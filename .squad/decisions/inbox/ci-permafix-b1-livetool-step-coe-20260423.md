# ci-permafix — B1 — live-tool-tests step-level continue-on-error

**Timestamp:** 2026-04-23T19:10:00Z
**Author:** ci-permafix coordinator (forge)
**Tracker:** #861
**Plan reference:** Category B1 — LiveTool wrappers (non-blocking) — stop failing loudly

## Problem

`.github/workflows/ci.yml` `live-tool-tests` job already declared `continue-on-error: true` at the JOB level, which keeps the workflow conclusion green. However, the individual job card is still rendered red on the PR checks page when the Pester test step calls `Write-Error` + `exit 1`. Reviewers see the red job and learn to ignore CI.

## Fix

Add `continue-on-error: true` at the STEP level on:
1. `Install LiveTool CLI dependencies from install manifest (Linux)` — network-sourced live-binary install, transient by nature.
2. `Run LiveTool wrapper tests` — tagged non-blocking tier.

Job-level guard stays as belt-and-braces against future steps that forget the flag.

## Regression guard

`tests/workflows/LiveToolNonBlocking.Tests.ps1`:
- asserts step-level `continue-on-error: true` on both steps
- asserts job-level flag preserved
- asserts the in-step `LiveTool failures detected` Write-Error remains so logs stay actionable

## Security invariant review (rubber-duck)

- `PesterBaselineGuard.Tests.ps1` — guards the `test` job's Pester configuration (PassThru, null guard, baseline floor). This PR edits only the `live-tool-tests` job, no overlap. Re-ran, 6/6 green.
- `AutoApproveBotRuns.Tests.ps1` — guards `auto-approve-bot-runs.yml`, different file. Re-ran, 7/7 green.
- `ConcurrencyGroups.Tests.ps1` — workflow already on the required list, concurrency block untouched. Re-ran, 20/20 green.
- No change to triggers, permissions, token scope, or the `FailedCount > 0` Write-Error (only the job/step status visibility).

## Exit criteria

- `live-tool-tests` job never renders red on the PR checks page unless a required contract regresses (no live-binary drift can paint red).
- `LiveToolNonBlocking.Tests.ps1` green in CI.
