# Workflow: QA Pipeline

Generate a complete QA plan and detailed test cases from Jira requirements, Confluence documentation, and local product context.

## When to Invoke

Run this workflow when the user clicks "Generate QA Plan" in the QA tab. The input section below contains Jira ticket keys, optional Confluence page URLs, and optional additional instructions provided by the user.

## Input Parsing

The prompt includes a `## QA Generation Input` section with:
- **Run ID** — unique identifier for this QA run (e.g., `qa-run-20260324-143200`)
- **Output Directory** — where to write results (e.g., `.bot/workspace/product/qa-runs/qa-run-20260324-143200/`)
- **Jira Tickets (required)** — one or more Jira issue keys (e.g., `PROJ-123, PROJ-456`)
- **Confluence Pages (optional)** — Confluence page URLs
- **Additional Instructions (optional)** — free-text guidance from the user

Parse these from the prompt before proceeding. All output files must be written to the **Output Directory**, not the shared `.bot/workspace/product/` root.

## Execution Steps

### Step 1 — Fetch Jira requirements

For each Jira ticket key in the input, perform a comprehensive data gather following the same strategy as the kickstart-via-jira profile:

#### 1a. Main issue
Call `mcp__atlassian__getJiraIssue` with the issue key to retrieve:
- Summary, description, acceptance criteria
- Status, priority, labels, components
- Parent key (if exists)
- Issue links and relationships

#### 1b. Child issues
Search for child issues and epic children:
```
mcp__atlassian__searchJiraIssuesUsingJql
JQL: parent = {issue_key}
Limit: 50
```

#### 1c. Linked issues
Search for explicitly linked issues (blocks, is-blocked-by, relates-to, duplicates):
```
mcp__atlassian__searchJiraIssuesUsingJql
JQL: issuekey in linkedIssues({issue_key})
Limit: 50
```
Linked issues often define scope boundaries and negative test cases.

#### 1d. Parent context
If the main issue has a parent (epic or initiative):
- Fetch the parent with `mcp__atlassian__getJiraIssue` to understand the broader scope
- This helps identify what is OUT of scope for this ticket
- Optionally fetch sibling issues under the same parent (limit: 20) to understand related work

#### 1e. Comments
Fetch comments from the main issue using `mcp__atlassian__getJiraIssue` response or dedicated comment API:
- Look for hidden acceptance criteria discussed in comments
- Look for edge cases, clarifications, or scope changes
- Look for decisions that aren't reflected in the description

#### 1f. Compile context
Compile all fetched data into a structured context block:
- Main issue: key + summary + full description + acceptance criteria
- Child issues: key + summary for each
- Linked issues: key + summary + link type (blocks, relates-to, etc.)
- Parent context: key + summary + scope boundaries
- Comments: relevant excerpts with decisions or edge cases
- Total issues discovered: count

#### 1g. Save Jira context summary
Write a `jira-context.json` file to `{output_directory}/jira-context.json`:
```json
{
  "issues": [
    { "key": "PROJ-123", "summary": "Brief ticket title from Jira" },
    { "key": "PROJ-456", "summary": "Another ticket title" }
  ],
  "linked_count": 5,
  "child_count": 3,
  "parent_key": "PROJ-100"
}
```
This is used by the UI to show ticket descriptions on run cards.

### Step 2 — Fetch Confluence context

#### 2a. User-provided pages (if URLs given)
For each Confluence page URL in the input:

1. Extract the page ID or title from the URL
2. Call `mcp__atlassian__getConfluencePage` to retrieve the page content
3. Extract the body text, stripping HTML markup to plain text

#### 2b. Auto-search Confluence (proactive discovery)
Regardless of whether user provided URLs, search Confluence for pages related to the Jira tickets:
```
mcp__atlassian__searchConfluenceUsingCql
CQL: text ~ "{issue_key}" OR text ~ "{issue_summary}"
Limit: 10
```
For each discovered page (up to 5 most relevant):
- Fetch full content with `mcp__atlassian__getConfluencePage`
- Look for: specifications, design decisions, acceptance criteria, architecture notes

This proactive search catches related documentation the user may not know about.

Compile all Confluence context (user-provided + auto-discovered) as supplementary documentation.

### Step 3 — Load local product context (if available)

Read any existing product specification files:
```
.bot/workspace/product/mission.md             (if present)
.bot/workspace/product/tech-stack.md          (if present)
.bot/workspace/product/entity-model.md        (if present)
.bot/workspace/product/prd.md                 (if present)
.bot/workspace/product/change-request-*.md    (all, if present)
```

These supplement the Jira requirements with broader project context. If none exist, that's fine — Jira data is the primary source.

### Step 4 — Load task context (if available)

Call MCP tools to check if tasks exist:
```
task_list           → all tasks, grouped by status
task_get_stats      → counts by category and status
```

If tasks exist with acceptance criteria, include them as additional test coverage input.

### Step 5 — Detect affected systems

Identify all systems/components affected by this change **before** generating the test plan, so the plan can be organized by system from the start.

Use these strategies **in order**, stopping as soon as you have a confident system list:

**Strategy 1 — Jira project keys from child issues:**
Look at the child issues fetched in Step 1b. Different Jira project prefixes indicate different systems (e.g., child issues FE-1234, API-5678, BILL-910 indicate 3 systems: frontend, api, billing). Group by project key.

**Strategy 2 — System names in child epic summaries:**
Parse child issue summaries for system names in parentheses or brackets. Examples:
- `[PROJ-100] Feature X (Backend API)` → system "Backend API"
- `[PROJ-100] Feature X — Frontend` → system "Frontend"

**Strategy 3 — "Lead System" or component fields:**
Check the main Jira issue for custom fields like "Lead System", "Affected Systems", or the standard "Components" field.

**Strategy 4 — Agent inference (fallback):**
If no clear system indicators exist in Jira data, infer systems from:
- The requirements content (which services, APIs, UIs are mentioned)
- Architecture described in Confluence pages
- Acceptance criteria that reference specific system behaviors
- The overall test plan sections (which naturally group by system)

Write the detected systems to `{output_directory}/systems.json`:
```json
{
  "systems": [
    {
      "id": "lowercase-slug",
      "name": "Human Readable System Name",
      "jira_project": "PROJ",
      "jira_key": "PROJ-1234"
    }
  ],
  "lead_system": "lowercase-slug-of-lead"
}
```

- `id`: lowercase slug derived from project key or system name (e.g., "frontend", "api", "billing")
- `name`: human-readable system name
- `jira_project`: Jira project key prefix (if known, otherwise empty string)
- `jira_key`: the specific child epic/issue key for this system (if known, otherwise empty string)
- `lead_system`: the id of the primary/lead system (if detectable, otherwise null)

**If only ONE system is detected** (single-system ticket): write `systems.json` with one entry, then **skip Steps 8 and 9** entirely. Go straight to Step 9b — generate test cases directly into `{output_directory}/test-cases/` (same as legacy behavior). The per-system breakdown adds no value when there's only one system.

### Step 6 — Generate overall test plan

Apply the `write-test-plan` skill using all gathered context:
- Jira requirements as the primary input
- Detected systems from Step 5 (use to organize scenarios by system)
- Confluence pages as supplementary context
- Local product docs as project-level context
- User's additional instructions as guidance

The skill will:
- Map every Jira acceptance criterion to a test scenario
- Produce integration / E2E / UAT scenario tables organized by detected system
- Identify risk areas
- Define test data requirements
- Reference Jira issue keys in each scenario for traceability

Write the generated test plan to:
```
{output_directory}/test-plan.md
```

### Step 7 — Validate test plan coverage

After writing the test plan:

1. List all acceptance criteria from all fetched Jira issues
2. Verify each criterion appears in at least one scenario row
3. If any criterion is unmapped, add the missing scenario and note it

### Step 7b — Generate UAT plan

Apply the `write-uat-plan` skill using the overall test plan:
- Extract UAT-xx scenarios from the test plan
- Rewrite entirely in business-friendly language for non-technical testers
- If the test plan has no UAT scenarios, derive them from E2E scenarios

Write to:
```
{output_directory}/uat-plan.md
```

This UAT plan is a standalone document — a business user should be able to execute it without reading the technical test plan.

### Step 8 — Generate per-system test plans (multi-system only)

> **Skip this step if only one system was detected in Step 5.**

For each system in `systems.json`, generate a **self-contained test plan document** following the same structure as the `write-test-plan` skill (all 14 sections), but scoped entirely to that system.

1. Create directory: `{output_directory}/systems/{system-id}/`
2. Apply the `write-test-plan` skill scoped to this system's context
3. Write `{output_directory}/systems/{system-id}/test-plan.md`

Each per-system test plan must be a **standalone document** that a system team can use independently. It must include ALL 14 sections from the write-test-plan skill, scoped to this system:

1. **Executive Summary** — what this system's role is in the change, what's changing in THIS system specifically
2. **Current State** — how THIS system works today before the change
3. **Change Description** — concrete changes being made in THIS system (new endpoints, modified logic, new fields)
4. **Scope** — what's in/out of scope for THIS system's testing (not the overall initiative)
5. **Business Impact & Risk** — risks specific to this system
6. **Assumptions** — what this system's team assumes (e.g., "upstream API is deployed", "database migration applied")
7. **Dependencies** — other systems this one depends on, deployment order requirements
8. **Environment & Configuration** — environment setup specific to this system
9. **Test Data Requirements** — test data needed for this system's tests
10. **Test Strategy** — testing approach for this system
11. **Test Scenarios** — ONLY scenarios owned by and executable within this system
12. **Regression Scope** — existing functionality in THIS system at risk
13. **Open Questions** — unresolved items specific to this system
14. **Entry and Exit Criteria** — when this system's testing can start and when it's complete

**System isolation principle:** A per-system test plan must only contain scenarios that the system's team can test **within their system's boundaries**. Ask: "Can this system's team execute this scenario using only their system's APIs, interfaces, and tools — without needing another team's system to be running or available?"

**Cross-system E2E scenarios** (scenarios that span multiple systems end-to-end) should remain in the overall test plan only — do NOT duplicate them in per-system plans. Instead, each per-system plan should reference relevant E2E scenario IDs with a note like: "See overall test plan E-xx for the full end-to-end flow."

**Per-system UAT plans:** For each system that has UAT scenarios in its per-system test plan, also generate a UAT plan using the `write-uat-plan` skill. Write to `{output_directory}/systems/{system-id}/uat-plan.md`. Skip systems with no user-facing UAT scenarios (e.g., backend-only systems).

### Step 9 — Generate test cases (multi-system only)

> **Skip this step if only one system was detected in Step 5. Go to Step 9b instead.**

For each system detected in Step 5:

1. Apply the `write-test-cases` skill using that system's test plan
2. Generate detailed test cases with: preconditions, step-by-step procedure, expected results, test data, priority, tags
3. Tag each test case as automatable or manual-only
4. Write to: `{output_directory}/systems/{system-id}/test-cases/{group-slug}.md`

> **CRITICAL — System boundary isolation for test case steps:**
>
> Every step in a per-system test case must be executable **within that system only**. The system's QA team should be able to run these tests without depending on other systems being available.
>
> **DO:**
> - Use the system's own APIs, endpoints, and interfaces as the test entry point
> - Set up preconditions by seeding data directly (DB, config, fixtures, mocks) rather than going through other systems
> - Stub or mock external system responses when testing how THIS system handles them
> - Test THIS system's validation, error handling, and response formats
>
> **DO NOT:**
> - Include steps like "Submit via System X's UI" in System Y's test cases
> - Use another system as the trigger for testing THIS system's behavior
> - Include steps that require another team's system to be running
>
> **Example — API system test case:**
> - BAD: "1. Submit tax change via Portal UI → 2. Check API response" (this is an E2E test, not an API test)
> - GOOD: "1. POST /fiscal-status with valid payload → 2. Verify response format and status code → 3. Query DB to confirm pending state created"
>
> Steps that involve multiple systems belong in the **cross-system E2E test cases**, not per-system ones.

Then generate **cross-system E2E test cases**:
1. Extract E2E scenarios from the overall test plan
2. Generate detailed test cases for cross-system flows — these ARE the tests where steps span multiple systems (e.g., "Submit via CP → verify in API → check Titan DB")
3. Write to: `{output_directory}/test-cases/cross-system-e2e.md`

### Step 9b — Generate test cases (single-system shortcut)

> **Only run this step if exactly one system was detected in Step 5.**

Apply the `write-test-cases` skill using the overall test plan:
- Generate detailed test cases for ALL scenario groups in a **single file**
- Each test case includes: preconditions, step-by-step procedure, expected results, test data, priority, tags
- Tag each test case as automatable or manual-only
- Organize by scenario group within the file (use h2 headings per group)

Write all test cases to a **single file** (not one per group):
```
{output_directory}/test-cases/test-cases.md
```

Do NOT split into multiple files for single-system tickets. One consolidated file is easier for the team to work with.

### Step 10 — Validate traceability

After writing all test cases:

1. List all scenario IDs from the overall test plan (I-xx, E-xx, UAT-xx)
2. Check each ID is referenced in at least one test case (either per-system or cross-system E2E)
3. Report any gaps

### Step 11 — Report summary

Output the complete coverage summary:
```
QA Pipeline Complete

Sources:
- Jira tickets: N issues fetched
- Confluence pages: N pages loaded
- Local product docs: N files loaded
- Tasks with acceptance criteria: N

Systems detected: N
- {system-name} ({jira-project}): N scenarios, N test cases
- ...

Overall Test Plan: {output_directory}/test-plan.md
- Total scenarios: N (I=N, E=N, UAT=N)

Per-System Plans: {output_directory}/systems/
- {system-id}/test-plan.md: N scenarios
- ...

Test Cases:
- Cross-system E2E: {output_directory}/test-cases/cross-system-e2e.md
- Per-system: {output_directory}/systems/{system-id}/test-cases/
- Total test cases: N (automatable: N, manual: N)

Coverage: N/N acceptance criteria mapped (100%)
```

### Step 12 — Write completion marker

**This must be the LAST file written.** The UI uses this file to detect that the entire pipeline has finished (test plan + system detection + per-system plans + test cases are all complete).

Write `{output_directory}/pipeline-complete.json`:
```json
{
  "completed_at": "2026-03-27T11:30:00Z",
  "systems_count": 4,
  "scenario_count": 98,
  "test_case_count": 45
}
```

Fill in actual counts from the pipeline run. Do NOT write this file until ALL previous steps (including test case generation) are finished.

### Step 13 — Commit (if in autonomous mode)

If running inside an autonomous execution session, commit all generated files:
```
docs: generate QA plan and test cases from Jira requirements

Sources: {comma-separated Jira keys}
Systems: {comma-separated system names}
Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>
```

If running interactively, present the summary and let the operator decide whether to commit.

## Anti-Patterns

- **Do not skip Jira data** — Jira tickets are the primary requirements source; always fetch them
- **Do not generate the test plan from local docs alone** — Jira acceptance criteria are the authoritative requirements
- **Do not leave acceptance criteria unmapped** — every Jira criterion must trace to a scenario ID
- **Do not generate test cases without a test plan** — the plan must exist first for traceability
- **Do not duplicate E2E scenarios** — cross-system E2E scenarios live in the overall plan only; per-system plans reference them
- **Do not run test automation tasks (workflow 06) from this pipeline** — automation is a separate step triggered independently
- **Do not hardcode system names** — detect systems dynamically from Jira data; the same workflow must work for any project
