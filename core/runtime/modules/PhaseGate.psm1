#requires -Version 7.0
<#
.SYNOPSIS
    Generic per-phase approval gating for workflow runs.

.DESCRIPTION
    Replaces the QA-specific approval flow that lived in /api/qa/approve etc.
    A workflow declares `phases:` in workflow.yaml; each phase has
    `completes_after_task` (the task whose completion triggers the gate). When
    that task transitions to done AND the run was launched with approval_mode=true,
    Apply-PhaseGate moves all remaining incomplete tasks for the run into
    needs-input/ (invisible to the task-runner) and sets the run's status to
    "awaiting-approval". Approve-Phase / Skip-Phase restore the tasks so the
    runner can resume.

    Why needs-input as the holding pen: the task-runner already filters tasks
    by directory (todo/analysed only), so moving to needs-input is an existing
    primitive that doesn't require runner changes. Tasks remember their prior
    status via a `pending_approval_resume_to` field so we can move them back
    correctly on approve.
#>

Set-StrictMode -Version Latest

# Defensive imports for unit-test / standalone use.
if (-not (Get-Module WorkflowRunStore)) {
    $storePath = Join-Path $PSScriptRoot "WorkflowRunStore.psm1"
    if (Test-Path $storePath) {
        Import-Module $storePath -DisableNameChecking -Global -ErrorAction SilentlyContinue
    }
}

# ---------------------------------------------------------------------------
# Run-level phase initialization
# ---------------------------------------------------------------------------

function ConvertTo-PhaseRecords {
    <#
        Normalise the workflow.yaml `phases:` block into the per-run records we
        store on the WorkflowRun document. Adds a `status` field (pending) and
        copies declarative fields verbatim.
    #>
    param(
        [Parameter(Mandatory)][object]$Phases,
        [bool]$ApprovalMode = $true
    )
    $records = @()
    foreach ($phase in $Phases) {
        if (-not $phase) { continue }
        $id          = if ($phase -is [System.Collections.IDictionary]) { $phase['id'] } else { $phase.id }
        $label       = if ($phase -is [System.Collections.IDictionary]) { $phase['label'] } else { $phase.label }
        $completes   = if ($phase -is [System.Collections.IDictionary]) { $phase['completes_after_task'] } else { $phase.completes_after_task }
        $depends     = if ($phase -is [System.Collections.IDictionary]) { $phase['depends_on_phase'] } else { $phase.depends_on_phase }
        $reqApproval = if ($phase -is [System.Collections.IDictionary]) { $phase['requires_approval'] } else { $phase.requires_approval }
        if ($null -eq $reqApproval) { $reqApproval = $true }
        # When run was launched with approval_mode=false, all phases are pre-approved
        # — guard never fires.
        if (-not $ApprovalMode) { $reqApproval = $false }
        if (-not $id -or -not $completes) { continue }
        $records += [ordered]@{
            id                   = "$id"
            label                = if ($label) { "$label" } else { "$id" }
            completes_after_task = "$completes"
            depends_on_phase     = if ($depends) { "$depends" } else { $null }
            requires_approval    = [bool]$reqApproval
            status               = 'pending'   # pending | awaiting-approval | approved | skipped
            decided_at           = $null
        }
    }
    return ,$records
}

# ---------------------------------------------------------------------------
# Phase guard — fired from task-mark-done after a task transitions to done
# ---------------------------------------------------------------------------

function Test-PhaseGateForTask {
    <#
        Returns the phase that should be gated by this task's completion, or $null
        if no gating applies. Caller invokes Apply-PhaseGate when this returns
        non-null.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$BotRoot,
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][string]$TaskName
    )
    $run = Get-WorkflowRun -BotRoot $BotRoot -RunId $RunId
    if (-not $run) { return $null }
    if (-not $run.PSObject.Properties['approval_mode'] -or -not [bool]$run.approval_mode) { return $null }
    if (-not $run.PSObject.Properties['phases'] -or -not $run.phases) { return $null }
    foreach ($phase in $run.phases) {
        $reqApproval = if ($phase.PSObject.Properties['requires_approval']) { [bool]$phase.requires_approval } else { $true }
        if (-not $reqApproval) { continue }
        if ($phase.status -ne 'pending') { continue }
        # Strip any "[runId]" or similar suffix from the live task name to match
        # the manifest declaration. New-WorkflowTask currently doesn't append a
        # suffix, but downstream renames did this historically.
        $cleanName = ($TaskName -replace "\s*\[.*\]$", "")
        if ($cleanName -eq $phase.completes_after_task) {
            return $phase
        }
    }
    return $null
}

function Apply-PhaseGate {
    <#
        Mark the phase as awaiting-approval, move every still-pending task for the
        run into needs-input/, and set run.status = "awaiting-approval". Idempotent
        — safe to call twice.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$BotRoot,
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][string]$PhaseId
    )
    $run = Get-WorkflowRun -BotRoot $BotRoot -RunId $RunId
    if (-not $run) { return @{ success = $false; error = "Run not found" } }

    # Move pending tasks to needs-input. Track which directory each came from
    # so Approve-Phase can restore them correctly.
    $movedIds = @()
    foreach ($srcDir in @('todo', 'analysing', 'analysed', 'needs-input')) {
        $path = Join-Path $BotRoot "workspace/tasks/$srcDir"
        if (-not (Test-Path $path)) { continue }
        Get-ChildItem -Path $path -Filter "*.json" -ErrorAction SilentlyContinue | ForEach-Object {
            try {
                $tData = Get-Content $_.FullName -Raw | ConvertFrom-Json
                $belongsToRun = $tData.PSObject.Properties['run_id'] -and $tData.run_id -eq $RunId
                if (-not $belongsToRun) { return }
                if ($srcDir -eq 'needs-input') { return }  # already gated
                # Stamp prior status so Approve-Phase can move it back.
                $tData | Add-Member -NotePropertyName 'pending_approval_resume_to' -NotePropertyValue $srcDir -Force
                $tData | Add-Member -NotePropertyName 'status' -NotePropertyValue 'needs-input' -Force
                $tData | Add-Member -NotePropertyName 'updated_at' -NotePropertyValue ((Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")) -Force
                $destDir = Join-Path $BotRoot "workspace/tasks/needs-input"
                if (-not (Test-Path $destDir)) { New-Item -Path $destDir -ItemType Directory -Force | Out-Null }
                $destPath = Join-Path $destDir $_.Name
                $tData | ConvertTo-Json -Depth 20 | Set-Content -Path $destPath -Encoding UTF8
                Remove-Item -Path $_.FullName -Force -ErrorAction SilentlyContinue
                $movedIds += $tData.id
            } catch {
                # Skip on parse errors — better to under-gate than corrupt state.
            }
        }
    }

    # Update phase status on the run record.
    $newPhases = @()
    foreach ($p in $run.phases) {
        if ($p.id -eq $PhaseId) {
            $p | Add-Member -NotePropertyName 'status' -NotePropertyValue 'awaiting-approval' -Force
        }
        $newPhases += $p
    }
    Update-WorkflowRun -BotRoot $BotRoot -RunId $RunId -Properties @{
        phases        = $newPhases
        current_phase = $PhaseId
        status        = 'awaiting-approval'
    } | Out-Null

    return @{ success = $true; gated_task_ids = $movedIds; phase_id = $PhaseId }
}

# ---------------------------------------------------------------------------
# Approve / Skip — caller-facing endpoints unblock the gated tasks
# ---------------------------------------------------------------------------

function Resume-RunFromPhase {
    <#
        Shared body for Approve-Phase and Skip-Phase: marks the phase with the
        given decision, moves needs-input tasks back to their prior status, sets
        run.status = "running" (or "completed" when nothing remains to do).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$BotRoot,
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][string]$PhaseId,
        [Parameter(Mandatory)][ValidateSet('approved', 'skipped')][string]$Decision
    )
    $run = Get-WorkflowRun -BotRoot $BotRoot -RunId $RunId
    if (-not $run) { return @{ success = $false; error = "Run not found" } }

    # Move needs-input tasks for this run back to their prior status.
    $resumedIds = @()
    $needsInputDir = Join-Path $BotRoot "workspace/tasks/needs-input"
    if (Test-Path $needsInputDir) {
        Get-ChildItem -Path $needsInputDir -Filter "*.json" -ErrorAction SilentlyContinue | ForEach-Object {
            try {
                $tData = Get-Content $_.FullName -Raw | ConvertFrom-Json
                $belongsToRun = $tData.PSObject.Properties['run_id'] -and $tData.run_id -eq $RunId
                if (-not $belongsToRun) { return }
                $resumeTo = if ($tData.PSObject.Properties['pending_approval_resume_to']) { $tData.pending_approval_resume_to } else { 'todo' }
                if (-not $resumeTo -or $resumeTo -notin @('todo', 'analysing', 'analysed')) { $resumeTo = 'todo' }
                $tData | Add-Member -NotePropertyName 'status' -NotePropertyValue $resumeTo -Force
                $tData | Add-Member -NotePropertyName 'updated_at' -NotePropertyValue ((Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")) -Force
                # Strip the resume hint — no longer relevant.
                $tData.PSObject.Properties.Remove('pending_approval_resume_to') | Out-Null
                $destDir = Join-Path $BotRoot "workspace/tasks/$resumeTo"
                if (-not (Test-Path $destDir)) { New-Item -Path $destDir -ItemType Directory -Force | Out-Null }
                $destPath = Join-Path $destDir $_.Name
                $tData | ConvertTo-Json -Depth 20 | Set-Content -Path $destPath -Encoding UTF8
                Remove-Item -Path $_.FullName -Force -ErrorAction SilentlyContinue
                $resumedIds += $tData.id
            } catch { }
        }
    }

    # Update phase + run status.
    $now = (Get-Date).ToUniversalTime().ToString("o")
    $newPhases = @()
    foreach ($p in $run.phases) {
        if ($p.id -eq $PhaseId) {
            $p | Add-Member -NotePropertyName 'status' -NotePropertyValue $Decision -Force
            $p | Add-Member -NotePropertyName 'decided_at' -NotePropertyValue $now -Force
        }
        $newPhases += $p
    }
    # If any phase still pending, run is back to running and current_phase advances.
    $nextPending = $newPhases | Where-Object { $_.status -eq 'pending' } | Select-Object -First 1
    $newStatus = if ($resumedIds.Count -gt 0 -or $nextPending) { 'running' } else { 'completed' }
    Update-WorkflowRun -BotRoot $BotRoot -RunId $RunId -Properties @{
        phases        = $newPhases
        current_phase = if ($nextPending) { $nextPending.id } else { $null }
        status        = $newStatus
    } | Out-Null

    return @{
        success      = $true
        resumed_task_ids = $resumedIds
        decision     = $Decision
        next_phase   = if ($nextPending) { $nextPending.id } else { $null }
    }
}

function Approve-Phase {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$BotRoot,
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][string]$PhaseId
    )
    return Resume-RunFromPhase -BotRoot $BotRoot -RunId $RunId -PhaseId $PhaseId -Decision 'approved'
}

function Skip-Phase {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$BotRoot,
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][string]$PhaseId
    )
    return Resume-RunFromPhase -BotRoot $BotRoot -RunId $RunId -PhaseId $PhaseId -Decision 'skipped'
}

Export-ModuleMember -Function @(
    'ConvertTo-PhaseRecords',
    'Test-PhaseGateForTask',
    'Apply-PhaseGate',
    'Approve-Phase',
    'Skip-Phase',
    'Resume-RunFromPhase'
)
