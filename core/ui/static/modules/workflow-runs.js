/**
 * Generic per-workflow runs UI — replaces the deleted QA tab with a workflow-agnostic
 * run list + run detail view that works for any workflow that uses the Step 1 form
 * fields and Step 2 run storage. Opens in a modal triggered from each workflow card.
 *
 * State lives in module scope:
 *   workflowRunsCurrentWf  — workflow name being viewed
 *   workflowRunsCurrentRun — run record being viewed (null = list view)
 *   workflowRunsPollTimer  — polling handle for live updates
 *
 * Events fired (all consumed by tabs.js / app.js if it cares):
 *   none — fully self-contained.
 */

let workflowRunsCurrentWf = null;
let workflowRunsCurrentRun = null;
let workflowRunsPollTimer = null;
let workflowRunsResultsCache = null; // last /results payload for the currently-open run

/**
 * Open the runs modal for a given workflow. Entry point — wired from the
 * "Runs" button on each workflow card in workflow-launch.js.
 */
function openWorkflowRunsModal(workflowName) {
    if (!workflowName) return;
    workflowRunsCurrentWf = workflowName;
    workflowRunsCurrentRun = null;
    workflowRunsResultsCache = null;
    const modal = document.getElementById('workflow-runs-modal');
    if (!modal) return;
    document.getElementById('workflow-runs-title').textContent = `Runs — ${workflowName}`;
    showWorkflowRunsListView();
    modal.classList.add('visible');
    refreshWorkflowRuns();
    startWorkflowRunsPolling();
}

function closeWorkflowRunsModal() {
    stopWorkflowRunsPolling();
    workflowRunsCurrentWf = null;
    workflowRunsCurrentRun = null;
    workflowRunsResultsCache = null;
    const modal = document.getElementById('workflow-runs-modal');
    if (modal) modal.classList.remove('visible');
}

function startWorkflowRunsPolling() {
    stopWorkflowRunsPolling();
    workflowRunsPollTimer = setInterval(() => {
        if (workflowRunsCurrentRun) {
            refreshWorkflowRunDetail(workflowRunsCurrentRun.id);
        } else {
            refreshWorkflowRuns();
        }
    }, 3000);
}

function stopWorkflowRunsPolling() {
    if (workflowRunsPollTimer) {
        clearInterval(workflowRunsPollTimer);
        workflowRunsPollTimer = null;
    }
}

// ───────────────────────────── List view ─────────────────────────────

function showWorkflowRunsListView() {
    document.getElementById('workflow-runs-list-view').style.display = '';
    document.getElementById('workflow-runs-detail-view').style.display = 'none';
    workflowRunsCurrentRun = null;
    workflowRunsResultsCache = null;
}

async function refreshWorkflowRuns() {
    if (!workflowRunsCurrentWf) return;
    try {
        const res = await fetch(`${API_BASE}/api/workflows/${encodeURIComponent(workflowRunsCurrentWf)}/runs`);
        const data = await res.json();
        if (!data.success) {
            renderWorkflowRunsError(data.error || 'Failed to load runs');
            return;
        }
        renderWorkflowRunsList(data.runs || []);
    } catch (err) {
        renderWorkflowRunsError(err.message);
    }
}

function renderWorkflowRunsList(runs) {
    const host = document.getElementById('workflow-runs-list');
    if (!host) return;
    if (!runs.length) {
        host.innerHTML = `
            <div class="workflow-runs-empty">
                <div class="workflow-runs-empty-icon">◯</div>
                <div class="workflow-runs-empty-title">No runs yet</div>
                <div class="workflow-runs-empty-hint">Launch this workflow from the Run button to start your first run.</div>
            </div>`;
        return;
    }

    let html = '';
    for (const run of runs) {
        const status = run.status || 'unknown';
        const stage = run.metadata?.current_stage || '';
        const started = formatRunTime(run.started_at);
        const isActive = status === 'running' || status === 'awaiting-approval';
        const ledClass = isActive ? 'led pulse' : (status === 'failed' || status === 'cancelled' ? 'led off' : 'led');
        const statusLabel = formatRunStatus(status);
        const formSummary = renderRunFormSummary(run.form_input);

        html += `
            <div class="workflow-run-card" data-run-id="${escapeAttr(run.id)}">
                <div class="workflow-run-card-header">
                    <span class="${ledClass}"></span>
                    <span class="workflow-run-card-id">${escapeHtml(run.id)}</span>
                    <span class="workflow-run-card-status status-${escapeAttr(status)}">${escapeHtml(statusLabel)}</span>
                </div>
                ${formSummary ? `<div class="workflow-run-card-summary">${formSummary}</div>` : ''}
                ${stage ? `<div class="workflow-run-card-stage">${escapeHtml(stage)}</div>` : ''}
                <div class="workflow-run-card-footer">
                    <span class="workflow-run-card-time">${escapeHtml(started)}</span>
                    <div class="workflow-run-card-actions">
                        <button class="ctrl-btn-xs wf-run-detail-btn" title="View detail">Detail</button>
                        ${isActive
                            ? `<button class="ctrl-btn-xs wf-run-stop-btn" title="Stop gracefully">Stop</button>
                               <button class="ctrl-btn-xs wf-run-kill-btn" title="Force-kill">Kill</button>`
                            : `<button class="ctrl-btn-xs wf-run-delete-btn" title="Delete run">Delete</button>`}
                    </div>
                </div>
            </div>`;
    }
    host.innerHTML = html;

    // Bind handlers per card (avoid inline onclick — XSS-safe with run id from data attribute).
    host.querySelectorAll('.workflow-run-card').forEach(card => {
        const runId = card.dataset.runId;
        if (!runId) return;
        card.querySelector('.wf-run-detail-btn')?.addEventListener('click', () => openWorkflowRunDetail(runId));
        card.querySelector('.wf-run-stop-btn')?.addEventListener('click', () => stopWorkflowRun(runId));
        card.querySelector('.wf-run-kill-btn')?.addEventListener('click', () => killWorkflowRun(runId));
        card.querySelector('.wf-run-delete-btn')?.addEventListener('click', () => deleteWorkflowRun(runId));
    });
}

function renderRunFormSummary(formInput) {
    if (!formInput || typeof formInput !== 'object') return '';
    const entries = Object.entries(formInput);
    if (!entries.length) return '';
    // Show up to 3 truthy non-toggle fields, truncated.
    const parts = [];
    for (const [k, v] of entries) {
        if (v == null || v === '' || v === false) continue;
        if (parts.length >= 3) break;
        const display = (typeof v === 'string') ? (v.length > 60 ? v.slice(0, 60) + '…' : v) : String(v);
        parts.push(`<span class="workflow-run-card-field"><span class="field-name">${escapeHtml(k)}:</span> ${escapeHtml(display)}</span>`);
    }
    return parts.join('');
}

function renderWorkflowRunsError(msg) {
    const host = document.getElementById('workflow-runs-list');
    if (!host) return;
    host.innerHTML = `<div class="workflow-runs-empty"><div class="workflow-runs-empty-title">Error</div><div class="workflow-runs-empty-hint">${escapeHtml(msg)}</div></div>`;
}

// ───────────────────────────── Detail view ─────────────────────────────

async function openWorkflowRunDetail(runId) {
    document.getElementById('workflow-runs-list-view').style.display = 'none';
    document.getElementById('workflow-runs-detail-view').style.display = '';
    document.getElementById('workflow-run-detail-body').innerHTML = '<div class="workflow-runs-empty"><div class="workflow-runs-empty-hint">Loading…</div></div>';
    await refreshWorkflowRunDetail(runId);
}

async function refreshWorkflowRunDetail(runId) {
    if (!workflowRunsCurrentWf) return;
    try {
        const wf = encodeURIComponent(workflowRunsCurrentWf);
        const id = encodeURIComponent(runId);
        const [runRes, resultsRes] = await Promise.all([
            fetch(`${API_BASE}/api/workflows/${wf}/runs/${id}`),
            fetch(`${API_BASE}/api/workflows/${wf}/runs/${id}/results`)
        ]);
        const runData = await runRes.json();
        const resultsData = await resultsRes.json();
        if (!runData.success) {
            renderWorkflowRunDetailError(runData.error || 'Run not found');
            return;
        }
        workflowRunsCurrentRun = runData.run;
        workflowRunsResultsCache = resultsData.success ? resultsData : { artifacts: [] };
        renderWorkflowRunDetail(runData.run, workflowRunsResultsCache);
    } catch (err) {
        renderWorkflowRunDetailError(err.message);
    }
}

function renderWorkflowRunDetail(run, resultsPayload) {
    const body = document.getElementById('workflow-run-detail-body');
    if (!body) return;

    const status = run.status || 'unknown';
    const isActive = status === 'running' || status === 'awaiting-approval';
    const stage = run.metadata?.current_stage || '';
    const started = formatRunTime(run.started_at);
    const completed = run.completed_at ? formatRunTime(run.completed_at) : null;

    const formInputRows = renderFormInputTable(run.form_input);
    const tasksList = renderTasksList(run.task_ids);
    const artifactsList = renderArtifactsList(resultsPayload?.artifacts || [], resultsPayload?.outputs_dir);

    const actionButtons = isActive
        ? `<button class="ctrl-btn-xs wf-run-detail-stop-btn">Stop</button>
           <button class="ctrl-btn-xs wf-run-detail-kill-btn">Kill</button>`
        : `<button class="ctrl-btn-xs wf-run-detail-delete-btn">Delete</button>`;

    body.innerHTML = `
        <div class="workflow-run-detail-header">
            <div>
                <div class="workflow-run-detail-id">${escapeHtml(run.id)}</div>
                <div class="workflow-run-detail-meta">
                    <span class="workflow-run-card-status status-${escapeAttr(status)}">${escapeHtml(formatRunStatus(status))}</span>
                    ${stage ? `<span class="workflow-run-detail-stage">${escapeHtml(stage)}</span>` : ''}
                </div>
            </div>
            <div class="workflow-run-detail-actions">${actionButtons}</div>
        </div>
        <div class="workflow-run-detail-section">
            <div class="workflow-run-detail-label">Timing</div>
            <div class="workflow-run-detail-rows">
                <div><span class="field-name">started:</span> ${escapeHtml(started)}</div>
                ${completed ? `<div><span class="field-name">completed:</span> ${escapeHtml(completed)}</div>` : ''}
            </div>
        </div>
        ${formInputRows ? `
        <div class="workflow-run-detail-section">
            <div class="workflow-run-detail-label">Form input</div>
            <div class="workflow-run-detail-rows">${formInputRows}</div>
        </div>` : ''}
        ${tasksList ? `
        <div class="workflow-run-detail-section">
            <div class="workflow-run-detail-label">Tasks (${run.task_ids?.length || 0})</div>
            ${tasksList}
        </div>` : ''}
        <div class="workflow-run-detail-section">
            <div class="workflow-run-detail-label">Artifacts</div>
            ${artifactsList}
        </div>`;

    body.querySelector('.wf-run-detail-stop-btn')?.addEventListener('click', () => stopWorkflowRun(run.id, true));
    body.querySelector('.wf-run-detail-kill-btn')?.addEventListener('click', () => killWorkflowRun(run.id, true));
    body.querySelector('.wf-run-detail-delete-btn')?.addEventListener('click', () => deleteWorkflowRun(run.id, true));
    body.querySelectorAll('.wf-artifact-toggle').forEach(btn => {
        btn.addEventListener('click', e => {
            const card = e.target.closest('.wf-artifact-card');
            const content = card?.querySelector('.wf-artifact-content');
            if (content) content.classList.toggle('expanded');
            btn.textContent = content?.classList.contains('expanded') ? 'Collapse' : 'Expand';
        });
    });
}

function renderFormInputTable(formInput) {
    if (!formInput || typeof formInput !== 'object') return '';
    const entries = Object.entries(formInput).filter(([_, v]) => v != null && v !== '');
    if (!entries.length) return '';
    return entries.map(([k, v]) => {
        const display = typeof v === 'boolean' ? (v ? 'yes' : 'no') : String(v);
        return `<div><span class="field-name">${escapeHtml(k)}:</span> ${escapeHtml(display)}</div>`;
    }).join('');
}

function renderTasksList(taskIds) {
    if (!taskIds || !Array.isArray(taskIds) || !taskIds.length) return '';
    // For now just list IDs — Step 3+ may add a tasks endpoint with names/statuses.
    return `<div class="workflow-run-detail-rows">${taskIds.map(id => `<div class="workflow-run-task-id">${escapeHtml(id)}</div>`).join('')}</div>`;
}

function renderArtifactsList(artifacts, outputsDir) {
    if (!artifacts || !artifacts.length) {
        return `<div class="workflow-runs-empty-hint">
            No artifacts yet${outputsDir ? ` — will appear in <code>${escapeHtml(outputsDir)}</code> as the run completes` : ''}.
        </div>`;
    }
    return artifacts.map(a => {
        const isMd = a.path.endsWith('.md');
        const renderedContent = a.content
            ? (isMd && typeof renderMarkdown === 'function'
                ? renderMarkdown(a.content)
                : `<pre>${escapeHtml(a.content)}</pre>`)
            : `<div class="workflow-runs-empty-hint">File too large for inline preview (${formatBytes(a.size)}).</div>`;
        return `
            <div class="wf-artifact-card">
                <div class="wf-artifact-header">
                    <span class="wf-artifact-name">${escapeHtml(a.path)}</span>
                    <span class="wf-artifact-size">${formatBytes(a.size)}</span>
                    <button class="ctrl-btn-xs wf-artifact-toggle">Expand</button>
                </div>
                <div class="wf-artifact-content">${renderedContent}</div>
            </div>`;
    }).join('');
}

function renderWorkflowRunDetailError(msg) {
    const body = document.getElementById('workflow-run-detail-body');
    if (!body) return;
    body.innerHTML = `<div class="workflow-runs-empty"><div class="workflow-runs-empty-title">Error</div><div class="workflow-runs-empty-hint">${escapeHtml(msg)}</div></div>`;
}

// ───────────────────────────── Actions ─────────────────────────────

async function stopWorkflowRun(runId, fromDetail = false) {
    if (!workflowRunsCurrentWf) return;
    if (!confirm('Stop this run gracefully?')) return;
    const wf = encodeURIComponent(workflowRunsCurrentWf);
    try {
        await fetch(`${API_BASE}/api/workflows/${wf}/runs/${encodeURIComponent(runId)}/stop`, { method: 'POST' });
        if (fromDetail) await refreshWorkflowRunDetail(runId); else await refreshWorkflowRuns();
        if (typeof showToast === 'function') showToast('Stop signal sent', 'success');
    } catch (err) {
        if (typeof showToast === 'function') showToast(err.message, 'error');
    }
}

async function killWorkflowRun(runId, fromDetail = false) {
    if (!workflowRunsCurrentWf) return;
    if (!confirm('Force-kill this run? Tasks in-flight will be terminated.')) return;
    const wf = encodeURIComponent(workflowRunsCurrentWf);
    try {
        await fetch(`${API_BASE}/api/workflows/${wf}/runs/${encodeURIComponent(runId)}/kill`, { method: 'POST' });
        if (fromDetail) await refreshWorkflowRunDetail(runId); else await refreshWorkflowRuns();
        if (typeof showToast === 'function') showToast('Run killed', 'success');
    } catch (err) {
        if (typeof showToast === 'function') showToast(err.message, 'error');
    }
}

async function deleteWorkflowRun(runId, fromDetail = false) {
    if (!workflowRunsCurrentWf) return;
    if (!confirm('Delete this run? Artifacts will be removed too.')) return;
    const wf = encodeURIComponent(workflowRunsCurrentWf);
    try {
        const res = await fetch(`${API_BASE}/api/workflows/${wf}/runs/${encodeURIComponent(runId)}`, { method: 'DELETE' });
        const data = await res.json();
        if (!data.success) {
            if (typeof showToast === 'function') showToast(data.error || 'Delete failed', 'error');
            return;
        }
        if (typeof showToast === 'function') showToast('Run deleted', 'success');
        // After delete, return to list view (the run we were viewing no longer exists).
        showWorkflowRunsListView();
        await refreshWorkflowRuns();
    } catch (err) {
        if (typeof showToast === 'function') showToast(err.message, 'error');
    }
}

// ───────────────────────────── Helpers ─────────────────────────────

function formatRunStatus(s) {
    switch (s) {
        case 'running': return 'Running';
        case 'awaiting-approval': return 'Awaiting approval';
        case 'completed': return 'Completed';
        case 'failed': return 'Failed';
        case 'cancelled': return 'Cancelled';
        default: return s;
    }
}

function formatRunTime(iso) {
    if (!iso) return '—';
    try {
        const d = new Date(iso);
        const diff = (Date.now() - d.getTime()) / 1000;
        if (diff < 60) return 'just now';
        if (diff < 3600) return `${Math.floor(diff / 60)}m ago`;
        if (diff < 86400) return `${Math.floor(diff / 3600)}h ago`;
        return d.toLocaleString();
    } catch {
        return iso;
    }
}

function formatBytes(n) {
    if (n == null) return '—';
    if (n < 1024) return `${n} B`;
    if (n < 1024 * 1024) return `${(n / 1024).toFixed(1)} KB`;
    return `${(n / (1024 * 1024)).toFixed(1)} MB`;
}

function escapeAttr(s) {
    if (s == null) return '';
    return String(s).replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
}

// `escapeHtml` is defined globally by other modules (kickstart-era utility); fall
// back to a local copy if it's not present so this module stays standalone-loadable.
if (typeof escapeHtml !== 'function') {
    window.escapeHtml = function (s) {
        if (s == null) return '';
        return String(s).replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
    };
}

// ───────────────────────────── Init ─────────────────────────────

function initWorkflowRuns() {
    const modal = document.getElementById('workflow-runs-modal');
    if (!modal) return;
    modal.querySelector('.modal-close')?.addEventListener('click', closeWorkflowRunsModal);
    document.getElementById('workflow-runs-back-btn')?.addEventListener('click', () => {
        showWorkflowRunsListView();
        refreshWorkflowRuns();
    });
    document.getElementById('workflow-runs-refresh-btn')?.addEventListener('click', () => {
        if (workflowRunsCurrentRun) {
            refreshWorkflowRunDetail(workflowRunsCurrentRun.id);
        } else {
            refreshWorkflowRuns();
        }
    });
}

window.openWorkflowRunsModal = openWorkflowRunsModal;
window.closeWorkflowRunsModal = closeWorkflowRunsModal;
window.initWorkflowRuns = initWorkflowRuns;
