# Generate Test Cases

Generate detailed technical test cases from the test plan scenarios.

## Input

Read from the current run directory:
- `test-plan.md` — overall test plan with I-xx and E-xx scenarios
- `systems.json` — detected systems
- `systems/{system-id}/test-plan.md` — per-system plans (if multi-system)

## Output

### Multi-system tickets
One consolidated test-cases file per system:
- `{output_directory}/systems/{system-id}/test-cases.md`

Plus cross-system E2E:
- `{output_directory}/test-cases/cross-system-e2e.md`

### Single-system tickets
All test cases in one consolidated file:
- `{output_directory}/test-cases.md`

## Instructions

Apply the `write-test-cases` skill (read `.bot/workflows/qa/prompts/skills/write-test-cases/SKILL.md`).

### For multi-system tickets

For each system detected:
1. Read that system's `test-plan.md`
2. Generate detailed test cases with: preconditions, step-by-step procedure, expected results, test data, priority, tags
3. Tag each test case as automatable or manual-only
4. Write ALL test cases for that system into ONE file: `{output_directory}/systems/{system-id}/test-cases.md`
5. Organize test cases by functional group using `## H2` section headings (e.g., `## Eligibility`, `## Purchase Flow`, `## Regression`)

**System boundary isolation — CRITICAL:**

Every step in a per-system test case must be executable **within that system only**.

**DO:**
- Use the system's own APIs, endpoints, and interfaces as the test entry point
- Set up preconditions by seeding data directly (DB, config, fixtures, mocks)
- Stub or mock external system responses
- Test THIS system's validation, error handling, and response formats

**DO NOT:**
- Include steps like "Submit via System X's UI" in System Y's test cases
- Use another system as the trigger for testing THIS system's behavior
- Include steps that require another team's system to be running

Then generate **cross-system E2E test cases**:
1. Extract E2E scenarios from the overall test plan
2. Generate detailed test cases for flows spanning multiple systems
3. Write to: `{output_directory}/test-cases/cross-system-e2e.md`

### For single-system tickets

Generate all test cases in a **single file**:
- Organize test cases by functional group using `## H2` section headings
- Write to: `{output_directory}/test-cases.md`

## Knowledge Base (optional)

If `{knowledge_base_path}` is not empty, for each system read the following files if they exist:
- `{knowledge_base_path}/projects/{system-id}/skills/write-test-cases/SKILL.md` — project-specific test case patterns and conventions
- `{knowledge_base_path}/projects/{system-id}/history/*.md` — historical test cases showing real test steps: where to click, how to navigate, what data to enter, correct UI labels and field names

Use historical test cases as reference for writing accurate, detailed test steps. They show how users actually interact with each system.

## Anti-Patterns

- Do NOT generate UAT test cases — UAT is in the separate UAT Plan
- Do not use vague steps ("verify it works") — every step must have an observable expected result
- Do not invent scenarios — every test case must trace to a scenario ID in the test plan
