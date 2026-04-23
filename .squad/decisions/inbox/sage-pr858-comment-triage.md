# Comment Triage: PR #858

**Author:** Sage
**Date:** 2026-04-23
**PR:** #858 (merged) — fix(ci): cover all PR-triggered workflows in auto-approve bot gate
**Umbrella:** Closes #836; supersedes #837

## Review threads
GraphQL `reviewThreads` query returned `[]`. No Copilot or human line-level review threads were opened.

## Issue comments
One bot comment from `github-actions` (Copilot review contract reminder). No actionable content — informational only. No 3-model gate triage required.

## Post-merge verification
- `Invoke-Pester -Path ./tests/workflows/AutoApproveBotRuns.Tests.ps1 -CI` on merged `main` → **7/7 pass**.
- Diff audit against invariant contract (`tests/workflows/AutoApproveBotRuns.Tests.ps1` lines 52–58):
  - ✅ Trigger stays `workflow_run` only (no `pull_request.user`, no `workflow_dispatch`).
  - ✅ Hard-coded trusted-actor allow-list untouched.
  - ✅ `workflows:` list expansion is additive (`Should -Contain` semantics preserved).
- Required checks `Analyze (actions)`, `links (lychee)`, `lint (markdownlint-cli2)` all green at merge.

## Labels applied
`squad`, `squad:sage`, `type:bug`, `priority:p0`, `ci-failure` (removed stale `squad:lead`).

## Follow-up
Decision record at `.squad/decisions/inbox/sage-pr858-supersedes-837.md` (PR #866) captures the supersession rationale.
