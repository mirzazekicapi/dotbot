#requires -Version 7.0
<#
.SYNOPSIS
    Generic per-workflow run metadata store.

.DESCRIPTION
    Persists workflow-run records under .bot/.control/workflow-runs/{run-id}.json.
    Used by the generic /api/workflows/{name}/runs endpoints (added in the
    qa-refactor "Step 2" — replaces the QA-specific .bot/.control/qa-runs/
    storage so any workflow gets run tracking for free).

    Run schema:
      id              string   wr-YYYYMMDD-HHMMSS-xxxxxxxx
      workflow_name   string   e.g. "qa-via-jira"
      started_at      ISO 8601 UTC
      completed_at    ISO 8601 UTC | null
      status          "running" | "awaiting-approval" | "completed" | "failed" | "cancelled"
      process_id      string | null
      pid             int | null     (used for race-condition resolution before process_id is known)
      form_input      object | null  (whatever the workflow form posted)
      task_ids        string[]
      outputs_dir     string         (.bot/workspace/{workflow}/runs/{run-id}/)
      approval_mode   bool
      phases          object[]       (reserved for Step 4 — approval gates)
      metadata        object         (free-form bag for workflow-specific surfacing — jira_summary, etc.)
#>

Set-StrictMode -Version Latest

# ---------------------------------------------------------------------------
# Path resolution helpers
# ---------------------------------------------------------------------------

function Get-WorkflowRunsDir {
    param([Parameter(Mandatory)][string]$BotRoot)
    Join-Path $BotRoot ".control/workflow-runs"
}

function Get-WorkflowRunPath {
    param(
        [Parameter(Mandatory)][string]$BotRoot,
        [Parameter(Mandatory)][string]$RunId
    )
    Join-Path (Get-WorkflowRunsDir -BotRoot $BotRoot) "$RunId.json"
}

function Get-WorkflowRunOutputsDir {
    <#
        Returns the BotRoot-relative outputs directory for a run. Stored as a
        relative path in the run record (`workspace/{workflow}/runs/{id}`) so the
        record stays portable across machines / paths. Callers that need an
        absolute path should `Join-Path $BotRoot $outputs_dir` themselves.
    #>
    param(
        [Parameter(Mandatory)][string]$WorkflowName,
        [Parameter(Mandatory)][string]$RunId
    )
    "workspace/$WorkflowName/runs/$RunId"
}

# ---------------------------------------------------------------------------
# CRUD
# ---------------------------------------------------------------------------

function New-WorkflowRunId {
    # wr-YYYYMMDD-HHMMSS-xxxxxxxx — sortable + unique enough for human use.
    $stamp = (Get-Date).ToUniversalTime().ToString("yyyyMMdd-HHmmss")
    $suffix = [guid]::NewGuid().ToString("N").Substring(0, 8)
    return "wr-$stamp-$suffix"
}

function New-WorkflowRun {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$BotRoot,
        [Parameter(Mandatory)][string]$WorkflowName,
        [hashtable]$FormInput = @{},
        [string[]]$TaskIds = @(),
        [bool]$ApprovalMode = $false,
        [string]$ProcessId = $null,
        [int]$Pid = 0,
        # Optional pre-generated run id — when the caller wants tasks to carry the
        # same run_id the run record will use (e.g. so prompts can resolve
        # {output_directory} to this run's outputs_dir without a current-run lookup).
        [string]$RunId = $null
    )

    $dir = Get-WorkflowRunsDir -BotRoot $BotRoot
    if (-not (Test-Path $dir)) {
        New-Item -Path $dir -ItemType Directory -Force | Out-Null
    }

    $runId = if ($RunId) { $RunId } else { New-WorkflowRunId }
    $now = (Get-Date).ToUniversalTime().ToString("o")

    $record = [ordered]@{
        id            = $runId
        workflow_name = $WorkflowName
        started_at    = $now
        completed_at  = $null
        status        = "running"
        process_id    = $ProcessId
        pid           = if ($Pid -gt 0) { $Pid } else { $null }
        form_input    = $FormInput
        task_ids      = @($TaskIds)
        outputs_dir   = (Get-WorkflowRunOutputsDir -WorkflowName $WorkflowName -RunId $runId)
        approval_mode = [bool]$ApprovalMode
        phases        = @()
        metadata      = @{}
    }

    $path = Get-WorkflowRunPath -BotRoot $BotRoot -RunId $runId
    $record | ConvertTo-Json -Depth 6 | Set-Content -Path $path -Encoding UTF8

    return [pscustomobject]$record
}

function Get-WorkflowRun {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$BotRoot,
        [Parameter(Mandatory)][string]$RunId
    )
    $path = Get-WorkflowRunPath -BotRoot $BotRoot -RunId $RunId
    if (-not (Test-Path $path)) { return $null }
    try {
        return Get-Content $path -Raw | ConvertFrom-Json
    } catch {
        return $null
    }
}

function Get-WorkflowRuns {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$BotRoot,
        [string]$WorkflowName = $null
    )
    $dir = Get-WorkflowRunsDir -BotRoot $BotRoot
    if (-not (Test-Path $dir)) { return @() }

    $runs = @()
    Get-ChildItem -Path $dir -Filter "*.json" -ErrorAction SilentlyContinue | ForEach-Object {
        try {
            $record = Get-Content $_.FullName -Raw | ConvertFrom-Json
            if (-not $WorkflowName -or $record.workflow_name -eq $WorkflowName) {
                $runs += $record
            }
        } catch {
            # Corrupt file — skip rather than fail the whole listing.
        }
    }
    # Caller wraps with @() — return the bare array (no leading comma) so an empty
    # result doesn't get re-wrapped into @(@()) at the call site.
    return $runs
}

function Update-WorkflowRun {
    <#
        Generic patch — accepts a hashtable of properties to set/merge on the run record.
        For free-form metadata bag use `metadata = @{ ... }` and we merge by key.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$BotRoot,
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][hashtable]$Properties
    )
    $path = Get-WorkflowRunPath -BotRoot $BotRoot -RunId $RunId
    if (-not (Test-Path $path)) { return $null }

    $record = Get-Content $path -Raw | ConvertFrom-Json
    foreach ($key in $Properties.Keys) {
        $value = $Properties[$key]
        if ($key -eq 'metadata' -and $value -is [hashtable] -and $record.PSObject.Properties['metadata']) {
            # Merge metadata bag instead of replacing.
            foreach ($mk in $value.Keys) {
                $record.metadata | Add-Member -NotePropertyName $mk -NotePropertyValue $value[$mk] -Force
            }
        } else {
            if ($record.PSObject.Properties[$key]) {
                $record.$key = $value
            } else {
                $record | Add-Member -NotePropertyName $key -NotePropertyValue $value -Force
            }
        }
    }
    $record | ConvertTo-Json -Depth 6 | Set-Content -Path $path -Encoding UTF8
    return $record
}

function Set-WorkflowRunStatus {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$BotRoot,
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)]
        [ValidateSet("running", "awaiting-approval", "completed", "failed", "cancelled")]
        [string]$Status
    )
    $patch = @{ status = $Status }
    if ($Status -in @("completed", "failed", "cancelled")) {
        $patch.completed_at = (Get-Date).ToUniversalTime().ToString("o")
    }
    return Update-WorkflowRun -BotRoot $BotRoot -RunId $RunId -Properties $patch
}

function Remove-WorkflowRun {
    <#
        Deletes the run metadata file. Optionally also deletes the outputs directory
        if -RemoveOutputs is set. Tasks linked to the run are NOT deleted here —
        callers that need to clean tasks should do that explicitly.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$BotRoot,
        [Parameter(Mandatory)][string]$RunId,
        [switch]$RemoveOutputs
    )
    $path = Get-WorkflowRunPath -BotRoot $BotRoot -RunId $RunId
    if (-not (Test-Path $path)) { return $false }

    if ($RemoveOutputs) {
        $record = Get-Content $path -Raw | ConvertFrom-Json
        $outputsDir = if ($record.PSObject.Properties['outputs_dir']) { $record.outputs_dir } else { $null }
        if ($outputsDir) {
            $absDir = if ([System.IO.Path]::IsPathRooted($outputsDir)) { $outputsDir } else { Join-Path $BotRoot $outputsDir }
            if (Test-Path $absDir) {
                Remove-Item -Path $absDir -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    Remove-Item -Path $path -Force -ErrorAction SilentlyContinue
    return $true
}

Export-ModuleMember -Function @(
    'Get-WorkflowRunsDir',
    'Get-WorkflowRunPath',
    'Get-WorkflowRunOutputsDir',
    'New-WorkflowRunId',
    'New-WorkflowRun',
    'Get-WorkflowRun',
    'Get-WorkflowRuns',
    'Update-WorkflowRun',
    'Set-WorkflowRunStatus',
    'Remove-WorkflowRun'
)
