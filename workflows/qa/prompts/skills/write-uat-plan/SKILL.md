---
name: write-uat-plan
description: Generate a UAT (User Acceptance Testing) plan from the technical test plan, rewritten entirely in business-friendly language for non-technical testers. Zero jargon, zero code, zero system internals.
auto_invoke: false
---

# Write UAT Plan

Guide for producing a UAT plan that a business user, product owner, or stakeholder can pick up and execute without any technical knowledge. The UAT plan is derived from the technical test plan but completely rewritten for its audience.

## Prerequisites

The technical test plan must exist first. This skill reads the UAT-xx scenarios from it and rewrites them.

## Audience

The reader of this document:
- Uses the application daily as part of their job
- Knows the business processes and terminology
- Does NOT know how the system is built (no APIs, databases, services)
- Does NOT have access to developer tools, command lines, or admin panels
- Needs clear, step-by-step instructions they can follow in a browser or mobile app

## Writing Rules

These rules are **absolute** — violating any of them makes the UAT plan unusable for its audience:

1. **Zero technical jargon** — no HTTP codes, no API endpoints, no database tables, no JSON, no service names, no environment variables, no feature flags, no deployment terminology
2. **Observable results only** — "the page shows X" not "the DB contains Y" or "the API returns Z"
3. **Browser/app actions only** — "Click the Save button" not "POST /api/companies" or "run the migration script"
4. **Real UI labels** — use the actual button names, field labels, and menu items visible in the application. If known from Jira/Confluence context, use exact labels (e.g., "Fiscal Status" not "fiscal_status")
5. **Business language** — "Portuguese company" not "company with country_code=PT and fiscal_type=1"
6. **One action per step** — each numbered step is a single user action, not a compound instruction
7. **No assumptions about technical knowledge** — explain where to find things ("Go to Settings > Company Profile > Edit")

## UAT Plan Structure

### 1. Introduction

2-3 sentences explaining what's changing, written for a business person:
- What the change does in user terms
- Why it's being made (business reason, not technical reason)
- Who it affects (which users, which workflows)

Example: "We're adding a new 'Fiscal Status' field for Portuguese companies. When registering or editing a company based in Portugal, you'll now need to select a fiscal status and provide a tax number. This is required for Portuguese e-invoicing compliance."

Do NOT mention: systems, APIs, services, databases, deployment, migration, or technical architecture.

### 2. What to Test

A bulleted list of user-visible changes, each in one plain sentence:
- "A new dropdown called 'Fiscal Status' appears on the company registration page for Portuguese companies"
- "Tax number is now required when the fiscal status is 'Portuguese Company'"
- "Changing your tax number no longer updates immediately — it goes through a review process"

Each bullet should be something the tester can visually verify in the application.

### 3. Prerequisites

What the UAT tester needs before starting. Keep it simple:
- **Login credentials**: which account to use, what role it should have
- **Test environment URL**: the exact URL to open
- **Test data available**: what companies/users already exist for testing (described in business terms)
- **Browser**: any specific browser requirements

Do NOT include: database setup, API configuration, feature flags, seed scripts, environment variables.

### 4. Test Scenarios

For each UAT-xx scenario from the technical test plan, produce a complete test script:

```
### UAT-xx: {Scenario title in business language}

**What you're testing:** One sentence explaining the purpose

**Starting point:** Where to begin (e.g., "Log in as admin@example.com and go to Company Management")

**Steps:**
1. {Single user action — click, type, select, navigate}
   **You should see:** {What appears on screen after this step}
2. {Next action}
   **You should see:** {Expected visible result}
3. ...

**This test passes if:** {One clear sentence — the final expected state}

**This test fails if:** {What would indicate a problem}

**Notes:** {Any helpful context for the tester — optional}
```

Rules for scenarios:
- Include ONLY UAT-xx scenarios (skip I-xx integration and E-xx end-to-end scenarios)
- If the technical test plan has no UAT scenarios, derive them from the E2E scenarios by rewriting in user terms
- Every step must be a visible user action in the browser/app
- Every "You should see" must describe something visible on screen
- Never reference other systems, APIs, or background processes
- If a step involves waiting (e.g., "the change takes time to process"), say "Wait for the page to refresh" not "wait for the async job to complete"

### 5. Known Limitations

Things the tester should NOT expect to work or test:
- Features explicitly out of scope
- Known issues that are expected
- Things that look different in test vs production

Written in plain language: "The email notification for fiscal status changes is not included in this release — you will NOT receive an email when your status is updated."

### 6. Reporting Issues

How to report problems found during UAT:
- What information to include (which scenario, what happened vs what was expected, screenshots)
- Who to contact or where to log the issue
- Priority guidance: what's a blocker vs nice-to-have

## Output Quality Rules

- **Read it aloud** — if it sounds like a developer talking, rewrite it
- **The screenshot test** — every expected result should be something you could take a screenshot of
- **The phone test** — could you explain each step to someone over the phone? If not, simplify
- **No implied knowledge** — don't assume the tester knows where settings are or what abbreviations mean
- **Specific over vague** — "Click the blue 'Save Changes' button at the bottom of the page" not "Save the form"

## Output Checklist

- [ ] Zero technical terms in the entire document
- [ ] Every step is a single browser/app action
- [ ] Every expected result is visually observable
- [ ] Prerequisites include login details and URL
- [ ] Pass/fail criteria are clear and unambiguous
- [ ] Known limitations are listed
- [ ] Contact information for reporting issues is included
- [ ] A non-technical person could execute every scenario without asking questions
