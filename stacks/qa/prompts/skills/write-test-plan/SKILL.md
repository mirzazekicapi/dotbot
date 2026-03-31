---
name: write-test-plan
description: Generate a comprehensive technical QA test plan from product specifications, Jira requirements, and task definitions. Covers business context, assumptions, environment setup, integration and E2E scenarios, and open questions. UAT scenarios are in the separate UAT Plan. Unit tests are out of scope.
auto_invoke: false
---

# Write Test Plan

Guide for producing a technical QA test plan (integration + E2E) that gives the QA team everything they need to understand the change, prepare their environment, and execute testing. The plan must stand alone — a QA engineer reading it with no prior context should understand what's changing, why, what to test, and what they need.

## Prerequisites

At least one of these must exist:

1. **Jira requirements** — fetched issue data with summary, description, acceptance criteria, child issues
2. **Product specifications** — `mission.md`, `entity-model.md`, PRD, change request, or interview summary
3. **Task definitions** — task list with acceptance criteria (via MCP calls or `task-groups.json`)

If none are available, stop and surface the gap. A test plan without requirements is guesswork.

## Inputs to Collect

```
Jira issue data (primary — from QA pipeline)    # requirements, acceptance criteria, linked issues
Confluence pages (supplementary)                 # specs, design docs, architecture notes
.bot/workspace/product/mission.md                # core goals and principles (if present)
.bot/workspace/product/entity-model.md           # data model and relationships (if present)
.bot/workspace/product/tech-stack.md             # runtime, frameworks, E2E tooling (if present)
.bot/workspace/product/prd.md                    # product requirements doc (if present)
.bot/workspace/product/change-request-*.md       # change-scoped context (if present)
task_list (MCP)                                  # all tasks with names, categories, criteria (if available)
```

Read every available input first. Do not write the plan until all accessible inputs are loaded.

## Test Plan Structure

### Required Sections

#### 1. Executive Summary

3-5 sentence plain-language summary written for someone who knows nothing about the ticket:
- What exists today (the current state in one sentence)
- What is changing and why (the business driver)
- Who is affected (users, teams, regions, systems)
- What is the expected outcome when this ships

This is NOT a restatement of the Jira summary. It should synthesize all gathered context into a concise narrative.

#### 2. Current State / Baseline

Describe how things work TODAY before this change:
- What is the current workflow or system behavior being modified?
- What do users currently experience?
- What are the current system interactions?
- If this is a new feature with no current state, explicitly say: "No equivalent functionality exists today."

This section gives testers the baseline to compare against. Without it, they can't determine whether something is "working as before" vs "broken by the change."

#### 3. Change Description

Concrete, specific description of what is being added, modified, or removed:
- New fields, endpoints, screens, or workflows
- Modified validation rules, business logic, or data flows
- Removed or deprecated functionality
- Configuration or feature flag changes

Be specific: not "add fiscal status support" but "add fiscal status dropdown field with 4 options to the registration form, profile edit page, and booking flow. New GET/PUT endpoints on /api/companies/{id}/fiscal. New validation: 9-digit NIF required for Portuguese Company status."

#### 4. Scope

- **In scope**: features, workflows, integrations, and user-facing behaviours covered by this test plan
- **Out of scope**: explicitly excluded areas with reason (e.g., "Unit testing — covered by development teams", "Phase 2 features — separate Jira epic")
- Derive both lists directly from requirements — nothing implied

#### 5. Business Impact & Risk

**Impact:**
- Who is affected? (specific user roles, regions, customer segments)
- What is the blast radius if it goes wrong? (revenue impact, compliance risk, user experience degradation)
- Is there a rollback plan? What does rollback look like?

**Risk areas** — list areas where coverage is hardest or most critical:
- Complex business rules with many conditional paths
- External integrations and third-party APIs
- Async / background processes (jobs, notifications, webhooks)
- Security-sensitive paths (auth, authorization, data visibility)
- Data migrations or schema changes visible to users
- Timing-sensitive operations (race conditions, eventual consistency)

For each risk, note the mitigation: extra E2E coverage, manual regression gate, contract tests, monitoring, etc.

#### 6. Assumptions

List what the test plan assumes to be true. If an assumption is wrong, specific scenarios may not be executable. Examples:
- "Third-party sandbox environment is available and configured"
- "Test database contains seed data for the relevant entity types"
- "Feature flag X is enabled in the test environment"
- "API version Y is deployed to staging before testing begins"
- "CRM system is configured to receive fiscal change tickets"

Each assumption should be something the QA team can verify before starting. Flag any assumptions you're uncertain about with "⚠ NEEDS CONFIRMATION".

#### 7. Dependencies

Systems, services, and artifacts that must be in place before testing:

| Dependency | Type | Description | Required by |
|------------|------|-------------|-------------|
| System X deployed to staging | Deployment | Must be deployed before System Y testing | Scenarios I-01 to I-05 |
| Database migration V123 | Data | Schema changes for new fields | All scenarios |
| Third-party sandbox credentials | External | API keys for test environment | Integration scenarios |

Note the order: which dependencies block which scenarios. This helps the QA team plan their schedule.

#### 8. Environment & Configuration

What the QA team needs to set up before testing:
- **Test environments**: which environments are needed (dev, staging, UAT), any environment-specific config
- **Feature flags**: which flags must be enabled/disabled
- **Configuration**: settings, connection strings, API URLs that need specific values
- **Third-party sandboxes**: external service test credentials and setup steps
- **Browser/device requirements**: specific browser versions, mobile devices, screen sizes
- **Network requirements**: VPN, proxy, specific DNS config

This section should be actionable — a QA engineer should be able to follow it step by step to set up their testing environment.

#### 9. Test Data Requirements

Specific test data needed with concrete examples:

| Data item | Example value | How to create | Cleanup |
|-----------|---------------|---------------|---------|
| Portuguese company with NIF | Company ID: 12345, NIF: 123456789 | Seed script or manual creation in admin | Delete after test run |
| User with admin role | test-admin@example.com | Pre-existing in staging | No cleanup needed |

Include:
- Exact test data values (use synthetic/example data, never real PII)
- How to create each data item (seed script, manual steps, API call)
- Data cleanup requirements between test runs
- Any data isolation constraints (parallel test execution)

#### 10. Test Strategy

| Level | What is tested | Tooling | Who |
|-------|---------------|---------|-----|
| Integration | Multi-component flows, API contracts, DB state | (from tech-stack or requirements) | QA |
| E2E / Acceptance | Full user journeys from UI to persistence | (from tech-stack or requirements) | QA |
| Exploratory | Edge cases, UX, error recovery, accessibility | Manual | QA |

Fill the tooling column from available context. If no E2E tool is specified, mark as `Manual`.

> **Note:** UAT (User Acceptance Testing) scenarios are NOT included in this test plan. They are covered in the separate **UAT Plan** document, which is written in business-friendly language for non-technical testers.

#### 11. Test Scenarios

For each feature area or task group, produce a scenario block:

```
### [Feature Area Name] — [reference id]

**Acceptance criteria covered:**
- [x] AC-1: <criterion from Jira>

**Integration scenarios:**
| ID | Scenario | Setup | Expected outcome |
|----|----------|-------|-----------------|
| I-01 | ... | ... | ... |

**E2E / Acceptance scenarios:**
| ID | Scenario | Steps | Pass condition |
|----|----------|-------|---------------|
| E-01 | ... | ... | ... |

**Exploratory notes:**
- Areas to probe manually: <list edge cases, error paths, UX concerns>
```

Rules:
- Every acceptance criterion from every Jira issue/task must map to at least one I-xx or E-xx scenario
- Scenario IDs are globally unique: I-01…I-nn, E-01…E-nn
- Integration scenarios: specify what's real vs. stubbed
- E2E scenarios: written as observable user steps with a clear pass/fail condition
- Exploratory notes: list areas QA should probe freely, not scripted steps
- Do NOT include UAT scenarios (UAT-xx) — those belong in the separate UAT Plan document

#### 12. Regression Scope

What existing functionality might be affected by this change and needs regression testing:
- List specific existing features, workflows, or integrations that could break
- For each, explain WHY it might be affected (shared code, shared data, shared API)
- Prioritize: critical regressions (must test) vs nice-to-have regressions

This is separate from the new feature scenarios — it's about protecting existing functionality.

#### 13. Open Questions

Things the test plan author couldn't determine from requirements alone. Each question should be:
- Specific (not "how does X work?" but "when a user changes country from Portugal to UK, is the existing fiscal status deleted or preserved?")
- Flagged with who should answer (product owner, dev team, architect)
- Marked with impact: which scenarios are blocked until this is answered

If there are no open questions, write: "No open questions — all requirements are clear."

#### 14. Entry and Exit Criteria

**Entry** (test execution can begin when):
- [ ] All code changes are deployed to the test environment
- [ ] Database migrations are applied
- [ ] Feature flags are configured per Section 8
- [ ] Test data is seeded per Section 9
- [ ] Dependencies from Section 7 are satisfied
- [ ] Open questions from Section 13 are resolved (or explicitly deferred)

**Exit** (testing is complete when):
- [ ] All integration scenarios pass
- [ ] All E2E / acceptance scenarios pass
- [ ] UAT plan signed off by product owner (separate document)
- [ ] Regression scenarios from Section 12 pass
- [ ] No open critical or high-severity defects
- [ ] All acceptance criteria are covered by at least one passing scenario

## Derivation Rules

### From Jira requirements → test plan context
- Jira description + acceptance criteria → Sections 3 (Change Description), 11 (Scenarios)
- Jira parent/linked issues → Section 2 (Current State), Section 4 (Scope)
- Jira comments → Section 13 (Open Questions), Section 6 (Assumptions)
- Jira components/labels → Section 7 (Dependencies)

### From acceptance criteria → test scenarios
Each criterion becomes ≥1 integration or E2E scenario. Criteria describing user-visible behaviour will also be covered in the separate UAT Plan document.

### From entity model → integration scenarios
Every entity relationship with a constraint (FK, unique, cascade delete) needs at least one integration scenario validating the constraint end-to-end.

### From risk areas → coverage weighting
High-risk areas get additional exploratory notes and explicit regression scenarios.

## Output Quality Rules

- **Concrete over generic**: "Portuguese Company fiscal status with 9-digit NIF" not "various fiscal statuses"
- **Specific over vague**: "GET /api/companies/{id}/fiscal returns HTTP 200 with fiscal_status field" not "API returns correct data"
- **Actionable over aspirational**: "Seed 3 test companies using admin API POST /companies" not "ensure test data exists"
- **Evidence-based**: every assertion should trace back to a Jira requirement, acceptance criterion, or explicit inference
- **No placeholders**: if a section can't be filled from available data, say what's missing and flag it in Open Questions

## Output Checklist

- [ ] All Jira acceptance criteria mapped to at least one scenario ID
- [ ] Executive Summary is understandable by someone with no prior context
- [ ] Current State explains what exists today
- [ ] Change Description is concrete and specific
- [ ] Assumptions are verifiable
- [ ] Environment section is actionable (step-by-step setup)
- [ ] Test data includes specific example values
- [ ] Dependencies list includes ordering
- [ ] Regression scope identifies at-risk existing features
- [ ] Open questions are specific with identified owner
- [ ] No UAT scenarios in this document (those belong in the UAT Plan)
- [ ] Scenario IDs are globally unique and sequential (I-xx, E-xx only)
- [ ] No absolute local paths in the document
- [ ] No secrets, tokens, or real PII in test data examples
