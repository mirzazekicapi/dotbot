# Detect Affected Systems

Identify all systems/components affected by the change, using the Jira context gathered in the previous task.

## Input

Read `.bot/workspace/product/qa-runs/{run}/jira-context-full.md` and `jira-context.json` for the gathered Jira data.

## Output

Write `{output_directory}/systems.json` with detected systems.

## Detection Strategies

Use these strategies **in order**, stopping as soon as you have a confident system list:

### Strategy 1 — Jira project keys from child issues
Look at the child issues. Different Jira project prefixes indicate different systems (e.g., child issues FE-1234, API-5678, BILL-910 indicate 3 systems: frontend, api, billing). Group by project key.

### Strategy 2 — System names in child epic summaries
Parse child issue summaries for system names in parentheses or brackets. Examples:
- `[PROJ-100] Feature X (Backend API)` → system "Backend API"
- `[PROJ-100] Feature X — Frontend` → system "Frontend"

### Strategy 3 — "Lead System" or component fields
Check the main Jira issue for custom fields like "Lead System", "Affected Systems", or the standard "Components" field.

### Strategy 4 — Agent inference (fallback)
If no clear system indicators exist in Jira data, infer systems from:
- The requirements content (which services, APIs, UIs are mentioned)
- Architecture described in Confluence pages
- Acceptance criteria that reference specific system behaviors

## Output Format

Write `{output_directory}/systems.json`:
```json
{
  "systems": [
    {
      "id": "lowercase-slug",
      "name": "Human Readable System Name",
      "jira_project": "PROJ",
      "jira_key": "PROJ-1234"
    }
  ],
  "lead_system": "lowercase-slug-of-lead"
}
```

- `id`: lowercase slug derived from project key or system name
- `name`: human-readable system name
- `jira_project`: Jira project key prefix (if known, otherwise empty string)
- `jira_key`: the specific child epic/issue key for this system (if known, otherwise empty string)
- `lead_system`: the id of the primary/lead system (if detectable, otherwise null)

## Notes

- Do not hardcode system names — detect dynamically from Jira data
- Single-system tickets still get a systems.json with one entry
