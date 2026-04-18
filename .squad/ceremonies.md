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
2. When Copilot posts review comments on the **PR** or on the **linked issue**, the authoring agent runs the **Comment Triage Loop** (below) before touching code.
3. After code changes land, the agent invokes the 3-model review gate (Opus 4.6 + Goldeneye + GPT-5.3-codex, per `.copilot/copilot-instructions.md` and `.squad/decisions.md`). Any model that blocks → fix → re-gate.
4. Squad reviewer (the member whose `squad:<name>` label is on the issue) applies `reviewer-protocol` (may reject → strict lockout, revision by a different agent).
5. Merge only after: all Copilot threads **Resolved** + 3-model gate green + squad reviewer **Approved** + required CI green.

### Comment Triage Loop (applies to PR review comments AND issue comments from Copilot)

For every Copilot comment on a PR or on the linked issue:

1. **Collect** the comment text + file/line context (PR review threads) or full issue body (issue comments).
2. **Rubber-duck against the 3-model gate** — the authoring agent MUST ask each of Opus 4.6, Goldeneye, and GPT-5.3-codex (sync rubber-duck sub-agents) whether the comment identifies a real issue and what the correct remediation is. Record each model's verdict.
3. **Synthesize** the verdicts into a plan update:
   - 2+ models agree it's valid → add a concrete todo to `plan.md` + SQL `todos` table for the fix.
   - All 3 reject it → reply on the comment with the multi-model reasoning and mark the thread resolved with justification.
   - Split verdict → reply asking the commenter to clarify, do NOT silently dismiss.
4. **Rubber-duck the updated plan** as a separate rubber-duck call (plan-level critique, not comment-level) before implementation.
5. **Implement** the todos from the plan. After implementation, re-run the 3-model gate on the diff.
6. **Reply** on each Copilot comment with either: the commit SHA that addresses it, or the multi-model rejection justification. Never leave a Copilot thread without a reply.

**Anti-patterns:**
- ❌ Squash-merging a cloud agent PR with unresolved Copilot review threads
- ❌ Letting the authoring agent self-dismiss Copilot comments without a reply
- ❌ Skipping the squad reviewer because "Copilot already reviewed"
- ❌ Addressing Copilot comments with ad-hoc edits instead of running the 3-model rubber-duck first
- ❌ Updating code before updating `plan.md` with the triaged todos
- ❌ Treating issue comments from Copilot as "just discussion" — they enter the same triage loop as PR review comments

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
| **Gate** | severity-aware (see `.copilot/copilot-instructions.md` -> "Review Severity Taxonomy") |
| **Enabled** | yes |

**Process:**
1. All 3 models review independently
2. Parse-check all .ps1 files, verify no ?. syntax
3. Check error handling and CLI tool wrapper compliance
4. Gate-pass rules per `.copilot/copilot-instructions.md` -> "Review Severity Taxonomy" (no `[blocker]`/`[correctness]` AND either 2-of-3 APPROVE or only `[style]`/`[nit]` change-requests)
