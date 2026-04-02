# Validate Coverage and Complete Pipeline

Validate traceability across all generated artifacts and write the completion summary.

## Input

Read from the current run directory:
- `test-plan.md` — overall test plan
- `uat-plan.md` — UAT plan
- `systems.json` — detected systems
- `systems/*/test-plan.md` — per-system plans (if multi-system)
- `systems/*/test-cases/*.md` — per-system test cases (if multi-system)
- `test-cases/*.md` — test cases (single-system or cross-system E2E)

## Validation Steps

### 1. Technical scenario traceability

1. List all scenario IDs from the overall test plan (I-xx, E-xx)
2. Check each I-xx and E-xx is referenced in at least one technical test case (per-system or cross-system E2E)
3. Report any unmapped scenarios

### 2. UAT coverage

1. List all user-facing acceptance criteria from the Jira context
2. Verify the UAT plan covers each one
3. Report any gaps

### 3. Per-system completeness (if multi-system)

For each detected system:
1. Verify it has a test-plan.md
2. Verify it has at least one test-cases file
3. Count scenarios and test cases

## Output

Write `{output_directory}/pipeline-complete.json`:
```json
{
  "completed_at": "2026-03-27T11:30:00Z",
  "systems_count": 4,
  "scenario_count": 98,
  "test_case_count": 45,
  "coverage": {
    "total_acceptance_criteria": 25,
    "mapped_to_scenarios": 25,
    "unmapped": 0
  },
  "validation_passed": true
}
```

Fill in actual counts. This file signals pipeline completion to the UI.

Also output a coverage summary to the console:
```
QA Pipeline Complete

Sources:
- Jira tickets: N issues fetched
- Confluence pages: N pages loaded

Systems detected: N
- {system-name} ({jira-project}): N scenarios, N test cases

Overall Test Plan: test-plan.md (I=N, E=N)
UAT Plan: uat-plan.md (UAT=N)

Per-System Plans: systems/
- {system-id}: N scenarios, N test cases

Coverage: N/N acceptance criteria mapped (100%)
```
