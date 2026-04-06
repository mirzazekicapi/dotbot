# Fetch Jira Context for QA

Gather comprehensive requirements data from Jira for the QA pipeline.

## Input

The prompt includes Jira ticket keys (e.g., `PROJ-123, PROJ-456`) and optionally Confluence page URLs and additional instructions.

## Output

Write all output to `.bot/workspace/product/qa-runs/` in the current run directory.

## Steps

### 1. Fetch main Jira issues

For each Jira ticket key, call `mcp__atlassian__getJiraIssue` to retrieve:
- Summary, description, acceptance criteria
- Status, priority, labels, components
- Parent key (if exists)
- Issue links and relationships

### 2. Fetch child issues

Search for child issues and epic children:
```
mcp__atlassian__searchJiraIssuesUsingJql
JQL: parent = {issue_key}
Limit: 50
```

### 3. Fetch linked issues

Search for explicitly linked issues (blocks, is-blocked-by, relates-to, duplicates):
```
mcp__atlassian__searchJiraIssuesUsingJql
JQL: issuekey in linkedIssues({issue_key})
Limit: 50
```
Linked issues often define scope boundaries and negative test cases.

### 4. Fetch parent context

If the main issue has a parent (epic or initiative):
- Fetch the parent with `mcp__atlassian__getJiraIssue` to understand the broader scope
- This helps identify what is OUT of scope for this ticket

### 5. Fetch comments

Use comments from the main issue response:
- Look for hidden acceptance criteria discussed in comments
- Look for edge cases, clarifications, or scope changes
- Look for decisions that aren't reflected in the description

### 6. Fetch Confluence context

#### User-provided pages (if URLs given)
For each Confluence page URL in the input:
1. Extract the page ID or title from the URL
2. Call `mcp__atlassian__getConfluencePage` to retrieve the page content
3. Extract the body text, stripping HTML markup to plain text

#### Auto-search Confluence
Search Confluence for pages related to the Jira tickets:
```
mcp__atlassian__searchConfluenceUsingCql
CQL: text ~ "{issue_key}" OR text ~ "{issue_summary}"
Limit: 10
```
For each discovered page (up to 5 most relevant):
- Fetch full content with `mcp__atlassian__getConfluencePage`
- Look for: specifications, design decisions, acceptance criteria, architecture notes

### 7. Load local product context (if available)

Read any existing product specification files:
```
.bot/workspace/product/mission.md             (if present)
.bot/workspace/product/tech-stack.md          (if present)
.bot/workspace/product/entity-model.md        (if present)
.bot/workspace/product/prd.md                 (if present)
.bot/workspace/product/change-request-*.md    (all, if present)
```

### 8. Write Jira context summary

Write `{output_directory}/jira-context.json`:
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

Also write a detailed context file `{output_directory}/jira-context-full.md` with all gathered data (full descriptions, acceptance criteria, child/linked issue summaries, Confluence excerpts, local docs) formatted as markdown. This file is consumed by downstream tasks.

## Anti-Patterns

- Do not make all Atlassian API calls in parallel — sequential to avoid rate limits
- If you hit a rate limit, wait 10 seconds and retry once. If it fails again, skip that step and continue.
- Do not skip Jira data — it's the primary requirements source
