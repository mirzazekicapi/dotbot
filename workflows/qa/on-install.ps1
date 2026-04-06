# ---------------------------------------------------------------------------
# 1. Create test-cases output directory
# ---------------------------------------------------------------------------
$testCasesDir = Join-Path $ProjectDir ".bot" "workspace" "product" "test-cases"
if (-not (Test-Path $testCasesDir)) {
    New-Item -Path $testCasesDir -ItemType Directory -Force | Out-Null
    $gitkeep = Join-Path $testCasesDir ".gitkeep"
    if (-not (Test-Path $gitkeep)) {
        New-Item -Path $gitkeep -ItemType File -Force | Out-Null
    }
    Write-Success "Created test-cases directory"
}

# ---------------------------------------------------------------------------
# 2. Check MCP server availability (same pattern as kickstart-via-jira)
# ---------------------------------------------------------------------------
$mcpJsonPath = Join-Path $ProjectDir ".mcp.json"
if (Test-Path $mcpJsonPath) {
    $mcpConfig = Get-Content $mcpJsonPath -Raw | ConvertFrom-Json
    $mcpServers = $mcpConfig.mcpServers
    if (-not $mcpServers) { $mcpServers = $mcpConfig }

    # Check for dotbot MCP server
    if ($mcpServers.PSObject.Properties.Name -contains "dotbot") {
        Write-Success "dotbot MCP server registered"
    } else {
        Write-DotbotWarning "dotbot MCP server not found in .mcp.json"
    }

    # Check for Atlassian MCP server (required for QA Jira integration)
    if ($mcpServers.PSObject.Properties.Name -contains "atlassian") {
        Write-Success "atlassian MCP server registered"
    } else {
        # Auto-add Atlassian HTTP MCP so subprocesses (claude --print) can discover it
        $atlDef = [PSCustomObject][ordered]@{ type = "http"; url = "https://mcp.atlassian.com/v1/mcp" }
        $mcpServers | Add-Member -NotePropertyName "atlassian" -NotePropertyValue $atlDef -Force
        $mcpConfig | ConvertTo-Json -Depth 5 | Set-Content -Path $mcpJsonPath -Encoding UTF8
        Write-Success "Added atlassian MCP server to .mcp.json"
        Write-Status "  Authenticate via: claude mcp add atlassian (if not already done)"
    }

    # Remove MCP servers unused by the QA workflow to reduce startup contention
    $unused = @("context7", "playwright", "serena")
    $removed = 0
    foreach ($name in $unused) {
        if ($mcpServers.PSObject.Properties.Name -contains $name) {
            $mcpServers.PSObject.Properties.Remove($name)
            $removed++
        }
    }
    if ($removed -gt 0) {
        $mcpConfig | ConvertTo-Json -Depth 5 | Set-Content -Path $mcpJsonPath -Encoding UTF8
        Write-Success "Removed $removed unused MCP server(s) from .mcp.json"
    }

    # Clean up any broken stdio atlassian entry (legacy from earlier QA profile versions)
    if ($mcpServers.PSObject.Properties.Name -contains "atlassian") {
        $atlEntry = $mcpServers.atlassian
        if ($atlEntry.type -eq "stdio" -and $atlEntry.args -and ($atlEntry.args -join ' ') -match 'mcp-atlassian') {
            $mcpServers.PSObject.Properties.Remove("atlassian")
            $mcpConfig | ConvertTo-Json -Depth 5 | Set-Content -Path $mcpJsonPath -Encoding UTF8
            Write-DotbotWarning "Removed broken local atlassian entry from .mcp.json -- use 'claude mcp add atlassian' instead"
        }
    }
} else {
    Write-DotbotWarning ".mcp.json not found -- MCP servers will be configured during init"
}

# ---------------------------------------------------------------------------
# 3. Bootstrap .env.local (same pattern as kickstart-via-jira)
# ---------------------------------------------------------------------------
$envLocal = Join-Path $ProjectDir ".env.local"
$envExample = Join-Path $PSScriptRoot ".env.example"

if (-not (Test-Path $envLocal)) {
    if (Test-Path $envExample) {
        Copy-Item $envExample $envLocal
        Write-DotbotWarning ".env.local created from QA template -- edit it with your credentials"
        Write-Status "  Path: $envLocal"
    }
} else {
    Write-Success ".env.local already exists"
}

# Ensure .env.local is in .gitignore
$gitignore = Join-Path $ProjectDir ".gitignore"
if (Test-Path $gitignore) {
    $gitContent = Get-Content $gitignore -Raw
    if ($gitContent -notmatch '\.env\.local') {
        Add-Content $gitignore ".env.local"
        Write-Success "Added .env.local to .gitignore"
    }
}

# Validate required variables are populated
if (Test-Path $envLocal) {
    $envVars = @{}
    Get-Content $envLocal | ForEach-Object {
        if ($_ -match '^\s*([^#][^=]+)=(.+)$') {
            $envVars[$matches[1].Trim()] = $matches[2].Trim()
        }
    }
    $required = @("ATLASSIAN_EMAIL", "ATLASSIAN_API_TOKEN", "ATLASSIAN_CLOUD_ID")
    $missing = $required | Where-Object { -not $envVars[$_] }
    if ($missing) {
        Write-DotbotWarning "Missing required values in .env.local: $($missing -join ', ')"
        Write-Status "  Edit $envLocal and fill in the missing values"
    } else {
        Write-Success "All required .env.local values populated"
    }
}

# ---------------------------------------------------------------------------
# 4. Validate test repo path (optional — for test automation workflow 06)
# ---------------------------------------------------------------------------
$settingsPath = Join-Path $ProjectDir ".bot" "defaults" "settings.default.json"
if (Test-Path $settingsPath) {
    $settings = Get-Content $settingsPath -Raw | ConvertFrom-Json

    $testRepoPath = $settings.qa.test_repo_path
    if (-not $testRepoPath) {
        Write-Host ""
        Write-DotbotWarning "qa.test_repo_path is not set (needed for test automation, not required for test plan generation)"
        Write-Host "    Set it in: .bot/defaults/settings.default.json" -ForegroundColor Yellow
        Write-Host "    Example: `"qa`": { `"test_repo_path`": `"C:/path/to/test-repo`" }" -ForegroundColor Gray
        Write-Host ""
    } elseif (-not (Test-Path $testRepoPath)) {
        Write-DotbotWarning "qa.test_repo_path '$testRepoPath' does not exist"
    } elseif (-not (Test-Path (Join-Path $testRepoPath ".git"))) {
        Write-DotbotWarning "qa.test_repo_path '$testRepoPath' is not a git repository"
    } else {
        Write-Success "Test repo found: $testRepoPath"
    }

    Write-Host "    Test framework will be auto-detected from the test repo" -ForegroundColor Gray

    # Validate knowledge base path (optional — for project-specific skills and knowledge)
    $kbPath = $settings.qa.knowledge_base_path
    if (-not $kbPath) {
        Write-Host ""
        Write-DotbotWarning "qa.knowledge_base_path is not set (optional — enhances test plans with project-specific knowledge)"
        Write-Host "    Set it in: .bot/defaults/settings.default.json" -ForegroundColor Yellow
        Write-Host "    Example: `"qa`": { `"knowledge_base_path`": `"C:/path/to/dotbot-qa-knowledge-base`" }" -ForegroundColor Gray
    } elseif (-not (Test-Path $kbPath)) {
        Write-DotbotWarning "qa.knowledge_base_path '$kbPath' does not exist"
    } else {
        Write-Success "Knowledge base found: $kbPath"
    }
}

Write-Success "QA profile initialized"
