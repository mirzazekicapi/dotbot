# Workflow: Generate Test Cases

Expand the high-level test plan scenarios into detailed, executable test case documents.

## When to Invoke

Run this workflow **after**:
- `04-plan-test-plan.md` has been executed and `.bot/workspace/product/test-plan.md` exists

Run this workflow **before** test automation tasks are created (workflow 06).

## Prerequisites Check

Before generating test cases, verify:

1. **Test plan exists** — confirm `.bot/workspace/product/test-plan.md` is present and contains scenario tables
2. **Product specifications exist** — at least one of: `mission.md`, `entity-model.md`, PRD, or change request

If either is missing, stop. Output a gap report:
```
## Prerequisites not met

- [ ] Test plan: <found / NOT FOUND>
- [ ] Product specifications: <found / NOT FOUND>

Action required: run workflow 04 (plan-test-plan) before generating test cases.
```

## Execution Steps

### Step 1 — Load product context

Read all available specification files:
```
.bot/workspace/product/test-plan.md           (required)
.bot/workspace/product/mission.md
.bot/workspace/product/tech-stack.md
.bot/workspace/product/entity-model.md
.bot/workspace/product/task-groups.json
.bot/workspace/product/prd.md                 (if present)
.bot/workspace/product/change-request-*.md    (all, if present)
```

### Step 2 — Load task context

Call MCP tools to pull the live task queue:
```
task_list           → all tasks, grouped by status
task_get_stats      → counts by category and status
```

For each task group, collect:
- Task names and descriptions
- Acceptance criteria
- Categories and effort estimates

### Step 3 — Extract scenarios from test plan

Parse `test-plan.md` and extract all scenario blocks:
- Integration scenarios (I-01, I-02, ...)
- E2E / Acceptance scenarios (E-01, E-02, ...)
- UAT scenarios (UAT-01, UAT-02, ...)

Group scenarios by task group.

### Step 4 — Invoke write-test-cases skill

Apply the `write-test-cases` skill for each task group using:
- The group's scenarios from the test plan
- The group's acceptance criteria from tasks
- Product context for realistic test data and edge cases

The skill will:
- Expand each scenario into one or more detailed test cases
- Assign test case IDs (TC-I-01, TC-E-01, TC-UAT-01, etc.)
- Define step-by-step procedures with expected results
- Classify priority (P1-P4) and automatable vs. manual
- Tag each test case (api, database, auth, ui, e2e, manual, regression, smoke)

### Step 5 — Write output

Write one file per task group to:
```
.bot/workspace/product/test-cases/{group-id}-{group-slug}.md
```

If the `test-cases/` directory does not exist, create it.

### Step 6 — Validate traceability

After writing all test case files, perform a coverage cross-check:

1. List all scenario IDs from `test-plan.md` (I-xx, E-xx, UAT-xx)
2. List all test case IDs from `test-cases/*.md` files
3. Verify every scenario ID is referenced by at least one test case
4. If any scenario is unmapped, add the missing test case and note it was added during validation

### Step 7 — Report

Output the coverage summary:
```
Test cases written to: .bot/workspace/product/test-cases/

Coverage summary:
- Task groups covered: N
- Total scenarios from test plan: N
- Mapped to test cases: N  ← must equal total scenarios
- Total test cases generated: N
  - Integration (TC-I-xx): N
  - E2E / Acceptance (TC-E-xx): N
  - UAT (TC-UAT-xx): N
- Automatable: N
- Manual-only: N
- By priority: P1=N, P2=N, P3=N, P4=N
- Unmapped scenarios fixed during validation: N
```

### Step 8 — Commit (if in autonomous mode)

If running inside an autonomous execution session, commit the test case files:
```
docs: generate detailed test cases from test plan

[task:XXXXXXXX]
Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>
```

If running interactively, present the summary and let the operator decide whether to commit.

## Integration Points

| When | How |
|------|-----|
| After test plan generation (04) | Run this workflow to expand scenarios into executable test cases |
| After a change request updates the test plan | Re-run this workflow to generate test cases for new/updated scenarios |
| Before test automation (06) | Test cases must exist before automation tasks can be created |

## Anti-Patterns

- **Do not generate test cases without a test plan** — scenarios must exist first for traceability
- **Do not regenerate all test cases on every run** — only generate for new or updated scenario groups
- **Do not skip the traceability validation** — every scenario must map to at least one test case
- **Do not mix concerns** — test cases document WHAT to test; test automation (workflow 06) handles HOW to automate
