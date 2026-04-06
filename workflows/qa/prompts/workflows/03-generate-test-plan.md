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

Apply the `write-test-plan` skill (read `.bot/workflows/qa/prompts/skills/write-test-plan/SKILL.md`) using all gathered context:
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

## Knowledge Base (optional)

If `{knowledge_base_path}` is not empty, for each detected system read the following files if they exist:
- `{knowledge_base_path}/projects/{system-id}/knowledge/application-summary.md` — system architecture, domain terms, API patterns
- `{knowledge_base_path}/projects/{system-id}/skills/write-test-plan/SKILL.md` — project-specific test plan guidance (extends the generic skill)
- `{knowledge_base_path}/projects/{system-id}/history/*.md` — historical test cases showing real navigation flows, UI labels, buttons, and test data patterns
- `{knowledge_base_path}/shared/standards/qa-standards.md` — cross-project QA standards

Use this knowledge to write more accurate, project-specific test plans. Historical test cases teach you how users actually interact with the system — use these patterns for scenario descriptions.

## Anti-Patterns

- Do NOT include UAT scenarios (UAT-xx) — those belong in the separate UAT Plan
- Do not leave acceptance criteria unmapped
- Do not generate from local docs alone — Jira acceptance criteria are authoritative
