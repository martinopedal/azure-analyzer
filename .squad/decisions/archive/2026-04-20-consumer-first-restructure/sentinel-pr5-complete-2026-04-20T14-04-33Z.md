# Sentinel completion record - PR-5 cleanup shipped

- Date (UTC): 2026-04-20T14:04:33Z
- PR: #253
- Merge commit: 3e2f0cdf505a8f5107f09edae56776fca7beb839
- Branch: chore/restructure-cleanup (deleted post-merge)
- Stream: consumer-first restructure, PR-5 of 5

## Stream summary

All five restructure PRs are now merged on main:

1. PR-1 #243 -> ed6041d07068c990f5fa0dded25f39be5d836870
2. PR-4 #244 -> 56b4ad0b290a2a737ba37dd3e13b28f5e986ed3a
3. PR-2 #246 -> e2d42d7ec037f65a1ac40e2a35169912eeacfe4b
4. PR-3 #247 -> be665ea63ab1163ef77596347c2ba719b32a68ed
5. PR-5 #253 -> 3e2f0cdf505a8f5107f09edae56776fca7beb839

Note: the original plan text called PR-5 #248, but GitHub PR #248 was already consumed by the Atlas PR-3 completion-record follow-up. The cleanup PR therefore landed as #253.

## PR-5 scope shipped

- Confirmed pester.log, retry.log, and testResults.xml are not tracked.
- Added .gitignore coverage for retry.log and output-test/.
- Replaced the fragmented Unreleased bullets with one consolidated Consumer-first documentation restructure entry.
- Added the move table, added/fixed sections, and the concrete stub-removal deadline of v1.1.0.
- Swept remaining em dashes from CHANGELOG.md and the affected docs under docs/.
- Filed follow-up issues #249, #250, #251, and #252 from the master plan.

## Validation

- Invoke-Pester -Path .\tests -CI -> 1197 passed, 0 failed, 5 skipped.
- gh pr checks 253 --watch -> all checks green after draft -> ready transition, including Analyze (actions) and the required rubberduck-gate skip/pass surface.
- PR merged via squash and the feature worktree was removed.
