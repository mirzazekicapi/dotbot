# Generate UAT Plan

Generate a User Acceptance Testing plan written entirely in business-friendly language for non-technical testers.

## Input

Read from the current run directory:
- `test-plan.md` — the overall technical test plan (for reference)
- `jira-context-full.md` — full Jira requirements
- `systems.json` — detected systems

## Output

Write `{output_directory}/uat-plan.md`

## Instructions

Apply the `write-uat-plan` skill (read `.bot/workflows/qa/prompts/skills/write-uat-plan/SKILL.md`).

The UAT plan is the **only document** that contains UAT scenarios. The technical test plan and technical test cases do NOT include UAT content.

- Derive user-facing test scenarios from acceptance criteria and E2E scenarios in the test plan
- Write entirely in business-friendly language for non-technical testers
- Include complete step-by-step instructions with expected results
- These ARE the UAT test cases — no separate UAT test case file is needed

## Key Rules

- Zero technical jargon — no HTTP codes, no API endpoints, no database tables, no JSON
- Steps must be performable in a browser/app — no command line, no tools
- Expected results must be visually observable — "the page shows X" not "the DB contains Y"
- Use actual UI labels where known from Jira/Confluence context

This UAT plan must be a standalone document — a business user should be able to execute it without reading the technical test plan or test cases.

## Knowledge Base (optional)

If `{knowledge_base_path}` is not empty, for each detected system read the following files if they exist:
- `{knowledge_base_path}/projects/{system-id}/knowledge/application-summary.md` — system context for business-friendly language
- `{knowledge_base_path}/projects/{system-id}/history/*.md` — historical test cases showing real UI navigation, labels, buttons, and user flows

Use this to write UAT scenarios with correct UI labels, real navigation paths, and accurate step-by-step instructions.
