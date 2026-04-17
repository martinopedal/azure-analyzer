---
name: "comment-triage"
description: "Rubber-duck Copilot PR/issue comments against the 3-model gate before changing any code"
domain: "orchestration"
confidence: "high"
source: "extracted"
---

## Context

When Copilot (the GitHub Copilot reviewer bot, or any AI reviewer) leaves comments on a PR or on the linked issue, the authoring agent MUST NOT jump straight to code edits. Each comment is first triaged through the 3-model rubber-duck gate, then translated into plan todos, then the plan itself is rubber-ducked, and only then implemented. Applies equally to cloud agents (`copilot-swe-agent[bot]`) and background agents working locally.

The 3-model gate for this repo is: **Opus 4.6 + Goldeneye + GPT-5.3-codex** (see `.copilot/copilot-instructions.md` and `.squad/decisions.md`).

## Patterns

### Comment Triage Loop

For every Copilot comment on a PR (review thread line comment, PR conversation comment, or issue comment on the linked issue):

1. **Collect** the comment text + the diff hunk or file/line it targets (for PR review threads), or the full issue body (for issue-level comments).
2. **Rubber-duck against all 3 models** as sync sub-agents, one call per model, asking each: *"Is this comment identifying a real issue in the proposed change? If yes, what is the correct remediation? If no, explain why the comment does not apply."*
3. **Record** each model's verdict (Valid / Invalid / Needs-Clarification) + reasoning.
4. **Synthesize the majority verdict**:
   - **2+ Valid** → add a concrete todo to `plan.md` and the SQL `todos` table with a short title + description referencing the comment URL.
   - **3 Invalid** → reply on the comment thread with the combined multi-model reasoning and resolve the thread.
   - **Split / Needs-Clarification** → reply asking the commenter for clarification. Do NOT silently dismiss.
5. **Rubber-duck the updated plan** as a separate plan-level critique (one rubber-duck call covering the full plan delta), not a comment-by-comment critique.
6. **Implement** the triaged todos. After implementation, re-run the 3-model gate on the diff (Build → Review → Fix → Re-gate → CI → Merge).
7. **Reply on every Copilot thread** with either the addressing commit SHA or the multi-model rejection justification. No thread may be left without a reply before merge.

## Examples

**Valid comment (2-of-3 Valid):**
1. Copilot flags `.Count` on potentially-scalar result → Opus 4.6 Valid, Goldeneye Valid, GPT-5.3-codex Valid.
2. Agent adds todo `fix-count-scalar-wrap` to plan.md + SQL.
3. Plan rubber-ducked → no additional feedback.
4. Agent wraps in `@(...)`, re-runs 3-model gate on diff → all 3 pass.
5. Agent replies on Copilot thread with commit SHA; thread resolved.

**Invalid comment (3-of-3 Invalid):**
1. Copilot suggests introducing a dependency that violates repo's "no new runtime deps" rule.
2. All 3 models reject (cite `.github/copilot-instructions.md` rules).
3. Agent replies on thread with "3/3 model rejection: violates no-new-runtime-deps rule. See CONTRIBUTING.md §X. Resolving as won't-fix."
4. Thread resolved, no code change, no todo added.

**Split verdict:**
1. Copilot comment is ambiguous about whether a regex should be case-insensitive.
2. Opus 4.6 Valid, Goldeneye Needs-Clarification, GPT-5.3-codex Invalid.
3. Agent replies asking for clarification + waits for reply. No code change yet.

## Anti-Patterns

- ❌ Addressing a Copilot comment with an ad-hoc edit before running the 3-model rubber-duck
- ❌ Treating issue comments from Copilot as "just discussion" — they enter the same loop as PR review comments
- ❌ Updating code before updating `plan.md` with the triaged todos
- ❌ Skipping the plan-level rubber-duck after adding todos
- ❌ Skipping the 3-model re-gate on the diff after implementation
- ❌ Leaving a Copilot thread without a reply (even an "invalid, see above" reply is required)
- ❌ Using a single model to triage comments (must be all 3 to avoid single-model blind spots)
