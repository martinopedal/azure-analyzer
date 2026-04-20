# Forge decision record - issue #266

- Timestamp (UTC): 2026-04-20T15-54-12Z
- Issue: #266
- PR: #268
- Merge commit: c793bfb1528b5fda39dbd5e92060fd7c4bf4ee88

## Root causes
1. Watchdog dedupe searched only open ci-failure issues, so closed issues with the same hash (263533c1752a) did not suppress re-opened duplicates.
2. Docs-check stacked PR matcher accepted only strict (PR-x of y) formatting.
3. Run 24674548710 attempt #1 was a transient Actions setup/download failure (actions/github-script tarball retrieval) and not a documentation-policy failure.

## Fixes shipped
- .github/workflows/ci-failure-watchdog.yml
  - Hash dedupe now searches --state all.
  - Canonical issue selection prefers oldest open; falls back to oldest closed.
  - Existing canonical issue is commented instead of opening a new duplicate.
- .github/workflows/docs-check.yml
  - Stacked PR regex broadened to support PR-4, PR 4, and PR:4 forms.
- CHANGELOG.md
  - Added unreleased fix entry for #266.

## Validation
- gh run view 24674548710 --attempt 1 --log-failed confirms transient setup failure.
- gh run list --workflow=\"Docs Check\" --status=failure --limit 20 ... reviewed historical pattern.
- Hash dedupe simulation against 263533c1752a shows canonical issue selection.
- Invoke-Pester -Path .\\tests -CI passed before and after change (1218 discovered, exit code 0).

## Outcome
- PR #268 merged.
- Issue #266 closed.
- Remote and local feature branch cleaned up.
