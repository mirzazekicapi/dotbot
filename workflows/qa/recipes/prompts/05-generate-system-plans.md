# Generate Per-System Test Plans

Generate a self-contained test plan for each detected system. Only runs for multi-system tickets.

## Input

Read from the current run directory:
- `test-plan.md` — the overall technical test plan
- `jira-context-full.md` — full Jira requirements
- `systems.json` — detected systems

## Prerequisite

Check `systems.json` — if only ONE system is detected, this task should be skipped (the overall test plan IS the system plan).

## Output

For each system in `systems.json`:
- `{output_directory}/systems/{system-id}/test-plan.md`
- `{output_directory}/systems/{system-id}/uat-plan.md` (if system has user-facing scenarios)

## Instructions

For each system, generate a **self-contained test plan document** following the `write-test-plan` skill (all 14 sections), scoped entirely to that system:

1. **Executive Summary** — what this system's role is in the change
2. **Current State** — how THIS system works today before the change
3. **Change Description** — concrete changes being made in THIS system
4. **Scope** — what's in/out of scope for THIS system's testing
5. **Business Impact & Risk** — risks specific to this system
6. **Assumptions** — what this system's team assumes
7. **Dependencies** — other systems this one depends on
8. **Environment & Configuration** — environment setup specific to this system
9. **Test Data Requirements** — test data needed for this system's tests
10. **Test Strategy** — testing approach for this system
11. **Test Scenarios** — ONLY scenarios owned by and executable within this system
12. **Regression Scope** — existing functionality in THIS system at risk
13. **Open Questions** — unresolved items specific to this system
14. **Entry and Exit Criteria** — when this system's testing can start and when it's complete

### System isolation principle

A per-system test plan must only contain scenarios that the system's team can test **within their system's boundaries**. Ask: "Can this system's team execute this scenario using only their system's APIs, interfaces, and tools — without needing another team's system to be running or available?"

### Cross-system E2E scenarios

Do NOT duplicate cross-system E2E scenarios in per-system plans. Reference them: "See overall test plan E-xx for the full end-to-end flow."

### Per-system UAT plans

For each system that has user-facing scenarios, also generate a UAT plan using the `write-uat-plan` skill. Write to `{output_directory}/systems/{system-id}/uat-plan.md`. Skip systems with no user-facing UAT scenarios (e.g., backend-only systems).


