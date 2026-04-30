# Fetch Jira Context for QA

Gather comprehensive requirements data from Jira for the QA pipeline.

## Input

Form inputs are written to `.bot/.control/launchers/qa-via-jira-form-input.json` by the workflow runner. **Read this file first** to obtain:

- `jira_keys` — comma-separated Jira ticket keys (required, e.g. `"PROJ-123, PROJ-456"`)
- `confluence_urls` — newline-separated Confluence page URLs (optional)
- `instructions` — free-text guidance for the QA plan (optional)
- `approval_mode` — boolean (currently informational; phase gating wired in a later step)

If the form-input file is missing (legacy launches), fall back to extracting the Jira keys from the user prompt text.

## Output

Write all output to `{output_directory}` (substituted at task launch — points at this run's per-workflow outputs dir under `.bot/workspace/{workflow_name}/runs/{run_id}/`).

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

**MCP:** `mcp__atlassian__getJiraIssue` with:
- `cloudId` and `issueIdOrKey`
- `fields: ["summary", "description", "status", "priority", "labels", "components", "parent", "issuelinks", "issuetype", "assignee"]` — **do NOT include `comment` or `attachment`; they can balloon the response past Claude's 25K-token Read limit on chatty tickets**
- `responseContentFormat: "markdown"` — simpler text, ~30–40% smaller than default ADF

**REST fallback:**
```bash
curl -s -u "{email}:{token}" \
  "https://api.atlassian.com/ex/jira/{cloudId}/rest/api/3/issue/{KEY}?fields=summary,description,status,priority,labels,components,parent,issuelinks,issuetype,assignee" \
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

**MCP:** `mcp__atlassian__getJiraIssue` with the parent key and the same safe parameters as Step 1 — `fields` whitelist (no `comment`/`attachment`) and `responseContentFormat: "markdown"`.

**REST fallback:** Same curl as Step 1 but with the parent key.

### 5. Fetch comments (optional, size-guarded)

Step 1 intentionally excludes the `comment` field to avoid token-limit crashes. Comments are often chatty and not the primary QA input — description and acceptance criteria usually carry the requirements.

Only fetch comments if the description is thin or acceptance criteria are missing. When you do fetch them:

**MCP:** Call `mcp__atlassian__getJiraIssue` again with `fields: ["comment"]` only and `responseContentFormat: "markdown"`.

**REST fallback:**
```bash
curl -s -u "{email}:{token}" \
  "https://api.atlassian.com/ex/jira/{cloudId}/rest/api/3/issue/{KEY}/comment?maxResults=50&orderBy=-created"
```

**If the returned tool-results file is too large to Read:**
- Do NOT try to Read the full file.
- Use **Grep** on the file path to extract only comments matching keywords (acceptance, criteria, edge case, blocker, bug, clarif, scope, decision).
- Alternatively use **Read with `offset` and `limit`** to scan in 500-line chunks.
- Extract a short summary (≤ 20 bullet points) and discard the raw file.

Extract:
- Hidden acceptance criteria discussed in comments
- Edge cases, clarifications, scope changes
- Decisions not reflected in the description

If you cannot fetch comments safely, proceed without them — note the omission in `jira-context-full.md` under "Known Gaps".

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

## Large Response Handling

Jira tickets with long comment history or many attachments can return responses over 25K tokens — Claude's `Read` tool will refuse these files outright.

**Rules:**
1. Never Read a tool-results file whose size is unknown. Check size first (the file path is printed when a "Large response" warning appears).
2. If a file exceeds ~20KB: use **Grep** to extract what you need by pattern, or **Read with `offset`/`limit`** in 500-line chunks.
3. If fetching any Jira or Confluence data, prefer:
   - Explicit `fields` whitelists over default full-object responses
   - `responseContentFormat: "markdown"` over default ADF
   - Paginated/filtered searches (smaller `maxResults`) over unbounded ones
4. When a response is still too large: summarize into bullets immediately and discard the raw file from your working context.

## Anti-Patterns

- Do not make all API calls in parallel — sequential to avoid rate limits
- If you hit a rate limit, wait 10 seconds and retry once. If it fails again, skip that step and continue.
- Do not skip Jira data — it's the primary requirements source
- Do not waste turns retrying MCP tools if the first call fails — switch to REST fallback immediately
- When using curl, do not expose full API tokens in console output — use `... ` to truncate in logs
- Do not request `comment` or `attachment` fields in the main `getJiraIssue` call — fetch them separately only if needed, with size guards
