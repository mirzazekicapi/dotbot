# Fetch Jira Context for QA

Gather comprehensive requirements data from Jira for the QA pipeline.

## Input

The prompt includes Jira ticket keys (e.g., `PROJ-123, PROJ-456`) and optionally Confluence page URLs and additional instructions.

## Output

Write all output to `.bot/workspace/product/qa-runs/` in the current run directory.

## Data Access Strategy

**Try Atlassian MCP tools first.** If they are not available (common in spawned processes), **fall back to the Jira REST API using credentials from `.env.local`**.

### Check MCP availability

Try calling `mcp__atlassian__getJiraIssue` for the first ticket. If it works, use MCP tools for all subsequent calls. If it fails or the tool doesn't exist, switch to the REST API fallback immediately — do not waste turns retrying MCP.

### REST API Fallback

If MCP tools are unavailable:

1. **Read credentials** from `.env.local` in the project root:
   ```bash
   cat .env.local
   ```
   Extract: `ATLASSIAN_EMAIL`, `ATLASSIAN_API_TOKEN`, `ATLASSIAN_CLOUD_ID`

2. **Resolve Cloud ID** — if `ATLASSIAN_CLOUD_ID` is a URL (like `https://site.atlassian.net`), resolve to UUID:
   ```bash
   curl -s "https://site.atlassian.net/_edge/tenant_info" | jq -r .cloudId
   ```

3. **Use curl for all Jira/Confluence calls** with basic auth:
   ```bash
   curl -s -u "{ATLASSIAN_EMAIL}:{ATLASSIAN_API_TOKEN}" \
     "https://api.atlassian.com/ex/jira/{CLOUD_ID}/rest/api/3/..."
   ```

## Steps

### 1. Fetch main Jira issues

**MCP:** `mcp__atlassian__getJiraIssue` with `cloudId` and `issueIdOrKey`

**REST fallback:**
```bash
curl -s -u "{email}:{token}" \
  "https://api.atlassian.com/ex/jira/{cloudId}/rest/api/3/issue/{KEY}?fields=summary,description,status,priority,labels,components,parent,issuelinks,comment,attachment" \
  | jq '{key: .key, summary: .fields.summary, description: .fields.description, status: .fields.status.name, priority: .fields.priority.name, labels: .fields.labels, components: [.fields.components[].name], parent: .fields.parent.key}'
```

Retrieve: summary, description, acceptance criteria, status, priority, labels, components, parent key, issue links.

### 2. Fetch child issues

**MCP:** `mcp__atlassian__searchJiraIssuesUsingJql` with JQL `parent = {issue_key}`

**REST fallback:**
```bash
curl -s -u "{email}:{token}" \
  -X POST "https://api.atlassian.com/ex/jira/{cloudId}/rest/api/3/search/jql" \
  -H "Content-Type: application/json" \
  -d '{"jql":"parent = {KEY}","fields":["key","summary","description","status","components"],"maxResults":50}'
```

### 3. Fetch linked issues

**MCP:** `mcp__atlassian__searchJiraIssuesUsingJql` with JQL `issuekey in linkedIssues({issue_key})`

**REST fallback:**
```bash
curl -s -u "{email}:{token}" \
  -X POST "https://api.atlassian.com/ex/jira/{cloudId}/rest/api/3/search/jql" \
  -H "Content-Type: application/json" \
  -d '{"jql":"issuekey in linkedIssues({KEY})","fields":["key","summary","status"],"maxResults":50}'
```

Linked issues define scope boundaries and negative test cases.

### 4. Fetch parent context

If the main issue has a parent (epic or initiative):

**MCP:** `mcp__atlassian__getJiraIssue` with the parent key

**REST fallback:** Same curl as Step 1 but with the parent key.

### 5. Fetch comments

Comments are included in the main issue response (Step 1) via the `comment` field. Extract:
- Hidden acceptance criteria discussed in comments
- Edge cases, clarifications, scope changes
- Decisions not reflected in the description

### 6. Fetch Confluence context

#### User-provided pages (if URLs given)

**MCP:** `mcp__atlassian__getConfluencePage` with page ID extracted from URL

**REST fallback:**
```bash
# Extract page ID from URL (the number in /pages/{id}/)
curl -s -u "{email}:{token}" \
  "https://api.atlassian.com/ex/confluence/{cloudId}/wiki/api/v2/pages/{pageId}?body-format=storage"
```

#### Auto-search Confluence

**MCP:** `mcp__atlassian__searchConfluenceUsingCql` with CQL `text ~ "{issue_key}"`

**REST fallback:**
```bash
CQL=$(python3 -c "import urllib.parse; print(urllib.parse.quote('text ~ \"{KEY}\"'))")
curl -s -u "{email}:{token}" \
  "https://api.atlassian.com/ex/confluence/{cloudId}/wiki/rest/api/content/search?cql=$CQL&limit=10"
```

For each discovered page (up to 5 most relevant), fetch full content.

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

- Do not make all API calls in parallel — sequential to avoid rate limits
- If you hit a rate limit, wait 10 seconds and retry once. If it fails again, skip that step and continue.
- Do not skip Jira data — it's the primary requirements source
- Do not waste turns retrying MCP tools if the first call fails — switch to REST fallback immediately
- When using curl, do not expose full API tokens in console output — use `... ` to truncate in logs
