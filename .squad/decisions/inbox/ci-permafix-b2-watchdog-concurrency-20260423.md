# ci-permafix — B2 — watchdog concurrency dynamic group

**Timestamp:** 2026-04-23T19:00:00Z
**Author:** ci-permafix coordinator (forge)
**Tracker:** #862
**Plan reference:** Category B2 — CI failure watchdog — 23/32 recent runs cancelled

## Problem

`.github/workflows/ci-failure-watchdog.yml` declared a constant concurrency group:

```yaml
concurrency:
  group: ci-failure-watchdog
  cancel-in-progress: false
```

GitHub Actions concurrency semantics: with a constant group name, only ONE run may be running and only ONE run may be pending per group. When a third run arrives while one is already queued, the previously-pending run is **cancelled** regardless of `cancel-in-progress: false`. Since the watchdog fires on every `workflow_run: completed` across ~25 watched workflows, queue contention is guaranteed — observed 23/32 runs cancelled.

## Fix

Key the group on `github.event.workflow_run.id`:

```yaml
concurrency:
  group: ci-failure-watchdog-${{ github.event.workflow_run.id }}
  cancel-in-progress: false
```

Each triggering workflow-run gets its own slot. The triage step already dedupes via sha256 hash of `workflow_name|first_error_line`, so parallel triage runs cannot open duplicate `ci-failure` issues.

## Regression guard

New test `tests/workflows/WatchdogConcurrency.Tests.ps1`:
- asserts the dynamic group expression
- asserts the constant `ci-failure-watchdog` (no suffix) is NOT reintroduced
- asserts `cancel-in-progress: false` preserved

## Security invariant review (rubber-duck)

- `tests/workflows/PesterBaselineGuard.Tests.ps1` — untouched; guards `.github/workflows/ci.yml`, this PR only touches `ci-failure-watchdog.yml`.
- `tests/workflows/AutoApproveBotRuns.Tests.ps1` — untouched; guards `auto-approve-bot-runs.yml`, different file.
- `tests/workflows/ConcurrencyGroups.Tests.ps1` — `ci-failure-watchdog.yml` is NOT in the required-workflows list, so tightening its group name does not violate the CAT-E contract.
- No new permissions, no change to triggers, no change to actor allow-lists. Pure concurrency keying change.

## Exit criteria

- Watchdog cancel rate <10% under normal load.
- `WatchdogConcurrency.Tests.ps1` green in CI.
