# Issue #127 Fix Decision, CI failure watchdog head_branch parse failure

**Date:** 2026-04-17  
**Agent:** Forge (Platform Automation and DevOps Engineer)  
**Status:** Implemented

## Summary

Fixed `.github/workflows/ci-failure-watchdog.yml` by removing the invalid `github.event.workflow_run.head_branch` reference from the job-level `if:` expression.

## Root Cause

`workflow_run` event payload does not include `head_branch`. Referencing it in job condition caused parse-time workflow failure and prevented job initialization.

## Chosen Fix

Applied Iris option 1 (minimal and safe):

```yaml
if: github.event.workflow_run.conclusion == 'failure' && github.event.workflow_run.name != 'CI failure watchdog'
```

## Why this fix

- Smallest change to restore workflow validity immediately.
- Preserves failure triage behavior and self-skip guard.
- Avoids adding extra API calls and step-output plumbing.

## Validation

- Baseline and post-change Pester test suite run: 392 passed, 0 failed.
- Workflow file loads correctly via `gh workflow view ci-failure-watchdog.yml`.

## Files changed

- `.github/workflows/ci-failure-watchdog.yml`
- `CHANGELOG.md`
- `.squad/agents/forge/history.md`
