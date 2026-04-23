# Decision: Advisory-workflow filter for ci-failure-watchdog

**Date:** 2026-04-23  
**PR:** #947  
**Merge SHA:** fa60ff482cb939825d2aa4bcb1ca40074b3159a7  
**Context:** RCA Track A from `.squad/decisions/inbox/rca-drift-sonnet.md`

## Problem

The ci-failure-watchdog opens GitHub issues for every workflow failure on the watchlist, regardless of whether the workflow is a required branch-protection check or an advisory workflow. This produces 13+ ci-failure issue spam per cascade when advisory workflows like CI (Test matrix) or E2E fail.

**Required checks** (per branch protection):
- `Analyze (actions)`
- `links (lychee)`
- `lint (markdownlint-cli2)`

**Advisory workflows** (observable but not blocking):
- `CI` (Test matrix across OS legs)
- `E2E` (E2E smoke tests)
- `Scheduled scan` (periodic security scans)

## Decision

Added an advisory-workflow filter in the watchdog triage step (`ci-failure-watchdog.yml`). Before opening ci-failure issues, the watchdog now checks if the failed workflow is in the advisory list and exits early with a logged message. Required checks still escalate to ci-failure issues as before.

### Changes

1. **`.github/workflows/ci-failure-watchdog.yml`**: Added case statement filtering CI / E2E / Scheduled scan workflows with `exit 0` after logging
2. **`tests/workflows/WatchdogAdvisoryFilter.Tests.ps1`**: New Pester test asserting the filter is present, contains all three advisory workflows, and has `exit 0` behavior
3. **`tests/workflows/AutoRebaseWorkflow.Tests.ps1`** + **`AutoRerunWorkflow.Tests.ps1`**: Fixed watchlist parsing to use `env.WATCHLIST` structure (PR #944 migration followup)
4. **`CHANGELOG.md`**: Added Fixed entry documenting the advisory filter

## Impact

- **13+ auto-issues per cascade eliminated** — CI Test matrix failures no longer spam the backlog
- **Observability preserved** — advisory workflows remain on the watchlist for metrics, logs are still accessible via `gh run view`
- **Required checks unaffected** — Analyze, links, lint failures still escalate to ci-failure issues

## Issues Closed

Closes #908, #913, #916, #920, #921, #923, #929 — all ci-failure issues from E2E and CI Test matrix advisory workflow failures.

## Next Steps

Track B (semantic HTML tests replacing brittle snapshot) deferred to follow-up per RCA.
