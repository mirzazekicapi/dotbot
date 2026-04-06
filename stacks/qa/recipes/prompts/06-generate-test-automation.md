# Workflow: Generate Test Automation Tasks

Create implementation tasks for test automation code, targeting the external test repository.

## When to Invoke

Run this workflow **after**:
- `05-generate-test-cases.md` has been executed and test case files exist in `.bot/workspace/product/test-cases/`

This workflow creates tasks — it does NOT write automation code directly. The tasks flow through the standard analysis (98) and execution (99) pipeline, executing in the external test repo.

## Prerequisites Check

Before creating automation tasks, verify these prerequisites:

1. **Test case files exist** — confirm `.bot/workspace/product/test-cases/*.md` contains at least one file
2. **Test repo configured** — `qa.test_repo_path` in settings points to an existing directory that is a git repository

If either is missing, stop. Output a gap report:
```
## Prerequisites not met

- [ ] Test case files: <N files found / NOT FOUND>
- [ ] Test repo path: <configured and valid / NOT CONFIGURED / PATH NOT FOUND / NOT A GIT REPO>

Action required:
- Missing test cases? Run workflow 05 (generate-test-cases) first.
- Missing test repo? Set qa.test_repo_path in .bot/settings/settings.default.json
```

## Execution Steps

### Step 1 — Load configuration and detect framework

Read `qa.test_repo_path` from settings, then auto-detect the test framework:
```
qa_sync_test_repo({ action: "validate" })    → verify repo is accessible
qa_sync_test_repo({ action: "detect" })      → auto-detect framework from repo contents
```

The detect action scans for framework indicators (playwright.config.ts, .csproj with Selenium, pom.xml, package.json, etc.) and returns the detected framework preset with language, test_runner, file_pattern, and base_dir.

If no framework is detected, ask the operator to specify which preset to use from `qa.test_framework_presets`.

### Step 2 — Load test case files

Read all test case files from `.bot/workspace/product/test-cases/*.md`.

For each file, extract:
- Group name and ID
- All test cases marked as **automatable**
- Test case IDs, types, priorities, and tags
- Step-by-step procedures and expected results

Skip test cases marked as `manual-only` — those are for UAT execution, not automation.

### Step 3 — Scan external test repo

Read the external test repo to understand existing structure:

1. Check if `{base_dir}/` exists — if not, it will be created by the first task
2. Look for existing page objects, helpers, fixtures, API clients
3. Look for test runner configuration (playwright.config.ts, pom.xml, etc.)
4. Identify naming conventions and patterns already in use

Record findings for inclusion in task descriptions.

### Step 4 — Create automation tasks

Use `task_create_bulk` MCP tool to create one task per test case group.

For each automatable test case group, create a task:

```javascript
task_create_bulk({
  tasks: [
    {
      name: "Automate [Group Name] test cases",
      description: "Generate test automation code for [Group Name] test cases.\n\n" +
        "## Framework\n" +
        "- Language: {language}\n" +
        "- Test runner: {test_runner}\n" +
        "- File pattern: {file_pattern}\n" +
        "- Base directory: {base_dir}\n\n" +
        "## Test Cases to Automate\n" +
        "[list of TC-xx IDs with titles and step summaries]\n\n" +
        "## Existing Test Repo Structure\n" +
        "[findings from Step 3]\n\n" +
        "## Instructions\n" +
        "Apply the write-test-automation skill. Follow existing repo conventions.\n" +
        "Every test function must include traceability comments referencing the source test case.",
      category: "qa-automation",
      effort: "[estimated based on number of test cases — S for 1-3, M for 4-8, L for 9+]",
      working_dir: "{qa.test_repo_path}",
      acceptance_criteria: [
        "All automatable test cases in [Group Name] have corresponding test functions",
        "Test function names include test case IDs (TC-xx-xx)",
        "Traceability comments reference source test case file and scenario ID",
        "Tests pass when run with: {test_runner}",
        "Page objects or API clients created for reusable interactions",
        "No hardcoded credentials (environment variables only)"
      ],
      applicable_agents: [".bot/prompts/agents/tester/AGENT.md"]
    }
  ]
})
```

### Step 5 — Report

Output the task creation summary:
```
Test automation tasks created:

- Total tasks: N
- Total automatable test cases: N
- Target repo: {qa.test_repo_path}
- Framework: {qa.test_framework} ({language})
- Test runner: {test_runner}

Tasks created:
1. [task name] — [N test cases, effort: M]
2. [task name] — [N test cases, effort: S]
...

Next steps:
- Review tasks in the dashboard
- Trigger analysis (98) and execution (99) for each task
- Tasks will execute in the test repo directory
```

## How Automation Tasks Execute

When a `qa-automation` task enters the standard pipeline:

1. **Analysis (98)**: The analyser reads test case files from the primary repo AND scans the test repo structure. It produces implementation guidance specific to the chosen framework.

2. **Execution (99)**: Because the task has `working_dir` set to the test repo path, the runtime skips worktree creation and executes directly in the test repo. The agent writes automation code, runs the test runner to verify, and commits.

The `working_dir` field is the key mechanism — it tells the runtime to execute in the external repo rather than creating a git worktree in the primary project.

## Integration Points

| When | How |
|------|-----|
| After test cases are generated (05) | Run this workflow to create automation tasks |
| After test repo framework changes | Re-run to regenerate tasks with updated framework config |
| During task execution (99) | Agent reads test cases from primary repo, writes code in test repo |

## Anti-Patterns

- **Do not write automation code directly** — create tasks that flow through the standard pipeline
- **Do not create tasks for manual-only test cases** — UAT scenarios are not automatable
- **Do not skip the test repo scan** — existing patterns must be followed for consistency
- **Do not hardcode the test repo path in task descriptions** — reference `working_dir` field
- **Do not create one task per test case** — group by task group for manageable scope
