#requires -Version 7.0
<#
.SYNOPSIS
    Generic /api/workflows/{name}/runs* handler functions.

.DESCRIPTION
    Thin handlers that delegate to WorkflowRunStore for persistence and to
    ProcessAPI for process lifecycle. Keeps the giant switch in
    `core/ui/server.ps1` thin: routes call into here, get back a hashtable,
    serialize as JSON.

    Status auto-derivation: a run record on disk only carries the last
    explicitly-set status. For "running" runs we check the linked process
    (process_id) and the run's tasks to derive a more accurate status
    (e.g. promote `running` → `completed` when no tasks are pending and the
    process has stopped). This mirrors what the QA-specific /api/qa/runs
    endpoint did for QA-only runs but works generically for any workflow.
#>

Set-StrictMode -Version Latest

# Load dependencies. WorkflowRunStore must come from core/runtime/modules; ProcessAPI
# is already loaded by the server.ps1 module-load block when the server runs, so we
# only need a defensive import for unit tests / standalone use.
if (-not (Get-Module WorkflowRunStore)) {
    $storePath = Join-Path $PSScriptRoot "../../runtime/modules/WorkflowRunStore.psm1"
    if (Test-Path $storePath) {
        Import-Module $storePath -DisableNameChecking -Global -ErrorAction SilentlyContinue
    }
}

function Get-WorkflowRunsForApi {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$BotRoot,
        [Parameter(Mandatory)][string]$WorkflowName
    )

    $runs = @(Get-WorkflowRuns -BotRoot $BotRoot -WorkflowName $WorkflowName)

    # Auto-derive richer status for live runs without permanently mutating
    # the on-disk record (cheap to recompute on each list).
    $derived = @()
    foreach ($run in $runs) {
        $r = $run | ConvertTo-Json -Depth 6 -Compress | ConvertFrom-Json  # clone
        $derived += (Resolve-WorkflowRunDerivedStatus -BotRoot $BotRoot -Run $r)
    }
    return @{
        success = $true
        runs    = @($derived | Sort-Object { $_.started_at } -Descending)
    }
}

function Get-WorkflowRunForApi {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$BotRoot,
        [Parameter(Mandatory)][string]$WorkflowName,
        [Parameter(Mandatory)][string]$RunId
    )
    $run = Get-WorkflowRun -BotRoot $BotRoot -RunId $RunId
    if (-not $run -or $run.workflow_name -ne $WorkflowName) {
        return @{ success = $false; error = "Run not found: $RunId" }
    }
    $derived = Resolve-WorkflowRunDerivedStatus -BotRoot $BotRoot -Run $run
    return @{ success = $true; run = $derived }
}

function Stop-WorkflowRunForApi {
    <#
        Stops the run by writing a .stop signal to its linked process. Mirrors what
        Stop-ProcessById does today. Status update happens when the process actually
        exits — derivation will reflect it on next list.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$BotRoot,
        [Parameter(Mandatory)][string]$WorkflowName,
        [Parameter(Mandatory)][string]$RunId
    )
    $run = Get-WorkflowRun -BotRoot $BotRoot -RunId $RunId
    if (-not $run -or $run.workflow_name -ne $WorkflowName) {
        return @{ success = $false; error = "Run not found: $RunId" }
    }
    $procId = if ($run.PSObject.Properties['process_id']) { $run.process_id } else { $null }
    if ($procId -and (Get-Command Stop-ProcessById -ErrorAction SilentlyContinue)) {
        Stop-ProcessById -ProcessId $procId | Out-Null
    }
    return @{ success = $true; run_id = $RunId; signaled = [bool]$procId }
}

function Stop-WorkflowRunHardForApi {
    <#
        Force-kills the run's process (Stop-ManagedProcessById sends SIGKILL on Unix /
        TerminateProcess on Windows). Then sets the run's status to 'cancelled'.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$BotRoot,
        [Parameter(Mandatory)][string]$WorkflowName,
        [Parameter(Mandatory)][string]$RunId
    )
    $run = Get-WorkflowRun -BotRoot $BotRoot -RunId $RunId
    if (-not $run -or $run.workflow_name -ne $WorkflowName) {
        return @{ success = $false; error = "Run not found: $RunId" }
    }
    $procId = if ($run.PSObject.Properties['process_id']) { $run.process_id } else { $null }
    $killed = $false
    if ($procId -and (Get-Command Stop-ManagedProcessById -ErrorAction SilentlyContinue)) {
        $result = Stop-ManagedProcessById -ProcessId $procId
        $killed = ($result -and $result.success)
    }
    Set-WorkflowRunStatus -BotRoot $BotRoot -RunId $RunId -Status 'cancelled' | Out-Null
    return @{ success = $true; run_id = $RunId; killed = $killed }
}

function Get-WorkflowRunResultsForApi {
    <#
        Returns the artifacts (files) currently in the run's outputs_dir, organised
        for UI display. Inlines small markdown files (<= 256 KB) so the UI doesn't
        need a second round-trip. Larger files come back as path-only entries.

        Today the run's outputs_dir is empty until something writes to it — Step 3
        of the QA refactor will wire up a post-task hook that copies declared
        `outputs:` files into the run dir. Until then this endpoint returns an empty
        artifact list for new generic runs.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$BotRoot,
        [Parameter(Mandatory)][string]$WorkflowName,
        [Parameter(Mandatory)][string]$RunId
    )
    $run = Get-WorkflowRun -BotRoot $BotRoot -RunId $RunId
    if (-not $run -or $run.workflow_name -ne $WorkflowName) {
        return @{ success = $false; error = "Run not found: $RunId" }
    }
    $outputsDir = if ($run.PSObject.Properties['outputs_dir']) { $run.outputs_dir } else { $null }
    if (-not $outputsDir) {
        return @{ success = $true; outputs_dir = $null; artifacts = @() }
    }
    # outputs_dir is stored as a BotRoot-relative path (e.g. workspace/qa-via-jira/runs/{id}).
    $absDir = if ([System.IO.Path]::IsPathRooted($outputsDir)) {
        $outputsDir
    } else {
        Join-Path $BotRoot $outputsDir
    }
    if (-not (Test-Path $absDir)) {
        return @{ success = $true; outputs_dir = $outputsDir; artifacts = @() }
    }

    $artifacts = @()
    $maxInlineBytes = 256KB
    Get-ChildItem -Path $absDir -Recurse -File -ErrorAction SilentlyContinue | ForEach-Object {
        $rel = $_.FullName.Substring($absDir.Length).TrimStart('\','/')
        $entry = [ordered]@{
            name      = $_.Name
            path      = $rel.Replace('\','/')
            size      = $_.Length
            modified  = $_.LastWriteTimeUtc.ToString("o")
            content   = $null
            truncated = $false
        }
        if ($_.Length -le $maxInlineBytes -and $_.Extension -in @('.md', '.txt', '.json', '.yaml', '.yml')) {
            try {
                $entry.content = Get-Content $_.FullName -Raw -ErrorAction Stop
            } catch {
                $entry.content = $null
            }
        } else {
            $entry.truncated = $true
        }
        $artifacts += [pscustomobject]$entry
    }

    return @{
        success     = $true
        outputs_dir = $outputsDir
        artifacts   = @($artifacts | Sort-Object path)
    }
}

function Remove-WorkflowRunForApi {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$BotRoot,
        [Parameter(Mandatory)][string]$WorkflowName,
        [Parameter(Mandatory)][string]$RunId,
        [bool]$RemoveOutputs = $true
    )
    $run = Get-WorkflowRun -BotRoot $BotRoot -RunId $RunId
    if (-not $run -or $run.workflow_name -ne $WorkflowName) {
        return @{ success = $false; error = "Run not found: $RunId" }
    }
    # If the run is still active, refuse — caller should kill first.
    if ($run.status -in @('running', 'awaiting-approval')) {
        return @{ success = $false; error = "Run is active — kill it before deleting" }
    }
    $ok = Remove-WorkflowRun -BotRoot $BotRoot -RunId $RunId -RemoveOutputs:$RemoveOutputs
    return @{ success = [bool]$ok; run_id = $RunId }
}

# ---------------------------------------------------------------------------
# Status derivation
# ---------------------------------------------------------------------------
# A run record on disk only carries the last explicitly-set status. For live
# runs we cross-check process state + linked tasks to surface a more accurate
# status without permanently mutating the file.

function Resolve-WorkflowRunDerivedStatus {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$BotRoot,
        [Parameter(Mandatory)][object]$Run
    )

    if ($Run.status -in @('completed', 'failed', 'cancelled')) {
        return $Run
    }

    # Resolve the linked process (if any) so we can tell if work is still happening.
    $procActive = $false
    if ($Run.PSObject.Properties['process_id'] -and $Run.process_id) {
        $procPath = Join-Path $BotRoot ".control/processes/$($Run.process_id).json"
        if (Test-Path $procPath) {
            try {
                $proc = Get-Content $procPath -Raw | ConvertFrom-Json
                $procActive = $proc.status -in @('running', 'starting')
            } catch { }
        }
    }

    # Inspect tasks linked by id (preferred) or, when task_ids isn't populated yet,
    # fall back to scanning by workflow_name (matches QA's existing detection logic).
    $taskStats = Get-WorkflowRunTaskStats -BotRoot $BotRoot -Run $Run

    # Promote terminal status when the process is gone and no tasks are pending.
    if (-not $procActive -and -not $taskStats.has_pending) {
        if ($taskStats.any_failed) {
            $Run.status = 'failed'
        } elseif ($taskStats.total -gt 0) {
            $Run.status = 'completed'
        }
        # If total=0 and process is gone, leave as-is — caller can interpret.
    }

    # Surface "current_stage" for the UI — first non-done task name, or "Completing..."
    # when everything is done but status hasn't flipped yet.
    if ($taskStats.current_stage) {
        if ($Run.PSObject.Properties['metadata']) {
            $Run.metadata | Add-Member -NotePropertyName 'current_stage' -NotePropertyValue $taskStats.current_stage -Force
        } else {
            $Run | Add-Member -NotePropertyName 'metadata' -NotePropertyValue ([pscustomobject]@{ current_stage = $taskStats.current_stage }) -Force
        }
    }

    return $Run
}

function Get-WorkflowRunTaskStats {
    <#
        Walks the workspace task directories to compute pending / in-progress / done
        counts and the current stage label for a run. Filters by `task_ids` when
        present (post-Step 3); falls back to workflow_name match for legacy runs.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$BotRoot,
        [Parameter(Mandatory)][object]$Run
    )

    $taskIds = @()
    if ($Run.PSObject.Properties['task_ids'] -and $Run.task_ids) {
        $taskIds = @($Run.task_ids)
    }
    $useIdFilter = $taskIds.Count -gt 0
    $wfName = $Run.workflow_name

    $stats = [pscustomobject]@{
        total         = 0
        done          = 0
        in_progress   = 0
        todo          = 0
        any_failed    = $false
        has_pending   = $false
        current_stage = $null
    }

    $tasks = @()
    foreach ($tDir in @('todo', 'analysing', 'analysed', 'in-progress', 'done', 'cancelled', 'skipped', 'needs-input')) {
        $path = Join-Path $BotRoot "workspace/tasks/$tDir"
        if (-not (Test-Path $path)) { continue }
        Get-ChildItem -Path $path -Filter "*.json" -ErrorAction SilentlyContinue | ForEach-Object {
            try {
                $tData = Get-Content $_.FullName -Raw | ConvertFrom-Json
                $matchesRun = if ($useIdFilter) { $tData.id -in $taskIds } else { $tData.workflow -eq $wfName }
                if ($matchesRun) {
                    $tasks += [pscustomobject]@{
                        name     = ($tData.name -replace "\s*\[.*\]$", "")
                        status   = $tDir
                        priority = if ($tData.PSObject.Properties['priority']) { [int]$tData.priority } else { 999 }
                    }
                }
            } catch { }
        }
    }

    $tasks = @($tasks | Sort-Object priority)
    $stats.total       = $tasks.Count
    # @(...) around Where-Object output — strict mode rejects .Count on $null when
    # Where-Object filters everything out. Wrapping forces an array even when empty.
    $stats.done        = @($tasks | Where-Object { $_.status -eq 'done' }).Count
    $stats.in_progress = @($tasks | Where-Object { $_.status -eq 'in-progress' }).Count
    $stats.todo        = @($tasks | Where-Object { $_.status -in @('todo', 'analysing', 'analysed', 'needs-input') }).Count
    $stats.any_failed  = @($tasks | Where-Object { $_.status -eq 'cancelled' }).Count -gt 0
    $stats.has_pending = $stats.in_progress -gt 0 -or $stats.todo -gt 0

    foreach ($t in $tasks) {
        if ($t.status -eq 'in-progress') { $stats.current_stage = "$($t.name)..."; break }
        if ($t.status -in @('todo', 'analysing', 'analysed', 'needs-input')) { $stats.current_stage = "Waiting: $($t.name)"; break }
    }
    if (-not $stats.current_stage -and $stats.total -gt 0 -and $stats.done -eq $stats.total) {
        $stats.current_stage = "Completing..."
    }

    return $stats
}

Export-ModuleMember -Function @(
    'Get-WorkflowRunsForApi',
    'Get-WorkflowRunForApi',
    'Get-WorkflowRunResultsForApi',
    'Stop-WorkflowRunForApi',
    'Stop-WorkflowRunHardForApi',
    'Remove-WorkflowRunForApi',
    'Resolve-WorkflowRunDerivedStatus',
    'Get-WorkflowRunTaskStats'
)
