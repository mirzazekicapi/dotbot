/**
 * DOTBOT Control Panel - QA Tab
 * Run list, detail view, input form, process polling
 */

let qaPollTimer = null;

/**
 * Initialize QA tab — check profile, load runs, wire form
 */
async function initQATab() {
    const qaTabBtn = document.getElementById('qa-tab-btn');
    if (!qaTabBtn) return;

    // Show QA tab only when QA profile is active
    try {
        const res = await fetch(`${API_BASE}/api/info`);
        const info = await res.json();
        if (info.has_qa) {
            qaTabBtn.style.display = '';
        } else {
            return;
        }
    } catch (e) {
        return;
    }

    // Wire up Generate button
    const generateBtn = document.getElementById('qa-generate-btn');
    if (generateBtn) {
        generateBtn.addEventListener('click', handleQAGenerate);
    }

    // Back button is wired dynamically via onclick in showRunDetail/showRunDocument
    const backBtn = document.getElementById('qa-back-btn');
    if (backBtn) backBtn.onclick = () => showRunList();

    // Load existing runs
    await loadQARuns();
}

/**
 * Load and render QA run list
 */
async function loadQARuns() {
    try {
        const res = await fetch(`${API_BASE}/api/qa/runs`);
        const data = await res.json();

        const runList = document.getElementById('qa-run-list');
        const emptyState = document.getElementById('qa-empty');
        if (!runList) return;

        // Clear existing cards (keep empty state)
        runList.querySelectorAll('.qa-run-card').forEach(c => c.remove());

        if (!data.runs || data.runs.length === 0) {
            if (emptyState) emptyState.style.display = '';
            return;
        }

        if (emptyState) emptyState.style.display = 'none';

        // Render run cards (newest first)
        const runs = data.runs.sort((a, b) => new Date(b.created_at) - new Date(a.created_at));
        for (const run of runs) {
            const card = createRunCard(run);
            runList.appendChild(card);
        }

        // Start polling if any run is processing
        const hasActive = runs.some(r => r.status === 'processing');
        if (hasActive) {
            startQAPoll();
        }
    } catch (e) {
        console.error('Failed to load QA runs:', e);
    }
}

/**
 * Create a run card element
 */
function createRunCard(run) {
    const card = document.createElement('div');
    card.className = `qa-run-card ${run.status}`;
    card.dataset.runId = run.id;

    const statusLabel = run.status === 'processing' ? 'Processing...'
        : run.status === 'completed' ? 'Completed'
        : run.status === 'failed' ? 'Failed'
        : run.status;

    const statsText = run.status === 'completed'
        ? ` · ${run.scenario_count || '?'} scenarios · ${run.test_case_count || '?'} cases`
        : '';

    const timeText = formatTimeAgo(run.created_at);

    const killBtn = run.status === 'processing'
        ? `<button class="ctrl-btn-xs danger qa-action-btn qa-kill-btn" data-run-id="${run.id}" title="Stop this run">Kill</button>`
        : '';
    const deleteBtn = `<button class="ctrl-btn-xs qa-action-btn qa-delete-btn" data-run-id="${run.id}" title="Delete this run">Del</button>`;

    // Extract only the first/main ticket summary (before any " | " separator)
    const mainSummary = run.jira_summary ? run.jira_summary.split(' | ')[0].replace(/^[A-Z][A-Z0-9]+-\d+:\s*/, '') : '';
    const titleText = mainSummary
        ? `${escapeHtml(run.jira_keys)} — ${escapeHtml(mainSummary)}`
        : escapeHtml(run.jira_keys);

    card.innerHTML = `
        <div class="qa-run-header">
            <div class="qa-run-title">${titleText}</div>
            <div class="qa-run-actions">${killBtn}${deleteBtn}</div>
        </div>
        <div class="qa-run-meta">
            <span class="qa-run-status ${run.status}">${statusLabel}</span>
            <span class="qa-run-stats">${statsText}</span>
            <span class="qa-run-time">${timeText}</span>
        </div>
    `;

    // Click card to view detail (but not if clicking action buttons)
    card.addEventListener('click', (e) => {
        if (e.target.closest('.qa-action-btn')) return;
        showRunDetail(run.id);
    });

    // Kill button handler
    const killBtnEl = card.querySelector('.qa-kill-btn');
    if (killBtnEl) {
        killBtnEl.addEventListener('click', (e) => {
            e.stopPropagation();
            killQARun(run.id);
        });
    }

    // Delete button handler
    const deleteBtnEl = card.querySelector('.qa-delete-btn');
    if (deleteBtnEl) {
        deleteBtnEl.addEventListener('click', (e) => {
            e.stopPropagation();
            deleteQARun(run.id);
        });
    }

    return card;
}

/**
 * Handle Generate QA Plan button click
 */
async function handleQAGenerate() {
    const jiraInput = document.getElementById('qa-jira-keys');
    const confluenceInput = document.getElementById('qa-confluence-urls');
    const instructionsInput = document.getElementById('qa-instructions');
    const statusEl = document.getElementById('qa-status');
    const generateBtn = document.getElementById('qa-generate-btn');

    const jiraRaw = jiraInput.value.trim();
    if (!jiraRaw) {
        statusEl.textContent = 'Jira tickets required';
        statusEl.style.color = 'var(--color-accent)';
        jiraInput.focus();
        return;
    }

    // Parse: extract ticket keys from URLs or raw keys
    const jiraKeys = parseJiraInput(jiraRaw);
    if (!jiraKeys) {
        statusEl.textContent = 'No valid Jira keys found';
        statusEl.style.color = 'var(--color-accent)';
        jiraInput.focus();
        return;
    }

    // Update input to show cleaned keys
    jiraInput.value = jiraKeys;

    // Run preflight checks with visible overlay
    generateBtn.disabled = true;
    generateBtn.textContent = 'Checking...';
    statusEl.textContent = '';

    const preflightPassed = await runQAPreflight();
    if (!preflightPassed) {
        generateBtn.disabled = false;
        generateBtn.textContent = 'Generate QA Plan';
        return;
    }

    const confluenceUrls = confluenceInput.value.trim();
    const instructions = instructionsInput.value.trim();

    generateBtn.textContent = 'Generating...';
    statusEl.textContent = 'Launching...';

    try {
        const response = await fetch(`${API_BASE}/api/qa/generate`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({
                jira_keys: jiraKeys,
                confluence_urls: confluenceUrls,
                instructions: instructions
            })
        });

        const data = await response.json();

        if (data.success) {
            statusEl.textContent = 'QA pipeline launched';
            statusEl.style.color = 'var(--color-success, #00ff88)';
            showToast('QA pipeline launched', 'success');

            // Reload runs to show the new one
            await loadQARuns();
            startQAPoll();

            // Clear form
            jiraInput.value = '';
            confluenceInput.value = '';
            instructionsInput.value = '';
        } else {
            statusEl.textContent = data.error || 'Launch failed';
            statusEl.style.color = 'var(--color-accent)';
        }
    } catch (error) {
        console.error('QA generate error:', error);
        statusEl.textContent = error.message;
        statusEl.style.color = 'var(--color-accent)';
    } finally {
        generateBtn.disabled = false;
        generateBtn.textContent = 'Generate QA Plan';
    }
}

/**
 * Run preflight checks with visible overlay in the main content area.
 * Returns true if all checks pass, false otherwise.
 */
async function runQAPreflight() {
    const overlay = document.getElementById('qa-preflight-overlay');
    const titleEl = document.getElementById('qa-preflight-title');
    const checksEl = document.getElementById('qa-preflight-checks');

    if (!overlay) return true; // No overlay element, skip

    // Show overlay with "checking" state
    overlay.style.display = '';
    titleEl.textContent = 'Running preflight checks...';
    checksEl.innerHTML = '<div class="qa-preflight-check"><div class="qa-preflight-led checking"></div><span class="qa-preflight-label">Checking prerequisites...</span></div>';

    try {
        const res = await fetch(`${API_BASE}/api/qa/preflight`);
        const preflight = await res.json();
        const checks = preflight.checks || [];

        if (checks.length === 0) {
            // No checks defined, pass through
            overlay.style.display = 'none';
            return true;
        }

        // Render each check result
        let html = '';
        for (const check of checks) {
            const ledClass = check.passed ? 'pass' : 'fail';
            const statusText = check.passed ? 'PASS' : 'FAIL';
            const statusClass = check.passed ? 'pass' : 'fail';

            html += `<div class="qa-preflight-check">
                <div class="qa-preflight-led ${ledClass}"></div>
                <span class="qa-preflight-label">${escapeHtml(check.message || check.name)}</span>
                <span class="qa-preflight-status ${statusClass}">${statusText}</span>
            </div>`;

            if (!check.passed && check.hint) {
                html += `<div class="qa-preflight-hint">${escapeHtml(check.hint)}</div>`;
            }
        }

        // Add result summary
        if (preflight.success) {
            html += '<div class="qa-preflight-result pass">All systems go</div>';
        } else {
            html += '<div class="qa-preflight-result fail">Preflight failed — fix the issues above and retry</div>';
        }

        checksEl.innerHTML = html;
        titleEl.textContent = 'Preflight Results';

        if (preflight.success) {
            // Auto-hide after brief display
            await new Promise(r => setTimeout(r, 1200));
            overlay.style.display = 'none';
            return true;
        } else {
            // Keep overlay visible for 4s then hide
            await new Promise(r => setTimeout(r, 4000));
            overlay.style.display = 'none';
            return false;
        }
    } catch (e) {
        console.error('Preflight error:', e);
        overlay.style.display = 'none';
        return true; // Graceful degradation — proceed if preflight endpoint fails
    }
}

/**
 * Delete a QA run (metadata + output files)
 */
async function deleteQARun(runId) {
    if (!confirm('Delete this QA run and its output files?')) return;
    try {
        const res = await fetch(`${API_BASE}/api/qa/delete?run=${encodeURIComponent(runId)}`, {
            method: 'POST'
        });
        const data = await res.json();
        if (data.success) {
            showToast('QA run deleted', 'success');
            await loadQARuns();
        } else {
            showToast(data.error || 'Failed to delete', 'error');
        }
    } catch (e) {
        console.error('Delete QA run error:', e);
    }
}

/**
 * Kill/stop a QA run
 */
async function killQARun(runId) {
    try {
        const res = await fetch(`${API_BASE}/api/qa/kill?run=${encodeURIComponent(runId)}`, {
            method: 'POST'
        });
        const data = await res.json();
        if (data.success) {
            showToast('QA run stopped', 'success');
            await loadQARuns();
        } else {
            showToast(data.error || 'Failed to stop', 'error');
        }
    } catch (e) {
        console.error('Kill QA run error:', e);
    }
}

/**
 * Show detail view for a specific run
 */
// Store current run data and ID for sub-navigation
let currentRunData = null;
let currentRunId = null;
let qaProgressPollTimer = null;

/**
 * Show run overview with sub-cards (Level 2)
 */
async function showRunDetail(runId) {
    const runList = document.getElementById('qa-run-list');
    const runDetail = document.getElementById('qa-run-detail');
    const detailTitle = document.getElementById('qa-detail-title');
    const detailContent = document.getElementById('qa-detail-content');
    const detailLogs = document.getElementById('qa-detail-logs');
    const toggle = document.getElementById('qa-detail-toggle');

    if (!runList || !runDetail) return;

    runList.style.display = 'none';
    runDetail.style.display = '';

    // Reset back button to go to run list (Level 2 → Level 1)
    const backBtn = document.getElementById('qa-back-btn');
    if (backBtn) backBtn.onclick = () => showRunList();

    detailTitle.textContent = 'Loading...';
    detailContent.innerHTML = '';

    try {
        const res = await fetch(`${API_BASE}/api/qa/results?run=${encodeURIComponent(runId)}`);
        const data = await res.json();
        currentRunData = data;
        currentRunId = runId;

        detailTitle.textContent = data.jira_keys || runId;

        const isProcessing = data.status === 'processing';

        // Hide TOC and search (shown only in document view)
        const toc = document.getElementById('qa-toc');
        if (toc) toc.style.display = 'none';
        const searchBox = document.getElementById('qa-search-box');
        if (searchBox) searchBox.style.display = 'none';
        const searchInput = document.getElementById('qa-search-input');
        if (searchInput) searchInput.value = '';

        // Show/hide progress bar
        renderProgress(data.progress, isProcessing);

        // Show/hide coverage bar
        renderCoverage(data);

        // Show/hide download button
        const dlBtn = document.getElementById('qa-download-btn');
        if (dlBtn) {
            dlBtn.style.display = (data.status === 'completed') ? '' : 'none';
            dlBtn.onclick = () => downloadQARun(currentRunId);
        }

        // Show/hide re-run button
        const rerunBtn = document.getElementById('qa-rerun-btn');
        if (rerunBtn) {
            rerunBtn.style.display = (data.status === 'completed' || data.status === 'failed') ? '' : 'none';
            rerunBtn.onclick = () => rerunQA(data);
        }

        // Hide copy button (shown only in document view)
        const copyBtn = document.getElementById('qa-copy-btn');
        if (copyBtn) copyBtn.style.display = 'none';

        // Build artifacts view (sub-cards)
        renderArtifactCards(data);

        // Start polling for updates if processing
        if (isProcessing) {
            startQAProgressPoll(runId);
        } else {
            stopQAProgressPoll();
        }

    } catch (e) {
        detailContent.innerHTML = '<div class="qa-empty-state"><div class="qa-empty-text">Failed to load results</div></div>';
    }
}

/**
 * Render artifact sub-cards in the content area, grouped by system
 */
function renderArtifactCards(data) {
    const detailContent = document.getElementById('qa-detail-content');
    if (!detailContent) return;

    // Check if there are per-system groups with actual content
    const systemsWithContent = (data.systems || []).filter(s => s.test_plan || (s.test_cases && s.test_cases.length > 0));
    const isMultiSystem = systemsWithContent.length > 0;
    const hasOverallPlan = !!data.test_plan;
    const hasOverallCases = data.test_cases && data.test_cases.length > 0;
    const hasAnyContent = hasOverallPlan || hasOverallCases || isMultiSystem;

    let html = '<div class="qa-subcards">';

    const hasUatPlan = !!data.uat_plan;

    // --- Overall section ---
    if (hasOverallPlan || hasOverallCases || hasUatPlan) {
        html += '<div class="qa-system-group">';
        // Only show "Overall" header when there are per-system groups too
        if (isMultiSystem) {
            html += '<div class="qa-system-header"><span class="qa-system-name">Overall</span></div>';
        }

        if (hasOverallPlan) {
            const planTitle = isMultiSystem ? 'Overall Test Plan' : 'Test Plan';
            const planDesc = isMultiSystem ? 'High-level test strategy across all systems' : 'Test strategy, scenarios, and coverage';
            html += `<div class="qa-subcard" data-doc="test-plan">
                <div class="qa-subcard-icon">TP</div>
                <div class="qa-subcard-info">
                    <div class="qa-subcard-title">${planTitle}</div>
                    <div class="qa-subcard-desc">${planDesc}</div>
                </div>
            </div>`;
        }

        if (hasUatPlan) {
            const uatTitle = isMultiSystem ? 'Overall UAT Plan' : 'UAT Plan';
            html += `<div class="qa-subcard qa-subcard-uat" data-doc="uat-plan">
                <div class="qa-subcard-icon qa-icon-uat">UAT</div>
                <div class="qa-subcard-info">
                    <div class="qa-subcard-title">${uatTitle}</div>
                    <div class="qa-subcard-desc">Business-friendly test scenarios for non-technical testers</div>
                </div>
            </div>`;
        }

        if (hasOverallCases) {
            for (const tc of data.test_cases) {
                const displayName = tc.name.replace(/-/g, ' ').replace(/\b\w/g, c => c.toUpperCase());
                const icon = isMultiSystem ? 'E2E' : 'TC';
                const desc = isMultiSystem ? 'Cross-system end-to-end test cases' : 'Detailed test cases with steps and expected results';
                html += `<div class="qa-subcard" data-doc="tc:${escapeHtml(tc.name)}">
                    <div class="qa-subcard-icon">${icon}</div>
                    <div class="qa-subcard-info">
                        <div class="qa-subcard-title">${escapeHtml(displayName)}</div>
                        <div class="qa-subcard-desc">${desc}</div>
                    </div>
                </div>`;
            }
        }

        html += '</div>';
    }

    // --- Per-system sections ---
    if (isMultiSystem) {
        for (const sys of data.systems) {
            const hasPlan = !!sys.test_plan;
            const hasCases = sys.test_cases && sys.test_cases.length > 0;
            if (!hasPlan && !hasCases) continue;

            const badge = sys.jira_project ? ` <span class="qa-system-badge">${escapeHtml(sys.jira_project)}</span>` : '';
            const tcCount = hasCases ? sys.test_cases.length : 0;
            const tcBadge = tcCount > 0 ? `<span class="qa-system-tc-count">${tcCount} TC</span>` : '';
            html += '<div class="qa-system-group">';
            html += `<div class="qa-system-header"><span class="qa-system-collapse">&#9660;</span><span class="qa-system-name">${escapeHtml(sys.name)}</span>${badge}${tcBadge}</div>`;

            if (hasPlan) {
                html += `<div class="qa-subcard" data-doc="sys:${escapeHtml(sys.id)}:test-plan">
                    <div class="qa-subcard-icon">TP</div>
                    <div class="qa-subcard-info">
                        <div class="qa-subcard-title">${escapeHtml(sys.name)} Test Plan</div>
                        <div class="qa-subcard-desc">System-specific test strategy and scenarios</div>
                    </div>
                </div>`;
            }

            if (sys.uat_plan) {
                html += `<div class="qa-subcard qa-subcard-uat" data-doc="sys:${escapeHtml(sys.id)}:uat-plan">
                    <div class="qa-subcard-icon qa-icon-uat">UAT</div>
                    <div class="qa-subcard-info">
                        <div class="qa-subcard-title">${escapeHtml(sys.name)} UAT Plan</div>
                        <div class="qa-subcard-desc">Business-friendly scenarios for non-technical testers</div>
                    </div>
                </div>`;
            }

            if (hasCases) {
                for (const tc of sys.test_cases) {
                    const displayName = tc.name.replace(/-/g, ' ').replace(/\b\w/g, c => c.toUpperCase());
                    html += `<div class="qa-subcard" data-doc="sys:${escapeHtml(sys.id)}:tc:${escapeHtml(tc.name)}">
                        <div class="qa-subcard-icon">TC</div>
                        <div class="qa-subcard-info">
                            <div class="qa-subcard-title">${escapeHtml(displayName)}</div>
                            <div class="qa-subcard-desc">Detailed test cases for ${escapeHtml(sys.name)}</div>
                        </div>
                    </div>`;
                }
            }

            html += '</div>';
        }
    }

    if (!hasAnyContent) {
        const isProcessing = data.status === 'processing';
        if (isProcessing) {
            html += '<div class="qa-empty-state"><div class="qa-empty-text">No artifacts yet</div><div class="qa-empty-hint">Check the Processes tab for detailed logs</div></div>';
        } else {
            html += '<div class="qa-empty-state"><div class="qa-empty-text">No documents</div><div class="qa-empty-hint">This run did not produce any output</div></div>';
        }
    }

    html += '</div>';
    detailContent.innerHTML = html;

    // Wire sub-card clicks
    detailContent.querySelectorAll('.qa-subcard').forEach(card => {
        card.addEventListener('click', () => {
            showRunDocument(card.dataset.doc);
        });
    });

    // Wire collapsible system group headers
    detailContent.querySelectorAll('.qa-system-header').forEach(header => {
        header.addEventListener('click', (e) => {
            if (e.target.closest('.qa-subcard')) return;
            const group = header.closest('.qa-system-group');
            if (group) group.classList.toggle('collapsed');
        });
    });
}

/**
 * Render coverage summary bar
 */
function renderCoverage(data) {
    const bar = document.getElementById('qa-coverage-bar');
    if (!bar) return;

    if (!data.test_plan || data.status === 'processing') {
        bar.style.display = 'none';
        return;
    }

    // Count scenarios and test cases from all sources
    let scenarioCount = 0;
    let testCaseCount = 0;

    // Count from overall test plan (scenario IDs like I-01, E-01, UAT-01)
    if (data.test_plan) {
        const matches = data.test_plan.match(/\b(I-\d+|E-\d+|UAT-\d+)\b/g);
        if (matches) scenarioCount = [...new Set(matches)].length;
    }

    // Count test cases from all sources
    if (data.test_cases) {
        for (const tc of data.test_cases) {
            const tcMatches = tc.content.match(/\bTC-(I|E|UAT)-\d+/g);
            if (tcMatches) testCaseCount += tcMatches.length;
        }
    }
    if (data.systems) {
        for (const sys of data.systems) {
            if (sys.test_cases) {
                for (const tc of sys.test_cases) {
                    const tcMatches = tc.content.match(/\bTC-(I|E|UAT)-\d+/g);
                    if (tcMatches) testCaseCount += tcMatches.length;
                }
            }
        }
    }

    const systemCount = (data.systems || []).filter(s => s.test_plan).length;

    // Build coverage bar
    const pct = scenarioCount > 0 ? Math.min(100, Math.round((testCaseCount / scenarioCount) * 100)) : 0;
    const quality = pct >= 80 ? 'good' : 'partial';

    let html = `<span class="qa-coverage-label">Coverage</span>`;
    html += `<div class="qa-coverage-track"><div class="qa-coverage-fill ${quality}" style="width:${pct}%"></div></div>`;
    html += `<span class="qa-coverage-value ${quality}">${scenarioCount} scenarios · ${testCaseCount} cases</span>`;
    if (systemCount > 0) {
        html += `<span class="qa-coverage-label" style="margin-left:8px">${systemCount} systems</span>`;
    }

    bar.innerHTML = html;
    bar.style.display = '';
}

/**
 * Re-run QA with same inputs from a completed run
 */
async function rerunQA(runData) {
    // Get the original inputs from run metadata
    const jiraKeys = runData.jira_keys;
    if (!jiraKeys) return;

    // Pre-fill the sidebar form
    const jiraInput = document.getElementById('qa-jira-keys');
    const confluenceInput = document.getElementById('qa-confluence-urls');
    const instructionsInput = document.getElementById('qa-instructions');

    if (jiraInput) jiraInput.value = jiraKeys;
    // Fetch run metadata for confluence_urls and instructions
    try {
        const res = await fetch(`${API_BASE}/api/qa/runs`);
        const data = await res.json();
        const run = (data.runs || []).find(r => r.jira_keys === jiraKeys);
        if (run) {
            if (confluenceInput && run.confluence_urls) confluenceInput.value = run.confluence_urls;
            if (instructionsInput && run.instructions) instructionsInput.value = run.instructions;
        }
    } catch (e) {}

    // Switch back to run list and trigger generation
    showRunList();
    handleQAGenerate();
}

/**
 * Render the pipeline progress bar
 */
function renderProgress(progress, isProcessing) {
    const progressBar = document.getElementById('qa-progress-bar');
    const stepsEl = document.getElementById('qa-progress-steps');
    if (!progressBar || !stepsEl) return;

    if (!isProcessing || !progress || !progress.stages) {
        progressBar.style.display = 'none';
        return;
    }

    progressBar.style.display = '';
    let html = '';
    for (const stage of progress.stages) {
        const isCurrent = stage.id === progress.current_stage;
        const stateClass = stage.done ? 'done' : isCurrent ? 'active' : 'pending';
        const icon = stage.done ? '&#10003;' : isCurrent ? '&#9679;' : '&#9675;';
        const hasDetail = stage.id === 'systems' && stage.done && stage.detail && stage.detail.length > 0;
        const clickClass = hasDetail ? ' qa-progress-clickable' : '';

        html += `<div class="qa-progress-step ${stateClass}${clickClass}" ${hasDetail ? 'data-expandable="true"' : ''}>
            <span class="qa-progress-icon">${icon}</span>
            <span class="qa-progress-label">${escapeHtml(stage.label)}${hasDetail ? ` (${stage.detail.length})` : ''}</span>
        </div>`;

        if (hasDetail) {
            html += '<div class="qa-progress-detail" style="display:none">';
            for (const sys of stage.detail) {
                const badge = sys.jira_project ? `<span class="qa-system-badge">${escapeHtml(sys.jira_project)}</span>` : '';
                html += `<div class="qa-progress-detail-item">${badge} ${escapeHtml(sys.name)}</div>`;
            }
            html += '</div>';
        }
    }
    stepsEl.innerHTML = html;

    // Wire expandable steps
    stepsEl.querySelectorAll('[data-expandable]').forEach(step => {
        step.addEventListener('click', () => {
            const detail = step.nextElementSibling;
            if (detail && detail.classList.contains('qa-progress-detail')) {
                detail.style.display = detail.style.display === 'none' ? '' : 'none';
            }
        });
    });
}

/**
 * Start polling for progress updates
 */
function startQAProgressPoll(runId) {
    stopQAProgressPoll();

    qaProgressPollTimer = setInterval(async () => {
        if (currentRunId !== runId) {
            stopQAProgressPoll();
            return;
        }

        try {
            const res = await fetch(`${API_BASE}/api/qa/results?run=${encodeURIComponent(runId)}`);
            const data = await res.json();

            // Update progress bar
            renderProgress(data.progress, data.status === 'processing');

            // Refresh artifact cards if new content appeared
            const hadPlan = currentRunData && currentRunData.test_plan;
            const hadCases = currentRunData && currentRunData.test_cases ? currentRunData.test_cases.length : 0;
            const hadSystems = currentRunData && currentRunData.systems ? currentRunData.systems.length : 0;
            const nowHasPlan = data.test_plan;
            const nowHasCases = data.test_cases ? data.test_cases.length : 0;
            const nowHasSystems = data.systems ? data.systems.length : 0;

            if (nowHasPlan !== hadPlan || nowHasCases !== hadCases || nowHasSystems !== hadSystems) {
                currentRunData = data;
                renderArtifactCards(data);
            }

            // If completed, stop polling and do final refresh
            if (data.status !== 'processing') {
                stopQAProgressPoll();
                currentRunData = data;
                renderProgress(null, false);
                renderCoverage(data);
                renderArtifactCards(data);
            }
        } catch (e) {
            // Ignore poll errors
        }
    }, 3000);
}

/**
 * Stop progress polling
 */
function stopQAProgressPoll() {
    if (qaProgressPollTimer) {
        clearInterval(qaProgressPollTimer);
        qaProgressPollTimer = null;
    }
}

/**
 * Show a specific document from the run (Level 3)
 */
function showRunDocument(docKey) {
    const detailTitle = document.getElementById('qa-detail-title');
    const detailContent = document.getElementById('qa-detail-content');
    const backBtn = document.getElementById('qa-back-btn');

    if (!currentRunData || !detailContent) return;

    let markdown = '';
    let title = '';

    if (docKey === 'test-plan') {
        markdown = currentRunData.test_plan || '';
        title = 'Overall Test Plan';
    } else if (docKey === 'uat-plan') {
        markdown = currentRunData.uat_plan || '';
        title = 'UAT Plan';
    } else if (docKey.startsWith('sys:')) {
        // Per-system document: sys:{sysId}:test-plan or sys:{sysId}:tc:{name}
        const parts = docKey.split(':');
        const sysId = parts[1];
        const sys = (currentRunData.systems || []).find(s => s.id === sysId);
        if (sys) {
            if (parts[2] === 'test-plan') {
                markdown = sys.test_plan || '';
                title = `${sys.name} — Test Plan`;
            } else if (parts[2] === 'uat-plan') {
                markdown = sys.uat_plan || '';
                title = `${sys.name} — UAT Plan`;
            } else if (parts[2] === 'tc' && parts[3]) {
                const tc = (sys.test_cases || []).find(t => t.name === parts[3]);
                if (tc) {
                    markdown = tc.content;
                    title = `${sys.name} — ${parts[3].replace(/-/g, ' ').replace(/\b\w/g, c => c.toUpperCase())}`;
                }
            }
        }
    } else if (docKey.startsWith('tc:')) {
        const tcName = docKey.substring(3);
        const tc = (currentRunData.test_cases || []).find(t => t.name === tcName);
        if (tc) {
            markdown = tc.content;
            title = tcName.replace(/-/g, ' ').replace(/\b\w/g, c => c.toUpperCase());
        }
    }

    if (markdown) {
        detailTitle.textContent = title;
        detailContent.innerHTML = `<div class="doc-viewer">${markdownToHtml(markdown)}</div>`;

        // Show copy button
        const copyBtn = document.getElementById('qa-copy-btn');
        if (copyBtn) {
            copyBtn.style.display = '';
            copyBtn.onclick = () => {
                navigator.clipboard.writeText(markdown).then(() => {
                    copyBtn.textContent = 'Copied!';
                    setTimeout(() => { copyBtn.textContent = 'Copy'; }, 1500);
                });
            };
        }

        // Hide coverage bar in document view
        const coverageBar = document.getElementById('qa-coverage-bar');
        if (coverageBar) coverageBar.style.display = 'none';

        // Hide re-run/download in document view
        const rerunBtn = document.getElementById('qa-rerun-btn');
        if (rerunBtn) rerunBtn.style.display = 'none';
        const dlBtn = document.getElementById('qa-download-btn');
        if (dlBtn) dlBtn.style.display = 'none';

        // Build TOC from headings
        buildTOC(detailContent);

        // Show search box
        const searchBox = document.getElementById('qa-search-box');
        if (searchBox) searchBox.style.display = '';
        initDocSearch(detailContent, markdown);

        // Scroll to top of content
        detailContent.scrollTop = 0;
    }

    // Update back button to return to sub-card overview
    backBtn.onclick = (e) => {
        e.preventDefault();
        if (currentRunId) {
            showRunDetail(currentRunId);
        } else {
            showRunList();
        }
    };
}

/**
 * Return to run list view
 */
function showRunList() {
    currentRunData = null;
    currentRunId = null;
    stopQAProgressPoll();

    const runList = document.getElementById('qa-run-list');
    const runDetail = document.getElementById('qa-run-detail');
    const backBtn = document.getElementById('qa-back-btn');

    if (runList) runList.style.display = '';
    if (runDetail) runDetail.style.display = 'none';
    // Reset back button to default (go to run list)
    if (backBtn) backBtn.onclick = () => showRunList();
}

/**
 * Poll for active QA run updates
 */
function startQAPoll() {
    if (qaPollTimer) clearInterval(qaPollTimer);

    qaPollTimer = setInterval(async () => {
        try {
            const res = await fetch(`${API_BASE}/api/qa/runs`);
            const data = await res.json();

            if (!data.runs) return;

            const hasActive = data.runs.some(r => r.status === 'processing');

            // Update cards
            for (const run of data.runs) {
                const card = document.querySelector(`.qa-run-card[data-run-id="${run.id}"]`);
                if (card) {
                    card.className = `qa-run-card ${run.status}`;
                    const statusEl = card.querySelector('.qa-run-status');
                    const statsEl = card.querySelector('.qa-run-stats');
                    if (statusEl) {
                        statusEl.className = `qa-run-status ${run.status}`;
                        statusEl.textContent = run.status === 'processing' ? 'Processing...'
                            : run.status === 'completed' ? 'Completed'
                            : run.status === 'failed' ? 'Failed'
                            : run.status;
                    }
                    if (statsEl && run.status === 'completed') {
                        statsEl.textContent = ` · ${run.scenario_count || '?'} scenarios · ${run.test_case_count || '?'} cases`;
                    }
                }
            }

            if (!hasActive) {
                clearInterval(qaPollTimer);
                qaPollTimer = null;
                // Reload to ensure card order is correct
                await loadQARuns();
            }
        } catch (e) {
            // Ignore poll errors
        }
    }, 5000);
}

/**
 * Format a timestamp as relative time
 */
function formatTimeAgo(dateStr) {
    if (!dateStr) return '';
    const date = new Date(dateStr);
    const now = new Date();
    const diffMs = now - date;
    const diffSec = Math.floor(diffMs / 1000);
    const diffMin = Math.floor(diffSec / 60);
    const diffHr = Math.floor(diffMin / 60);
    const diffDay = Math.floor(diffHr / 24);

    if (diffSec < 60) return 'Just now';
    if (diffMin < 60) return `${diffMin}m ago`;
    if (diffHr < 24) return `${diffHr}h ago`;
    if (diffDay === 1) return 'Yesterday';
    if (diffDay < 7) return `${diffDay} days ago`;
    return date.toLocaleDateString();
}

/**
 * Parse Jira input — extract ticket keys from URLs or raw keys.
 * Supports: "PROJ-123", "PROJ-123, PROJ-456", "https://site.atlassian.net/browse/PROJ-123"
 * Returns cleaned comma-separated keys or null if none found.
 */
function parseJiraInput(raw) {
    if (!raw) return null;

    // Split by commas, spaces, or newlines
    const parts = raw.split(/[,\s\n]+/).filter(Boolean);
    const keys = [];

    for (const part of parts) {
        const trimmed = part.trim();

        // Try to extract from URL: https://site.atlassian.net/browse/PROJ-123
        const urlMatch = trimmed.match(/\/browse\/([A-Z][A-Z0-9]+-\d+)/i);
        if (urlMatch) {
            keys.push(urlMatch[1].toUpperCase());
            continue;
        }

        // Try raw key pattern: PROJ-123
        const keyMatch = trimmed.match(/^([A-Z][A-Z0-9]+-\d+)$/i);
        if (keyMatch) {
            keys.push(keyMatch[1].toUpperCase());
            continue;
        }
    }

    return keys.length > 0 ? keys.join(', ') : null;
}

/**
 * Escape HTML entities
 */
function escapeHtml(str) {
    if (!str) return '';
    return str.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
}

// Markdown rendering uses the shared markdownToHtml() from markdown.js
// with doc-viewer CSS class for consistent Product-tab styling

/**
 * Build table of contents from headings in the document
 */
function buildTOC(contentEl) {
    const toc = document.getElementById('qa-toc');
    const tocList = document.getElementById('qa-toc-list');
    if (!toc || !tocList || !contentEl) return;

    const headings = contentEl.querySelectorAll('h1, h2, h3');
    if (headings.length < 3) {
        toc.style.display = 'none';
        return;
    }

    tocList.innerHTML = '';
    headings.forEach((h, i) => {
        const id = `qa-heading-${i}`;
        h.id = id;

        const level = parseInt(h.tagName.substring(1));
        const item = document.createElement('a');
        item.className = `qa-toc-item level-${level}`;
        item.textContent = h.textContent;
        item.onclick = (e) => {
            e.preventDefault();
            h.scrollIntoView({ behavior: 'smooth', block: 'start' });
            tocList.querySelectorAll('.qa-toc-item').forEach(t => t.classList.remove('active'));
            item.classList.add('active');
        };
        tocList.appendChild(item);
    });

    toc.style.display = '';

    // Highlight current section on scroll
    const observer = new IntersectionObserver((entries) => {
        entries.forEach(entry => {
            if (entry.isIntersecting) {
                const id = entry.target.id;
                tocList.querySelectorAll('.qa-toc-item').forEach((item, idx) => {
                    item.classList.toggle('active', `qa-heading-${idx}` === id);
                });
            }
        });
    }, { rootMargin: '-20% 0px -70% 0px' });

    headings.forEach(h => observer.observe(h));
}

/**
 * Initialize document search
 */
let searchMarks = [];
let searchIndex = -1;

function initDocSearch(contentEl, markdown) {
    const input = document.getElementById('qa-search-input');
    const countEl = document.getElementById('qa-search-count');
    const prevBtn = document.getElementById('qa-search-prev');
    const nextBtn = document.getElementById('qa-search-next');
    if (!input) return;

    input.value = '';
    if (countEl) countEl.textContent = '';
    searchMarks = [];
    searchIndex = -1;

    input.oninput = () => {
        clearSearchMarks(contentEl);
        const query = input.value.trim();
        if (query.length < 2) {
            if (countEl) countEl.textContent = '';
            return;
        }
        highlightSearch(contentEl, query);
        if (countEl) {
            countEl.textContent = searchMarks.length > 0 ? `${searchIndex + 1}/${searchMarks.length}` : '0';
        }
    };

    if (prevBtn) prevBtn.onclick = () => navigateSearch(-1, contentEl, countEl);
    if (nextBtn) nextBtn.onclick = () => navigateSearch(1, contentEl, countEl);
}

function highlightSearch(el, query) {
    searchMarks = [];
    searchIndex = -1;
    const walker = document.createTreeWalker(el, NodeFilter.SHOW_TEXT);
    const textNodes = [];
    while (walker.nextNode()) textNodes.push(walker.currentNode);

    const lowerQuery = query.toLowerCase();
    for (const node of textNodes) {
        const text = node.textContent;
        const lowerText = text.toLowerCase();
        let idx = lowerText.indexOf(lowerQuery);
        if (idx === -1) continue;

        const parts = [];
        let lastIdx = 0;
        while (idx !== -1) {
            if (idx > lastIdx) parts.push(document.createTextNode(text.substring(lastIdx, idx)));
            const mark = document.createElement('mark');
            mark.textContent = text.substring(idx, idx + query.length);
            parts.push(mark);
            searchMarks.push(mark);
            lastIdx = idx + query.length;
            idx = lowerText.indexOf(lowerQuery, lastIdx);
        }
        if (lastIdx < text.length) parts.push(document.createTextNode(text.substring(lastIdx)));

        const parent = node.parentNode;
        for (const part of parts) parent.insertBefore(part, node);
        parent.removeChild(node);
    }

    if (searchMarks.length > 0) {
        searchIndex = 0;
        searchMarks[0].classList.add('current');
        searchMarks[0].scrollIntoView({ behavior: 'smooth', block: 'center' });
    }
}

function clearSearchMarks(el) {
    el.querySelectorAll('mark').forEach(m => {
        const parent = m.parentNode;
        parent.replaceChild(document.createTextNode(m.textContent), m);
        parent.normalize();
    });
    searchMarks = [];
    searchIndex = -1;
}

function navigateSearch(dir, contentEl, countEl) {
    if (searchMarks.length === 0) return;
    searchMarks[searchIndex].classList.remove('current');
    searchIndex = (searchIndex + dir + searchMarks.length) % searchMarks.length;
    searchMarks[searchIndex].classList.add('current');
    searchMarks[searchIndex].scrollIntoView({ behavior: 'smooth', block: 'center' });
    if (countEl) countEl.textContent = `${searchIndex + 1}/${searchMarks.length}`;
}

/**
 * Download all run artifacts as ZIP
 */
function downloadQARun(runId) {
    if (!runId) return;
    window.open(`${API_BASE}/api/qa/download?run=${encodeURIComponent(runId)}`, '_blank');
}

