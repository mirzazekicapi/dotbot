# Generate Overall Test Plan

Generate a comprehensive technical QA test plan from the gathered Jira context and detected systems.

## Input

Read from the current run directory:
- `jira-context-full.md` — full Jira requirements, Confluence excerpts, local docs
- `jira-context.json` — issue summary data
- `systems.json` — detected systems

## Output

Write `{output_directory}/test-plan.md`

## Instructions

Apply the `write-test-plan` skill (read `.bot/workflows/qa/recipes/skills/write-test-plan/SKILL.md`) using all gathered context:
- Jira requirements as the primary input
- Detected systems from `systems.json` (organize scenarios by system)
- Confluence pages as supplementary context
- Local product docs as project-level context
- User's additional instructions as guidance

The skill defines a 14-section structure. Follow it exactly.

## Validation

After writing the test plan:
1. List all acceptance criteria from all fetched Jira issues
2. Verify each criterion appears in at least one scenario row (I-xx or E-xx)
3. If any criterion is unmapped, add the missing scenario and note it

## Anti-Patterns

- Do NOT include UAT scenarios (UAT-xx) — those belong in the separate UAT Plan
- Do not leave acceptance criteria unmapped
- Do not generate from local docs alone — Jira acceptance criteria are authoritative
