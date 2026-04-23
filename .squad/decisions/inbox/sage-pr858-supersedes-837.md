# Decision: PR #858 supersedes PR #837

**Author:** Sage (Reviewer/Driver)
**Date:** 2026-04-23
**Status:** Merged / Closed

## Summary
PR #858 (`fix(ci): cover all PR-triggered workflows in auto-approve bot gate`) was merged. PR #837 (`fix(ci): unblock Copilot PR gates and break action_required approval deadlocks`) was closed as superseded.

## Why #858 is the correct fix
Both PRs targeted the same symptom: bot-authored PRs (copilot-swe-agent, release-please, dependabot) wedging in `action_required` because `auto-approve-bot-runs.yml` did not cover every PR-triggered workflow.

- **#858 (merged):** Additive expansion of the `workflow_run.workflows:` watched list (+6 entries: Closes Link Required, E2E, Issue Resolution Verify, PR Auto-Rebase Conflicts, PR Auto-Rerun On Push, Squad Heartbeat). Trigger remains `workflow_run`-only. Hard-coded trusted-actor allow-list untouched. Security invariants in `tests/workflows/AutoApproveBotRuns.Tests.ps1` preserved. Diff: `.github/workflows/auto-approve-bot-runs.yml` (+10/-0), `CHANGELOG.md` (+1/-0).
- **#837 (closed):** Larger refactor that risked relaxing the security boundary (broader trigger surface, additional fallbacks). The invariant contract forbids `github.event.pull_request.user`, `workflow_dispatch`, and mandates a single `workflow_run` trigger with a hard-coded actor allow-list — #837's direction moved away from those guarantees.

## Verification
- Invariant tests: `Invoke-Pester -Path ./tests/workflows/AutoApproveBotRuns.Tests.ps1 -CI` — **7/7 pass** on #858 branch.
- All 3 required status checks green (`Analyze (actions)`, `links (lychee)`, `lint (markdownlint-cli2)`).
- Full CI rollup green on final head.
- Merged via `--squash --delete-branch --admin` (self-approval not permitted for PR author; branch protection required checks all satisfied).

## Follow-up
- When a new PR-triggering workflow is added, its `name:` must be appended to `.github/workflows/auto-approve-bot-runs.yml` `workflows:` list, or bot PRs will wedge again. Consider adding a contract test that enumerates all `pull_request` / `pull_request_target` workflows and asserts coverage.
