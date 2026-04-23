# PR #858 -- action_required meta-bug fix

**Status:** MERGED (squash) at 2026-04-23T16:46:41Z via auto-merge
**Merge commit:** 0dc295585cb59e8cceb2287ed3e62e5f14cef97f
**Branch:** squad/auto-approve-meta-fix (from main, non-bot)

## Root cause

`.github/workflows/auto-approve-bot-runs.yml` filtered `workflow_run` events to only 12 workflow names. Six PR-triggered workflows were absent from the filter, so auto-approve never fired for them on bot-authored PRs:

- `Closes Link Required`
- `E2E`
- `Issue Resolution Verify`
- `PR Auto-Rebase Conflicts`
- `PR Auto-Rerun On Push`
- `Squad Heartbeat (Ralph)`

These stayed wedged in `action_required` indefinitely on every PR from `copilot-swe-agent[bot]`, `github-actions[bot]` (release-please), and `dependabot[bot]`, forcing manual "Approve and run" clicks on 10+ checks per PR.

## Not the root cause (ruled out)

- **`fork-pr-contributor-approval`** already at `first_time_contributors_new_to_github` (minimum-friction). Not the dial.
- **Default workflow permissions** at `write`. Not the dial.
- **Same-repo vs fork**: release-please and copilot-swe-agent push branches to the same repo, not forks. The fork-PR approval setting does not apply; the gate comes from first-time-contributor heuristics on bot actors.

## Fix

Expanded the `workflows:` list in auto-approve-bot-runs.yml to enumerate all 18 PR-triggered workflows. Security invariants preserved: workflow_run + types=[requested], actions:write only, hard-coded trusted-actor allow-list inside the approve step, `action_required` status gating before calling `/approve`.

## Verification

- `Invoke-Pester -Path ./tests/workflows/AutoApproveBotRuns.Tests.ps1 -CI` 7/7 green.
- All 3 required status checks passed: `Analyze (actions)`, `links (lychee)`, `lint (markdownlint-cli2)`.
- Post-merge: auto-approve workflow fired for all subsequent workflow_run events on the merge commit.

## Related / deferred

- **PR #837** (`copilot/ci-health-audit-fix`) -- open, bot-authored, CONFLICTING. Attempts a bigger refactor (`pull_request_target` fallback, paginated PR-run discovery) for the same symptom. Recommend closing as superseded by #858 once the team confirms the minimal fix holds. Left open for Martin's call.
- Two minor loop frictions encountered and resolved:
  1. Initial `git rebase` failed (unstaged squad history). Stashed + retried.
  2. First force-push overrode a `pr-auto-rebase` merge commit from the bot. Force-with-lease caught nothing because local was behind. Replayed my commit on top of latest origin/main and re-pushed. No semantic change lost.

## Hygiene

- CHANGELOG.md entry added under `## Unreleased > ### Fixed`.
- No new actions introduced, no SHA pins needed.
- Opened from non-bot `squad/*` branch per user instruction so CI was not self-gated.
