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

# ---------------------------------------------------------------------------
# Refine — archive current outputs, stash feedback, reset phase task so the
# runner regenerates with the feedback in context.
# ---------------------------------------------------------------------------

function Save-OutputsSnapshot {
    <#
        Archive the current contents of outputs_dir into outputs_dir/.versions/{timestamp}/.
        Excludes the .versions/ subdir itself. Returns the version id (timestamp folder
        name) or $null when there is nothing to archive.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$BotRoot,
        [Parameter(Mandatory)][string]$OutputsDirRel
    )
    $absDir = if ([System.IO.Path]::IsPathRooted($OutputsDirRel)) { $OutputsDirRel } else { Join-Path $BotRoot $OutputsDirRel }
    if (-not (Test-Path $absDir)) { return $null }

    $versionsRoot = Join-Path $absDir ".versions"
    $stamp = (Get-Date).ToUniversalTime().ToString("yyyyMMdd-HHmmss")
    $versionDir = Join-Path $versionsRoot $stamp
    if (-not (Test-Path $versionsRoot)) { New-Item -Path $versionsRoot -ItemType Directory -Force | Out-Null }
    if (Test-Path $versionDir) {
        # Same-second collision — append a short suffix.
        $versionDir = "$versionDir-$([guid]::NewGuid().ToString('N').Substring(0,4))"
    }
    New-Item -Path $versionDir -ItemType Directory -Force | Out-Null

    Get-ChildItem -Path $absDir -Force -ErrorAction SilentlyContinue | Where-Object {
        $_.Name -ne '.versions'
    } | ForEach-Object {
        try {
            Copy-Item -Path $_.FullName -Destination $versionDir -Recurse -Force -ErrorAction Stop
        } catch {
            Write-Host "Save-OutputsSnapshot: failed to copy $($_.FullName) — $_" -ErrorAction SilentlyContinue
        }
    }

    return (Split-Path -Leaf $versionDir)
}

function Get-OutputsVersions {
    <#
        Lists snapshot folders inside outputs_dir/.versions/ — newest first.
        Each entry: @{ id; created_at; file_count }.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$BotRoot,
        [Parameter(Mandatory)][string]$OutputsDirRel
    )
    $absDir = if ([System.IO.Path]::IsPathRooted($OutputsDirRel)) { $OutputsDirRel } else { Join-Path $BotRoot $OutputsDirRel }
    $versionsRoot = Join-Path $absDir ".versions"
    if (-not (Test-Path $versionsRoot)) { return @() }
    $entries = @()
    Get-ChildItem -Path $versionsRoot -Directory -ErrorAction SilentlyContinue | ForEach-Object {
        $count = @(Get-ChildItem -Path $_.FullName -Recurse -File -ErrorAction SilentlyContinue).Count
        $entries += [pscustomobject]@{
            id         = $_.Name
            created_at = $_.CreationTimeUtc.ToString("o")
            file_count = $count
        }
    }
    return @($entries | Sort-Object id -Descending)
}

function Restore-OutputsVersion {
    <#
        Snapshot the current outputs (so the user can revert the revert) and then
        copy files from .versions/{VersionId}/ back into outputs_dir.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$BotRoot,
        [Parameter(Mandatory)][string]$OutputsDirRel,
        [Parameter(Mandatory)][string]$VersionId
    )
    $absDir = if ([System.IO.Path]::IsPathRooted($OutputsDirRel)) { $OutputsDirRel } else { Join-Path $BotRoot $OutputsDirRel }
    $versionDir = Join-Path (Join-Path $absDir ".versions") $VersionId
    if (-not (Test-Path $versionDir)) { return @{ success = $false; error = "Version not found: $VersionId" } }

    # Snapshot current state before overwriting so a revert is itself reversible.
    $preRevertId = Save-OutputsSnapshot -BotRoot $BotRoot -OutputsDirRel $OutputsDirRel

    # Wipe the live outputs (excluding .versions) before copying the chosen version on top.
    Get-ChildItem -Path $absDir -Force -ErrorAction SilentlyContinue | Where-Object {
        $_.Name -ne '.versions'
    } | ForEach-Object {
        Remove-Item -Path $_.FullName -Recurse -Force -ErrorAction SilentlyContinue
    }
    Get-ChildItem -Path $versionDir -Force -ErrorAction SilentlyContinue | ForEach-Object {
        try {
            Copy-Item -Path $_.FullName -Destination $absDir -Recurse -Force -ErrorAction Stop
        } catch { }
    }
    return @{ success = $true; restored = $VersionId; pre_revert_snapshot = $preRevertId }
}

function Invoke-PhaseRefine {
    <#
        Refine the current phase: archive outputs, stash the user's comment,
        reset the phase-completing task so the runner re-generates with the
        feedback in context. Caller is responsible for kicking off a task-runner
        process if one isn't already alive (the launch handler does this).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$BotRoot,
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][string]$PhaseId,
        [string]$Comment = ""
    )
    $run = Get-WorkflowRun -BotRoot $BotRoot -RunId $RunId
    if (-not $run) { return @{ success = $false; error = "Run not found" } }

    $phase = $null
    foreach ($p in $run.phases) {
        if ($p.id -eq $PhaseId) { $phase = $p; break }
    }
    if (-not $phase) { return @{ success = $false; error = "Phase not found: $PhaseId" } }

    # 1. Snapshot current outputs.
    $versionId = Save-OutputsSnapshot -BotRoot $BotRoot -OutputsDirRel $run.outputs_dir

    # 2. Persist the feedback both in run metadata (for UI history) and in a
    # refine-feedback.json under outputs_dir (where prompts can read it).
    $now = (Get-Date).ToUniversalTime().ToString("o")
    $entry = [ordered]@{
        timestamp = $now
        phase_id  = $PhaseId
        comment   = $Comment
        version_archived = $versionId
    }
    $absOutDir = if ([System.IO.Path]::IsPathRooted($run.outputs_dir)) { $run.outputs_dir } else { Join-Path $BotRoot $run.outputs_dir }
    if (-not (Test-Path $absOutDir)) { New-Item -Path $absOutDir -ItemType Directory -Force | Out-Null }
    $feedbackPath = Join-Path $absOutDir "refine-feedback.json"
    $existingFeedback = @()
    if (Test-Path $feedbackPath) {
        try { $existingFeedback = @(Get-Content $feedbackPath -Raw | ConvertFrom-Json) } catch { $existingFeedback = @() }
    }
    $existingFeedback = @($existingFeedback + (New-Object psobject -Property $entry))
    $existingFeedback | ConvertTo-Json -Depth 4 | Set-Content -Path $feedbackPath -Encoding UTF8

    # Append to run metadata.refine_history
    $history = @()
    if ($run.PSObject.Properties['metadata'] -and $run.metadata.PSObject.Properties['refine_history']) {
        $history = @($run.metadata.refine_history)
    }
    $history += (New-Object psobject -Property $entry)

    # 3. Reset the phase status back to "pending" and clear current_phase if it was
    # this one — the guard will re-fire on next completion of completes_after_task.
    $newPhases = @()
    foreach ($p in $run.phases) {
        if ($p.id -eq $PhaseId) {
            $p | Add-Member -NotePropertyName 'status' -NotePropertyValue 'pending' -Force
            $p | Add-Member -NotePropertyName 'decided_at' -NotePropertyValue $null -Force
        }
        $newPhases += $p
    }

    # 4. Reset the phase-completing task — find by name + run_id, move from done/
    # back to todo/ so the runner picks it up. Downstream tasks that were already
    # done stay as-is (user is only refining this one phase).
    $resetTaskId = $null
    $taskName = $phase.completes_after_task
    if ($taskName) {
        foreach ($srcDir in @('done', 'cancelled', 'skipped')) {
            $path = Join-Path $BotRoot "workspace/tasks/$srcDir"
            if (-not (Test-Path $path)) { continue }
            Get-ChildItem -Path $path -Filter "*.json" -ErrorAction SilentlyContinue | ForEach-Object {
                if ($resetTaskId) { return }
                try {
                    $tData = Get-Content $_.FullName -Raw | ConvertFrom-Json
                    if (-not $tData.PSObject.Properties['run_id'] -or $tData.run_id -ne $RunId) { return }
                    $cleanName = ($tData.name -replace "\s*\[.*\]$", "")
                    if ($cleanName -ne $taskName) { return }
                    # Move to todo with status reset.
                    $tData | Add-Member -NotePropertyName 'status' -NotePropertyValue 'todo' -Force
                    $tData | Add-Member -NotePropertyName 'completed_at' -NotePropertyValue $null -Force
                    $tData | Add-Member -NotePropertyName 'updated_at' -NotePropertyValue ((Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")) -Force
                    $destDir = Join-Path $BotRoot "workspace/tasks/todo"
                    if (-not (Test-Path $destDir)) { New-Item -Path $destDir -ItemType Directory -Force | Out-Null }
                    $destPath = Join-Path $destDir $_.Name
                    $tData | ConvertTo-Json -Depth 20 | Set-Content -Path $destPath -Encoding UTF8
                    Remove-Item -Path $_.FullName -Force -ErrorAction SilentlyContinue
                    $resetTaskId = $tData.id
                } catch { }
            }
        }
    }

    # 5. Update the run record.
    Update-WorkflowRun -BotRoot $BotRoot -RunId $RunId -Properties @{
        phases   = $newPhases
        status   = 'running'
        current_phase = $null
        metadata = @{ refine_history = $history }
    } | Out-Null

    return @{
        success            = $true
        version_archived   = $versionId
        reset_task_id      = $resetTaskId
        comment_recorded   = -not [string]::IsNullOrWhiteSpace($Comment)
    }
}

Export-ModuleMember -Function @(
    'ConvertTo-PhaseRecords',
    'Test-PhaseGateForTask',
    'Apply-PhaseGate',
    'Approve-Phase',
    'Skip-Phase',
    'Resume-RunFromPhase',
    'Save-OutputsSnapshot',
    'Get-OutputsVersions',
    'Restore-OutputsVersion',
    'Invoke-PhaseRefine'
)
