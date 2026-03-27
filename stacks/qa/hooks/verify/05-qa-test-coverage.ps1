param(
    [string]$TaskId,
    [string]$Category
)

# Verify test cases cover all test plan scenarios
# Only runs for qa-test-case category tasks
$issues = @()
$details = @{}

# Skip if not a QA test case task
if ($Category -and $Category -ne 'qa-test-case') {
    @{
        success = $true
        script = "05-qa-test-coverage.ps1"
        message = "Skipped (category: $Category)"
        details = @{ skipped = $true }
        failures = @()
    } | ConvertTo-Json -Depth 10
    exit 0
}

# Check for test plan
$testPlanPath = Join-Path ".bot" "workspace" "product" "test-plan.md"
if (-not (Test-Path $testPlanPath)) {
    @{
        success = $true
        script = "05-qa-test-coverage.ps1"
        message = "Skipped (no test-plan.md found)"
        details = @{ skipped = $true }
        failures = @()
    } | ConvertTo-Json -Depth 10
    exit 0
}

# Check for test cases directory
$testCasesDir = Join-Path ".bot" "workspace" "product" "test-cases"
if (-not (Test-Path $testCasesDir)) {
    @{
        success = $true
        script = "05-qa-test-coverage.ps1"
        message = "Skipped (no test-cases directory)"
        details = @{ skipped = $true }
        failures = @()
    } | ConvertTo-Json -Depth 10
    exit 0
}

# Extract scenario IDs from test plan (I-xx, E-xx, UAT-xx)
$testPlanContent = Get-Content $testPlanPath -Raw
$scenarioPattern = '\b(I-\d+|E-\d+|UAT-\d+)\b'
$planScenarios = [regex]::Matches($testPlanContent, $scenarioPattern) |
    ForEach-Object { $_.Value } |
    Sort-Object -Unique

$details['plan_scenarios'] = $planScenarios.Count

if ($planScenarios.Count -eq 0) {
    @{
        success = $true
        script = "05-qa-test-coverage.ps1"
        message = "Skipped (no scenarios found in test plan)"
        details = @{ skipped = $true }
        failures = @()
    } | ConvertTo-Json -Depth 10
    exit 0
}

# Extract scenario IDs referenced in test case files (via TC-I-xx, TC-E-xx, TC-UAT-xx or direct references)
$testCaseFiles = Get-ChildItem -Path $testCasesDir -Filter "*.md" -File
$details['test_case_files'] = $testCaseFiles.Count

$coveredScenarios = @()
foreach ($file in $testCaseFiles) {
    $content = Get-Content $file.FullName -Raw
    # Match both TC-I-01 style and direct I-01 references
    $matches = [regex]::Matches($content, $scenarioPattern)
    foreach ($match in $matches) {
        $coveredScenarios += $match.Value
    }
}
$coveredScenarios = $coveredScenarios | Sort-Object -Unique

$details['covered_scenarios'] = $coveredScenarios.Count

# Find unmapped scenarios
$unmapped = $planScenarios | Where-Object { $_ -notin $coveredScenarios }

if ($unmapped.Count -gt 0) {
    foreach ($scenarioId in $unmapped) {
        $issues += @{
            issue = "Scenario $scenarioId from test plan has no test case"
            severity = "warning"
            context = "Add a test case referencing scenario $scenarioId"
        }
    }
}

$details['unmapped_scenarios'] = $unmapped.Count
$details['coverage_percent'] = if ($planScenarios.Count -gt 0) {
    [math]::Round(($coveredScenarios.Count / $planScenarios.Count) * 100, 1)
} else { 100 }

$message = if ($issues.Count -eq 0) {
    "All $($planScenarios.Count) scenarios covered ($($coveredScenarios.Count) test cases)"
} else {
    "$($unmapped.Count) of $($planScenarios.Count) scenarios unmapped"
}

@{
    success = ($issues.Count -eq 0)
    script = "05-qa-test-coverage.ps1"
    message = $message
    details = $details
    failures = $issues
} | ConvertTo-Json -Depth 10
