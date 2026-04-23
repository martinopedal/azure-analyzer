# Post-cascade final consistency audit (1.1.1)

Date: 2026-04-23  
Scope: Post-April-2026 cascade verification for PRs #737/#788/#763/#765/#783/#817/#819/#790/#821/#823 and release 1.1.1.

## 1) Test baseline

- Ran: `Invoke-Pester -Path ./tests -CI` (local sandbox baseline before edits).
- Result in this environment: **2545 passed / 61 failed / 48 skipped**.
- Failures were concentrated in workflow-contract containers (`tests/workflows/*`) and one `BeforeAll` dependency-install path (PowerShell Gallery/network/proxy sensitive), i.e., not introduced by this audit pass.
- Audit-target ratchets (below) were run separately and were green.

## 2) Wrapper ratchets

- `tests/shared/WrapperConsistencyRatchet.Tests.ps1`: **112/112 green**
- `tests/workflows/JobTimeouts.Tests.ps1`: **27/27 green**
- `tests/workflows/RetryWrapping.Tests.ps1`: **52/52 green**

## 3) Schema drift (manifest as single source of truth)

Verified manifest-driven usage in all required surfaces:

- Installer: `modules/shared/Installer.ps1` (`Install-PrerequisitesFromManifest` + tool-manifest-driven validation/filtering).
- Reports: `New-HtmlReport.ps1`, `New-MdReport.ps1` load `tools/tool-manifest.json` for tool metadata/coverage rendering.
- ALZ sync: `scripts/Sync-AlzQueries.ps1` resolves upstream/repo data from `tools/tool-manifest.json`.

Targeted contract tests run and green:

- `tests/scripts/Sync-AlzQueries.Tests.ps1`
- `tests/reports/New-HtmlReport.Tests.ps1`
- `tests/reports/New-MdReport.Tests.ps1`
- `tests/manifest/Manifest.Sorted.Tests.ps1`

Combined result: **25/25 green**.

## 4) Security invariants re-check

Re-verified invariant enforcement points:

- HTTPS + host allow-list for clone/fetch: `modules/shared/RemoteClone.ps1`
- Package-manager allow-list and package-name guard regex: `modules/shared/Installer.ps1`
- Time-bounded external execution via `Invoke-WithTimeout`: shared installer/wrappers/sync paths
- Credential sanitization (`Remove-Credentials`) on persisted/logged output: shared modules + report generation paths
- Token scrub behavior in clone flows: `RemoteClone.ps1`

External-process surface was re-grepped for `Invoke-WithTimeout`/`Start-Process` to confirm expected guarded launch points.

## 5) Branch protection checks

- Repository-local workflow evidence confirms check names exist:
  - `Analyze (actions)` (`.github/workflows/codeql.yml`)
  - `lint (markdownlint-cli2)` and `links (lychee)` (`.github/workflows/markdown-check.yml`)
- Direct GitHub branch-protection API verification from this sandbox was blocked by proxy (`gh api .../branches/main/protection` -> HTTP 403 via DNS monitoring proxy), so live rule-state could not be read from this environment.

## 6) Stale stubs / merged remote branches

- Ran:
  - `git fetch origin main:refs/remotes/origin/main`
  - `git branch -r --merged origin/main`
- Result: only `origin/main` present in local remote refs as merged; no additional merged remote branches were listed in this clone context.

## 7) Open-issue sweep status (#770, #629, #506, #746, #529, #626, #627)

- **#770**: still open/reopened; prior coverage exists via merged PR #772 but issue remains actionable.
- **#629**: still open/reopened; partial/major backfill landed in merged PRs #736 and #764; remaining backlog still actionable.
- **#506**: open and explicitly `defer-post-window` (kept deferred per scope).
- **#746**: open/reopened though merged PR #790 closed the main isolation pass; residual follow-up appears actionable.
- **#529**: open; still actionable security hardening follow-up.
- **#626**: open/reopened though covered by merged PR #735 (and related follow-up in #819); residual scope still tracked as actionable.
- **#627**: open/reopened though covered by merged PR #735 (and earlier #759); residual scope still tracked as actionable.

## Outcome

- No additional code/config drift requiring in-repo functional changes was identified during this final pass.
- Deliverable audit summary recorded here for post-cascade closure tracking.
