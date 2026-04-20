# Forge CI failure batch triage (2026-04-20T15:18:09Z)

## Scope
Issues: #260, #261, #262, #264 (label: ci-failure, priority:p1)

## Triage matrix

| Issue | Workflow | Run URL | Verdict | Reasoning | Action |
| --- | --- | --- | --- | --- | --- |
| #260 | Docs Check | https://github.com/martinopedal/azure-analyzer/actions/runs/24672985957 | STALE (duplicate) | Exact duplicate hash of #245 ([263533c1752a]); root failure was transient actions/github-script archive fetch. Superseded by PR #256 and newer runs are green. | Closed issue as completed with superseded note. |
| #261 | Sync Squad Labels | https://github.com/martinopedal/azure-analyzer/actions/runs/24673112802 | STALE/FLAKE | Referenced run currently concludes success and recent failures list is empty. No reproducible failure on current main. | Closed issue as completed (transient/stale). |
| #262 | Squad Heartbeat (Ralph) | https://github.com/martinopedal/azure-analyzer/actions/runs/24673121654 | FLAKE | Failed log shows transient GitHub action fetch error for actions/github-script tarball; subsequent runs on newer SHAs are green. | Closed issue as completed (transient). |
| #264 | Copilot Agent PR Review | https://github.com/martinopedal/azure-analyzer/actions/runs/24673239978 | STALE/FLAKE | Referenced run currently concludes success and recent failures list is empty. No current regression on main. | Closed issue as completed (transient/stale). |

## Follow-up hardening

- Improved `.github/workflows/ci-failure-watchdog.yml` error-line extraction to prioritize `##[error]` and `::error::`, then fallback patterns (`error/failed/fatal`, exceptions, and exit-code text).
- Updated `CHANGELOG.md` Unreleased section with the watchdog extraction fix.
- Validation: `Invoke-Pester -Path .\tests -CI` passed (1213 passed, 0 failed, 5 skipped).
