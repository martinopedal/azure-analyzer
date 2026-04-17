# Ceremonies

> Team meetings that happen before or after work. Each squad configures their own.

## Cloud Agent PR Review

| Field | Value |
|-------|-------|
| **Trigger** | auto |
| **When** | after |
| **Condition** | `copilot-swe-agent[bot]` (or any background agent) opens a PR |
| **Facilitator** | Copilot code review + assigned squad reviewer |
| **Participants** | authoring agent, Copilot reviewer, squad:<member> reviewer |
| **Time budget** | until all review threads Resolved |
| **Enabled** | ✅ yes |

**Agenda:**
1. `copilot-agent-pr-review.yml` auto-requests Copilot code review on PR open (also applies to local/background agent PRs — opt in by adding reviewer manually).
2. Authoring agent MUST respond to every Copilot review comment — either with a code change or an explicit reply explaining why it does not apply. **Issue comments from Copilot count as review comments for this ceremony.**
3. Squad reviewer (the member whose `squad:<name>` label is on the issue) reviews the PR once all Copilot threads are Resolved, applying `reviewer-protocol` semantics (may reject → strict lockout, revision by a different agent).
4. Merge only after: all Copilot threads **Resolved** + squad reviewer **Approved** + required CI green.

**Anti-patterns:**
- ❌ Squash-merging a cloud agent PR with unresolved Copilot review threads
- ❌ Letting the authoring agent self-dismiss Copilot comments without a reply
- ❌ Skipping the squad reviewer because "Copilot already reviewed"

---

## Design Review

| Field | Value |
|-------|-------|
| **Trigger** | auto |
| **When** | before |
| **Condition** | multi-agent task involving 2+ agents modifying shared systems |
| **Facilitator** | lead |
| **Participants** | all-relevant |
| **Time budget** | focused |
| **Enabled** | ✅ yes |

**Agenda:**
1. Review the task and requirements
2. Agree on interfaces and contracts between components
3. Identify risks and edge cases
4. Assign action items

---

## Retrospective

| Field | Value |
|-------|-------|
| **Trigger** | auto |
| **When** | after |
| **Condition** | build failure, test failure, or reviewer rejection |
| **Facilitator** | lead |
| **Participants** | all-involved |
| **Time budget** | focused |
| **Enabled** | yes |

**Agenda:**
1. What happened? (facts only)
2. Root cause analysis
3. What should change?
4. Action items for next iteration

---

## Code Review

| Field | Value |
|-------|-------|
| **Trigger** | auto |
| **When** | before-merge |
| **Condition** | any code PR |
| **Participants** | opus-4.6, goldeneye, gpt-5.3-codex |
| **Gate** | all-approve |
| **Enabled** | yes |

**Process:**
1. All 3 models review independently
2. Parse-check all .ps1 files, verify no ?. syntax
3. Check error handling and CLI tool wrapper compliance
4. All 3 must APPROVE before merge gate opens
