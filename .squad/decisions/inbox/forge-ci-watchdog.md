# CI Failure Watchdog Automation

**Date:** 2026-04-17  
**Agent:** Forge (Platform Automation & DevOps Engineer)  
**Status:** ✅ Complete

## Decision

Implement CI failure triage as a dedicated `workflow_run` watchdog plus an opt-in local PowerShell watcher that share the same dedup contract:

- Hash: first 12 chars of `sha256("{workflow}|{first-error-line}")`
- Open-issue lookup: `ci-failure` label + hash in title
- Existing issue: append `still failing — {run_url}`
- Missing issue: create `fix: CI failure in {workflow} — {short_error} [{hash}]` with required labels

## Why

- Converts failed runs into actionable backlog items.
- Prevents issue spam by grouping repeats by deterministic workflow+error signature.
- Keeps behavior consistent between GitHub-hosted and local polling loops.

## Security and Reliability Notes

- Self-trigger loops are blocked with workflow-name exclusion.
- Workflow payload values are passed through environment variables to reduce expression-injection risk.
- Error lines are credential-sanitized before issue title/body generation.
- Local helper wraps `gh` calls with try/catch and explicit exit-code checks.

## Files

- `.github/workflows/ci-failure-watchdog.yml`
- `tools/Watch-GithubActions.ps1`
- `tests/workflows/Watch-GithubActions.Tests.ps1`
- `README.md`
- `PERMISSIONS.md`
- `CHANGELOG.md`
