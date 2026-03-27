function Invoke-QaSyncTestRepo {
    param(
        [hashtable]$Arguments
    )

    # Import helpers
    $coreHelpersPath = Join-Path $PSScriptRoot '..\..\core-helpers.psm1'
    Import-Module $coreHelpersPath -Force -DisableNameChecking -WarningAction SilentlyContinue

    $timer = Start-ToolTimer

    try {
        # Use project root detected by MCP server
        $solutionRoot = $global:DotbotProjectRoot
        if (-not $solutionRoot -or -not (Test-Path (Join-Path $solutionRoot '.bot'))) {
            $duration = Get-ToolDuration -Stopwatch $timer
            return New-EnvelopeResponse `
                -Tool "qa_sync_test_repo" `
                -Version "1.0.0" `
                -Summary "Failed: not in a project directory." `
                -Data @{} `
                -Errors @((New-ErrorObject -Code "PROJECT_NOT_FOUND" -Message "Not in a project directory (no .bot folder found)")) `
                -Source "qa-sync-test-repo" `
                -DurationMs $duration `
                -Host (Get-McpHost)
        }

        # Read QA settings
        $settingsPath = Join-Path $solutionRoot '.bot' 'defaults' 'settings.default.json'
        $userSettingsPath = Join-Path $solutionRoot '.bot' '.control' 'settings.json'

        $testRepoPath = $null
        $presets = $null

        # Load default settings
        if (Test-Path $settingsPath) {
            $settings = Get-Content $settingsPath -Raw | ConvertFrom-Json
            if ($settings.qa) {
                $testRepoPath = $settings.qa.test_repo_path
                $presets = $settings.qa.test_framework_presets
            }
        }

        # Override with user settings if present
        if (Test-Path $userSettingsPath) {
            $userSettings = Get-Content $userSettingsPath -Raw | ConvertFrom-Json
            if ($userSettings.qa -and $userSettings.qa.test_repo_path) {
                $testRepoPath = $userSettings.qa.test_repo_path
            }
        }

        if (-not $testRepoPath) {
            $duration = Get-ToolDuration -Stopwatch $timer
            return New-EnvelopeResponse `
                -Tool "qa_sync_test_repo" `
                -Version "1.0.0" `
                -Summary "Failed: qa.test_repo_path not configured." `
                -Data @{} `
                -Errors @((New-ErrorObject -Code "NOT_CONFIGURED" -Message "qa.test_repo_path is not set. Configure it in .bot/defaults/settings.default.json")) `
                -Source "qa-sync-test-repo" `
                -DurationMs $duration `
                -Host (Get-McpHost)
        }

        $action = if ($Arguments.action) { $Arguments.action } else { "status" }

        switch ($action) {
            "status" {
                $data = @{
                    test_repo_path = $testRepoPath
                    exists = (Test-Path $testRepoPath)
                }

                if (Test-Path $testRepoPath) {
                    $isGitRepo = Test-Path (Join-Path $testRepoPath ".git")
                    $data.is_git_repo = $isGitRepo

                    if ($isGitRepo) {
                        Push-Location $testRepoPath
                        try {
                            $data.current_branch = (git rev-parse --abbrev-ref HEAD 2>&1).ToString().Trim()
                            $statusOutput = git status --porcelain 2>&1 | Out-String
                            $data.is_clean = [string]::IsNullOrWhiteSpace($statusOutput)
                            $data.uncommitted_changes = if ($statusOutput) { $statusOutput.Trim() } else { "" }
                        }
                        finally {
                            Pop-Location
                        }
                    }
                }

                $duration = Get-ToolDuration -Stopwatch $timer
                $summary = if ($data.exists -and $data.is_git_repo) {
                    "Test repo: $testRepoPath (branch: $($data.current_branch), clean: $($data.is_clean))"
                } elseif ($data.exists) {
                    "Test repo path exists but is not a git repository"
                } else {
                    "Test repo path does not exist: $testRepoPath"
                }

                return New-EnvelopeResponse `
                    -Tool "qa_sync_test_repo" `
                    -Version "1.0.0" `
                    -Summary $summary `
                    -Data $data `
                    -Source "qa-sync-test-repo" `
                    -DurationMs $duration `
                    -Host (Get-McpHost)
            }

            "pull" {
                if (-not (Test-Path $testRepoPath)) {
                    $duration = Get-ToolDuration -Stopwatch $timer
                    return New-EnvelopeResponse `
                        -Tool "qa_sync_test_repo" `
                        -Version "1.0.0" `
                        -Summary "Failed: test repo path does not exist." `
                        -Data @{ test_repo_path = $testRepoPath } `
                        -Errors @((New-ErrorObject -Code "PATH_NOT_FOUND" -Message "Test repo not found at: $testRepoPath")) `
                        -Source "qa-sync-test-repo" `
                        -DurationMs $duration `
                        -Host (Get-McpHost)
                }

                Push-Location $testRepoPath
                try {
                    $pullOutput = git pull 2>&1 | Out-String
                    $data = @{
                        test_repo_path = $testRepoPath
                        output = $pullOutput.Trim()
                        success = ($LASTEXITCODE -eq 0)
                    }
                }
                finally {
                    Pop-Location
                }

                $duration = Get-ToolDuration -Stopwatch $timer
                $summary = if ($data.success) { "Git pull succeeded in $testRepoPath" } else { "Git pull failed in $testRepoPath" }

                return New-EnvelopeResponse `
                    -Tool "qa_sync_test_repo" `
                    -Version "1.0.0" `
                    -Summary $summary `
                    -Data $data `
                    -Source "qa-sync-test-repo" `
                    -DurationMs $duration `
                    -Host (Get-McpHost)
            }

            "detect" {
                if (-not (Test-Path $testRepoPath)) {
                    $duration = Get-ToolDuration -Stopwatch $timer
                    return New-EnvelopeResponse `
                        -Tool "qa_sync_test_repo" `
                        -Version "1.0.0" `
                        -Summary "Failed: test repo path does not exist." `
                        -Data @{ test_repo_path = $testRepoPath } `
                        -Errors @((New-ErrorObject -Code "PATH_NOT_FOUND" -Message "Test repo not found at: $testRepoPath")) `
                        -Source "qa-sync-test-repo" `
                        -DurationMs $duration `
                        -Host (Get-McpHost)
                }

                $indicators = @()
                $detectedFramework = $null
                $confidence = "none"

                # Check for Playwright (TypeScript)
                $playwrightConfig = Get-ChildItem -Path $testRepoPath -Filter "playwright.config.*" -Depth 1 -ErrorAction SilentlyContinue
                if ($playwrightConfig) {
                    $indicators += "Found: $($playwrightConfig.Name)"
                    $detectedFramework = "playwright-ts"
                    $confidence = "high"
                }
                if (-not $detectedFramework) {
                    $packageJson = Join-Path $testRepoPath "package.json"
                    if (Test-Path $packageJson) {
                        $pkgContent = Get-Content $packageJson -Raw
                        if ($pkgContent -match '@playwright/test') {
                            $indicators += "Found: @playwright/test in package.json"
                            $detectedFramework = "playwright-ts"
                            $confidence = "high"
                        }
                    }
                }

                # Check for Cypress
                if (-not $detectedFramework) {
                    $cypressConfig = Get-ChildItem -Path $testRepoPath -Filter "cypress.config.*" -Depth 1 -ErrorAction SilentlyContinue
                    if ($cypressConfig) {
                        $indicators += "Found: $($cypressConfig.Name)"
                        $detectedFramework = "cypress"
                        $confidence = "high"
                    }
                    if (-not $detectedFramework -and (Test-Path $packageJson)) {
                        $pkgContent = if ($pkgContent) { $pkgContent } else { Get-Content $packageJson -Raw }
                        if ($pkgContent -match '"cypress"') {
                            $indicators += "Found: cypress in package.json"
                            $detectedFramework = "cypress"
                            $confidence = "high"
                        }
                    }
                }

                # Check for Supertest (API)
                if (-not $detectedFramework -and (Test-Path (Join-Path $testRepoPath "package.json"))) {
                    $pkgContent = if ($pkgContent) { $pkgContent } else { Get-Content (Join-Path $testRepoPath "package.json") -Raw }
                    if ($pkgContent -match '"supertest"') {
                        $indicators += "Found: supertest in package.json"
                        $detectedFramework = "api-supertest"
                        $confidence = "high"
                    }
                }

                # Check for Selenium C# (.csproj with Selenium.WebDriver)
                if (-not $detectedFramework) {
                    $csproj = Get-ChildItem -Path $testRepoPath -Filter "*.csproj" -Recurse -Depth 3 -ErrorAction SilentlyContinue | Select-Object -First 1
                    if ($csproj) {
                        $csprojContent = Get-Content $csproj.FullName -Raw
                        if ($csprojContent -match 'Selenium\.WebDriver') {
                            $indicators += "Found: Selenium.WebDriver in $($csproj.Name)"
                            $detectedFramework = "selenium-csharp"
                            $confidence = "high"
                        }
                    }
                }

                # Check for Java frameworks (pom.xml)
                if (-not $detectedFramework) {
                    $pomXml = Join-Path $testRepoPath "pom.xml"
                    if (Test-Path $pomXml) {
                        $pomContent = Get-Content $pomXml -Raw

                        if ($pomContent -match 'io\.appium|appium') {
                            $indicators += "Found: appium dependency in pom.xml"
                            $detectedFramework = "appium-java"
                            $confidence = "high"
                        } elseif ($pomContent -match 'rest-assured|io\.restassured') {
                            $indicators += "Found: rest-assured dependency in pom.xml"
                            $detectedFramework = "api-rest-assured"
                            $confidence = "high"
                        } elseif ($pomContent -match 'selenium-java|org\.seleniumhq') {
                            $indicators += "Found: selenium-java dependency in pom.xml"
                            $detectedFramework = "selenium-java"
                            $confidence = "high"
                        }
                    }
                }

                # Build result
                $data = @{
                    test_repo_path = $testRepoPath
                    detected_framework = $detectedFramework
                    confidence = $confidence
                    indicators_found = $indicators
                }

                # Look up preset if detected
                if ($detectedFramework -and $presets) {
                    $preset = $presets.$detectedFramework
                    if ($preset) {
                        $data.preset = @{
                            language = $preset.language
                            test_runner = $preset.test_runner
                            file_pattern = $preset.file_pattern
                            base_dir = $preset.base_dir
                        }
                    }
                }

                $duration = Get-ToolDuration -Stopwatch $timer
                $summary = if ($detectedFramework) {
                    "Detected framework: $detectedFramework (confidence: $confidence)"
                } else {
                    "No known test framework detected in $testRepoPath"
                }

                return New-EnvelopeResponse `
                    -Tool "qa_sync_test_repo" `
                    -Version "1.0.0" `
                    -Summary $summary `
                    -Data $data `
                    -Source "qa-sync-test-repo" `
                    -DurationMs $duration `
                    -Host (Get-McpHost)
            }

            "validate" {
                $issues = @()
                $data = @{
                    test_repo_path = $testRepoPath
                }

                # Check repo exists and is git
                if (-not (Test-Path $testRepoPath)) {
                    $issues += New-ErrorObject -Code "PATH_NOT_FOUND" -Message "Test repo not found at: $testRepoPath"
                } elseif (-not (Test-Path (Join-Path $testRepoPath ".git"))) {
                    $issues += New-ErrorObject -Code "NOT_GIT_REPO" -Message "Path exists but is not a git repository: $testRepoPath"
                }

                $duration = Get-ToolDuration -Stopwatch $timer
                $summary = if ($issues.Count -eq 0) {
                    "Validation passed: $testRepoPath"
                } else {
                    "Validation found $($issues.Count) issue(s)"
                }

                $response = @{
                    Tool = "qa_sync_test_repo"
                    Version = "1.0.0"
                    Summary = $summary
                    Data = $data
                    Source = "qa-sync-test-repo"
                    DurationMs = $duration
                    Host = (Get-McpHost)
                }
                if ($issues.Count -gt 0) {
                    $response.Errors = $issues
                }

                return New-EnvelopeResponse @response
            }
        }
    }
    catch {
        $duration = Get-ToolDuration -Stopwatch $timer
        return New-EnvelopeResponse `
            -Tool "qa_sync_test_repo" `
            -Version "1.0.0" `
            -Summary "Failed: $_" `
            -Data @{} `
            -Errors @((New-ErrorObject -Code "EXECUTION_FAILED" -Message "$_")) `
            -Source "qa-sync-test-repo" `
            -DurationMs $duration `
            -Host (Get-McpHost)
    }
    finally {
        Remove-Module core-helpers -ErrorAction SilentlyContinue
    }
}
