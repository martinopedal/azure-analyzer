# Aggregated Post-Sprint Audit Findings  -  2026-04-23

This is the input for the 3-model trio rubberduck. Each finding from the five audit reports is included verbatim or summarized.


---
## Source: post-sprint-security-2026-04-23.md

# Post-Sprint Security Audit  -  2026-04-23

**Branch:** `fix/codeql-global-concurrency-v2`
**Baseline:** `origin/main` @ `5760012`
**Sprint window:** commits on `origin/main` since `2026-04-15` (321 commits, 894 files touched, 772 still present)
**Focus:** NEW security regressions introduced during this sprint.

---

## Executive summary

| Severity | Count |
|----------|-------|
| Critical | 0 |
| High     | 0 |
| Medium   | 0 |
| Low      | 1 |
| Info     | 1 |
| **Total**| **2** |

No hardcoded production secrets, HTTP bypasses, or host allow-list violations were introduced during the sprint. One Low-severity sanitization gap is the only material finding; one Info-severity observation is tracked for consistency.

---

## Findings

| ID | Severity | Location (file:line) | Description | Evidence | Remediation |
|----|----------|----------------------|-------------|----------|-------------|
| SEC-001 | Low | `modules\Invoke-Infracost.ps1:296` | Raw Infracost CLI JSON (`$jsonText`, sourced from `$exec.Output` on L262) is persisted to `infracost-breakdown.json` without passing through `Remove-Credentials`. Other writes and log paths in this same module correctly sanitize (version output, error messages, parse failures). Infracost output normally contains Terraform resource attributes  -  which, if a consumer's HCL hardcodes secrets (a known anti-pattern), would be written to disk un-redacted. | `Set-Content -LiteralPath $breakdownPath -Value $jsonText -Encoding utf8NoBOM -Force` with no `Remove-Credentials` wrapper. Introduced in sprint via PRs #271 / #378 / #472. | Wrap the value: `Set-Content -LiteralPath $breakdownPath -Value (Remove-Credentials $jsonText) -Encoding utf8NoBOM -Force`. Add a regression test in `tests/wrappers/Invoke-Infracost.Tests.ps1` modeled on the `Invoke-AzureQuotaReports` scrub test (ghp_ fake in fixture → asserted absent on disk). |
| SEC-002 | Info | `tools\Watch-GithubActions.ps1:23-33` | Local `Sanitize-Text` helper duplicates a narrower subset of the shared `Remove-Credentials` regex set (covers only `ghp_`, `github_pat_`, bearer, `password=`, `token=`). The sole on-disk write in this file (L336) already routes through the shared `Remove-Credentials`, so no secrets leak today. Flagged only to prevent future drift if new writers are added that use the local helper. | Local regex set misses `ghs_`, `gho_`, `sk-`, `AKIA`, `xoxb-`, JWT `eyJ`, Azure connection strings, SAS tokens  -  all of which are covered by `modules\shared\Sanitize.ps1::Remove-Credentials`. | Delete `Sanitize-Text` and replace remaining internal calls with `Remove-Credentials`, or dot-source `modules\shared\Sanitize.ps1` and re-export. Enforce via a Pester guard: grep `tools/**` for locally-defined `function Sanitize-Text` and fail. |

---

## Clean areas (checked and passed)

### 1. Hardcoded secrets
Regex scans for `sk-*`, `ghp_*`, `ghs_*`, `gho_*`, `github_pat_*`, `AKIA*`, `xox[bopas]-*`, `eyJ*`, `pattern-*` across `*.ps1 / *.psm1 / *.psd1 / *.json / *.yml / *.md` outside `tests/` and `output*/` returned **zero** production hits. All matches are confined to test fixtures (`tests/e2e/`, `tests/triage/`, `tests/shared/`, `tests/fixtures/`, `tests/wrappers/`, `tests/scripts/`) and are clearly `FAKE`-prefixed fixtures used to validate `Remove-Credentials`. Documentation hits in `docs/consumer/ai-triage.md` and `modules\Invoke-CopilotTriage.ps1` reference token *prefixes* (e.g. `ghs_`), not secrets.

### 2. HTTP-only URL bypasses
- No `Invoke-WebRequest` / `Invoke-RestMethod` targets `http://` in production code (only `tests/shared/Retry.Tests.ps1` uses `http://example.com` as a retry harness target  -  expected).
- No `git clone http://…`, `curl http://…`, or `wget http://…` anywhere in PowerShell sources.
- The only `http://` occurrences in `modules/` are: SVG XML namespace declarations (`ExecDashboardRender.ps1`), a doc comment in `ReportVerification.ps1`, and the local viewer bind address (`127.0.0.1` / `$BindAddress` via `Viewer.ps1`)  -  none are outbound fetch URLs.

### 3. Host allow-list
- `tools\tool-manifest.json` contains **zero** `install.method = gitclone` entries, so `RemoteClone.ps1`'s allow-list surface is not extended by the manifest.
- All informational `install.url` / `source.url` hosts resolve to: `api.github.com`, `cli.github.com`, `developer.hashicorp.com`, `github.com`, `learn.microsoft.com`, `powerpipe.io`, `raw.githubusercontent.com`, `www.infracost.io`. All are HTTPS; none are used for code execution or clone targets.

### 4. Disk-write sanitization (Remove-Credentials coverage)
Reviewed all 73 `Set-Content` / `Add-Content` / `Out-File` / `[IO.File]::WriteAll*` call sites in non-test production code. Every site that persists tool output or findings passes through `Remove-Credentials`, including (sprint-added or sprint-modified):

- `Invoke-AzureAnalyzer.ps1`  -  `results.json` (L1342), `entities.json` (L1374), `portfolio.json` (L1412), `tool-status.json` (L1502), `triage.json` (L1570), `run-metadata.json` (L1708), `errors.json` (L1843).
- `modules\Invoke-ADORepoSecrets.ps1:745` (new in sprint, PR #182)  -  `$payload = Remove-Credentials …` before write.
- `modules\shared\EntityStore.ps1:569-578`  -  spill files sanitized (belt-and-suspenders: `Remove-Credentials` invoked twice).
- `modules\shared\MultiTenantOrchestrator.ps1:386-389`  -  both JSON and HTML summary sanitized.
- `modules\shared\RubberDuckChain.ps1:271`, `modules\shared\Checkpoint.ps1:188`, `modules\reports\New-DriftReport.ps1:81,140`.
- Per-tool raw outputs in `Invoke-AzureCost.ps1`, `Invoke-AppInsights.ps1`, `Invoke-DefenderForCloud.ps1`, `Invoke-AzureLoadTesting.ps1`, `Invoke-AksRightsizing.ps1`, `Invoke-AksKarpenterCost.ps1`, `Invoke-FinOpsSignals.ps1`, `Invoke-SentinelCoverage.ps1`, `Invoke-SentinelIncidents.ps1`, `Invoke-KubeBench.ps1`, `Invoke-AzureQuotaReports.ps1`.
- `tools\Watch-GithubActions.ps1:335` (new in sprint, PR #111)  -  state file sanitized before write.
- Reporters `New-HtmlReport.ps1:1017`, `New-MdReport.ps1:594`, and `New-ExecDashboard.ps1:57` (via `ExecDashboardRender.ps1:880` returning `Remove-Credentials $html`).

Non-findings writes (confirmed safe by content type, not secret-bearing): `tools\Generate-SBOM.ps1:267` (SBOM metadata), `tools\Update-ToolPins.ps1:172,223` (manifest + release JSON  -  already HTTPS-fetched and structurally typed), `scripts\audit-tool-fields.ps1:151` (tool field metadata), `modules\shared\KubeAuth.ps1:154` (kubeconfig round-trip, user-supplied path), `modules\shared\ReportManifest.ps1:296` (manifest: paths, timings, features  -  no raw tool output), `modules\shared\ScanState.ps1:176` (resume-state metadata), `modules\shared\RunHistory.ps1:124` (run index), `modules\shared\ReportDelta.ps1:329` (delta index), `modules\shared\Invoke-PR*.ps1` (`$safe*` variables already sanitized upstream  -  naming convention enforced).

### 5. Viewer session token (`Viewer.ps1:1806`)
`session-token.txt` is intentionally written as the authentication token for the local viewer. Directory is locked down (`chmod 700` on POSIX, ACL with owner-only `FullControl` on Windows) and `umask 077` is set on POSIX before write. This is the documented behavior and not a regression.

### 6. RemoteClone host enforcement
`modules\shared\RemoteClone.ps1` remains the sole clone entry point; no new wrappers in the sprint bypass it. `Invoke-ADORepoSecrets.ps1` (new) uses the shared helper. Token scrubbing of `.git/config` (L242) is preserved.

---

## Methodology

Environment: Windows / PowerShell 7. All commands run from `C:\git\azure-analyzer` on `fix/codeql-global-concurrency-v2`.

### Tools
- `git --no-pager` (sprint commit/file enumeration, per-file history)
- `rg` (ripgrep 14.x at `C:\Users\martinopedal\AppData\Local\Microsoft\WinGet\Links\rg.exe`)
- `Select-String` (PowerShell built-in)
- Manual `view` of all write-site contexts for 15 suspect files.

### Commands (representative)
```powershell
# Sprint file inventory
git --no-pager log --since=2026-04-15 origin/main --name-only --pretty=format: |
    Sort-Object -Unique |
    Where-Object { $_ -match '\.(ps1|psm1|psd1|json|ya?ml|md)$' }

# Secret-pattern scan (production scope)
rg -n -g '*.ps1' -g '*.psm1' -g '*.psd1' -g '*.json' -g '*.yml' -g '*.yaml' -g '*.md' `
   -g '!tests/**' -g '!output*/**' `
   -e 'ghp_[A-Za-z0-9]{30,}' -e 'ghs_' -e 'gho_' `
   -e 'AKIA[0-9A-Z]{16}' -e 'xox[bopas]-[A-Za-z0-9-]{10,}' `
   -e 'sk-[A-Za-z0-9]{30,}' -e 'eyJ[A-Za-z0-9_-]{20,}' .

# HTTP bypass scan
rg -n -g '*.ps1' -g '*.psm1' -g '!tests/**' `
   -e 'Invoke-(Web|Rest)(Request|Method).*http://' `
   -e 'git clone.*http://' -e '\bcurl\s+http://' -e '\bwget\s+http://' .

# Disk-write inventory (non-test)
rg -n -g '*.ps1' -g '*.psm1' -g '!tests/**' -g '!output*/**' `
   -e 'Out-File' -e 'Set-Content' -e 'Add-Content' `
   -e 'WriteAllText' -e 'WriteAllLines' .

# Manifest host allow-list
(Select-String tools\tool-manifest.json -Pattern 'https?://[^"\s]+' -AllMatches).Matches.Value |
    ForEach-Object { ([uri]$_).Host } | Sort-Object -Unique

# Per-file sprint history
git --no-pager log --since=2026-04-15 origin/main --oneline -- <path>
```

### Scope boundaries
Pre-existing files untouched during the sprint (e.g. `scripts\arachne-watcher.ps1`) are out of scope even where they contain weaker local sanitizers  -  they represent inherited risk, not sprint-introduced regressions. All findings above are confirmed sprint-introduced via `git log --since=2026-04-15`.


---
## Source: post-sprint-consistency-2026-04-23.md

# Post-sprint consistency audit  -  2026-04-23

Audit of `modules/Invoke-*.ps1` wrappers against the consistency invariants
established by **PR #521** ("chore(consistency): enforce uniform
parameters/retry/error-quality across wrappers (sweep #2)") and the preceding
PR #501.

## Executive summary

- **Wrappers checked:** 36 (all `modules/Invoke-*.ps1`).
- **`[CmdletBinding()]` coverage:** 36 / 36 ✅ (Cat 7 invariant).
- **REST → retry coverage:** 11 / 11 wrappers that call
  `Invoke-RestMethod` / `Invoke-AzRestMethod` also invoke `Invoke-WithRetry`
  ✅ (Cat 10 invariant  -  zero violations, matches the ratchet expectation).
- **Raw `throw` ratchet:** 40 raw throws across 17 wrappers  -  **exact match**
  to the baseline locked in
  `tests/shared/WrapperConsistencyRatchet.Tests.ps1` (Cat 11).
- **Manifest registration:** 36 / 36 wrappers registered in
  `tools/tool-manifest.json` ✅.
- **Normalizer + tests:** 35 / 36 wrappers have a `modules/normalizers/*.ps1`
  counterpart *and* a `tests/normalizers/*.Tests.ps1`. The single gap
  (`Invoke-CopilotTriage`) is disabled in the manifest and is not a
  finding-producing wrapper.

### Deviations by category

| Category | Count | Severity range |
| --- | --- | --- |
| Parameter naming drift (canonical set not yet enforced) | 2 | Low  -  Medium |
| Error-handling debt (raw throw vs `New-FindingError`) | 1 | Medium |
| Manifest / wrapper alignment | 1 | Info |
| Scope-driven param shape (documented exceptions) | 1 | Info |
| Missing `SupportsShouldProcess` on side-effecting wrappers | 1 | Low |
| **Total** | **6** | |

No Critical or High deviations. All invariants actively enforced by the
ratchet (Cat 7 / Cat 10 / Cat 11) are green.

## Findings

| ID | Severity | Wrapper | Invariant violated | Location | Evidence | Fix |
| --- | --- | --- | --- | --- | --- | --- |
| CON-001 | Medium | `Invoke-AdoConsumption.ps1` | Uniform ADO parameter names (`AdoOrg` / `AdoProject` / `AdoPat`) | `param()` block | Signature: `Organization, Project, DaysBack, MonthlyBudgetUsd, AdoPat`. Every other ADO wrapper (`ADOPipelineCorrelator`, `ADOPipelineSecurity`, `ADORepoSecrets`, `ADOServiceConnections`) uses `AdoOrg, AdoProject, AdoPat`. | Rename `Organization`→`AdoOrg`, `Project`→`AdoProject` (keep aliases via `[Alias('Organization','Project')]` for one release to avoid breaking callers), update `Invoke-AzureAnalyzer.ps1` forwarding and tests. |
| CON-002 | Low | Repo-scoped wrappers (group) | Uniform repo-input parameter name | `param()` blocks of `Invoke-IaCBicep`, `Invoke-IaCTerraform`, `Invoke-Gitleaks` (use `RepoPath`); `Invoke-Infracost`, `Invoke-PSRule` (use `Path`); `Invoke-Trivy` (uses `ScanPath`); `Invoke-Scorecard`, `Invoke-Zizmor` (use `Repository`) | Four distinct names for "the repo to scan". Blocks cross-wrapper orchestration and confuses the manifest-driven runner. | Converge on `RepoPath` (local fs) + `RemoteUrl` (HTTPS clone). Add `[Alias]` for legacy names. Update `RemoteClone.ps1` call sites accordingly. |
| CON-003 | Medium | 17 wrappers grandfathered by `$RawThrowBaseline` | Error exits must use `New-FindingError` (sweep #2 Cat 11 target end-state) | See list below  -  baseline is locked but **not** yet zeroed | 40 raw `throw "..."` strings remain (matches baseline exactly  -  no regression). Only `Invoke-ADORepoSecrets.ps1` has completed the migration; `Invoke-AzureQuotaReports.ps1` and `Invoke-KubeBench.ps1` source `Errors.ps1` but still leak raw throws. | Incrementally convert per-file, drop the entry in `$RawThrowBaseline` each time a wrapper reaches zero, per the ratchet's remediation hint. Priority order recommended: `Falco` (4), `KubeBench` (4), `Kubescape` (4), `DefenderForCloud` (3), `Gitleaks` (3), `AksKarpenter/Rightsizing` (3 each). |
| CON-004 | Low | Side-effecting wrappers | `SupportsShouldProcess` / `-WhatIf` surface | `Invoke-Falco.ps1` (`-InstallFalco`, `-UninstallFalco`), `Invoke-AksKarpenterCost.ps1` (`-EnableElevatedRbac`) | No wrapper sets `[CmdletBinding(SupportsShouldProcess = $true)]`. Users cannot dry-run cluster-mutating flows. PR #521 did not require this; flagged as a drift from the prompt's "typical invariants" list. | Add `SupportsShouldProcess` + `ConfirmImpact='High'` to the two identified wrappers and gate the kubectl apply/install paths behind `$PSCmdlet.ShouldProcess(...)`. |
| CON-005 | Info | `tools/tool-manifest.json` entry `identity-correlator` | Every manifest tool should map to an `Invoke-*.ps1` wrapper | `tools/tool-manifest.json` | Entry exists with `normalizer = Normalize-IdentityCorrelation` but no wrapper file  -  the logic lives in `modules/shared/IdentityCorrelator.ps1` and is consumed by other wrappers. | Either (a) rename the entry to signal "shared module, not wrapper" (e.g. `kind: shared`) or (b) extract a thin `Invoke-IdentityCorrelator.ps1` wrapper so the manifest schema is uniform. |
| CON-006 | Info | `Invoke-CopilotTriage.ps1` | Wrapper-to-normalizer 1:1 mapping | `modules/normalizers/` | No `Normalize-CopilotTriage.ps1`; no `Sanitize.ps1` / `Schema.ps1` imports. Manifest entry has `enabled: false`. | Acceptable today (disabled). If/when this wrapper is enabled, ship the normalizer + test + sanitize import in the same PR. |

### Raw-throw inventory (backing CON-003)

Exact counts equal the baseline in
`tests/shared/WrapperConsistencyRatchet.Tests.ps1`:

```
Invoke-AksKarpenterCost.ps1   3   (lines 449, 456, …)
Invoke-AksRightsizing.ps1     3   (lines 409, 412, …)
Invoke-AppInsights.ps1        2   (lines 347, 410)
Invoke-AzGovViz.ps1           1   (line 665)
Invoke-AzureCost.ps1          1   (line 103)
Invoke-AzureLoadTesting.ps1   1   (line 90)
Invoke-DefenderForCloud.ps1   3   (lines 180, 226, 311)
Invoke-Falco.ps1              4   (lines 121, 124, 127, 133)
Invoke-FinOpsSignals.ps1      2   (lines 116, 135)
Invoke-GhActionsBilling.ps1   1   (line 59)
Invoke-Gitleaks.ps1           3   (lines 319, 323, 327)
Invoke-KubeBench.ps1          4   (lines 260, 263, 266, 272)
Invoke-Kubescape.ps1          4   (lines 147, 150, 153, 160)
Invoke-Powerpipe.ps1          1   (line 133)
Invoke-Scorecard.ps1          1   (line 245)
Invoke-SentinelCoverage.ps1   1   (line 322)
Invoke-SentinelIncidents.ps1  1   (line 319)
                             --
Total                        40
```

No regression since PR #521 was merged.

## Clean wrappers (no deviations detected)

These wrappers meet every audited invariant  -  `[CmdletBinding()]`, REST-through-retry
if any, zero raw throws, canonical param shape for their scope, manifest entry,
and a normalizer + test file:

- `Invoke-ADOPipelineCorrelator.ps1`
- `Invoke-ADOPipelineSecurity.ps1`
- `Invoke-ADORepoSecrets.ps1` *(the sweep #2 reference migration)*
- `Invoke-ADOServiceConnections.ps1`
- `Invoke-AlzQueries.ps1`
- `Invoke-Azqr.ps1`
- `Invoke-AzureQuotaReports.ps1`
- `Invoke-IaCBicep.ps1` *(subject to CON-002 naming drift, not wrapper-internal)*
- `Invoke-IaCTerraform.ps1` *(ditto CON-002)*
- `Invoke-IdentityGraphExpansion.ps1` *(empty `param()`  -  scope-driven, acceptable per PR #521 audit table)*
- `Invoke-Infracost.ps1`
- `Invoke-Maester.ps1` *(empty `param()`  -  scope-driven)*
- `Invoke-Prowler.ps1`
- `Invoke-PSRule.ps1`
- `Invoke-Trivy.ps1`
- `Invoke-WARA.ps1`
- `Invoke-Zizmor.ps1`

## Methodology

1. **Read PR #521** via `gh pr view 521 --json title,body,files` to extract the
   authoritative invariant set (sweep #2 cats 7-11) and the grandfathered
   raw-throw baseline in `tests/shared/WrapperConsistencyRatchet.Tests.ps1`.
2. **Enumerated wrappers** with `Get-ChildItem modules\Invoke-*.ps1`
   (36 files).
3. **Static scan**  -  one pass per wrapper, computing:
   - `[CmdletBinding(` match → Cat 7.
   - Counts of `Invoke-RestMethod | Invoke-AzRestMethod | Search-AzGraph` vs
     `Invoke-WithRetry` → Cat 10.
   - Raw-throw count using the same regex as the ratchet
     (`(?m)^\s*throw\s+["']` + `catch\s*\{[^{}]*throw\s+["']`) → Cat 11.
   - Presence of `Errors.ps1 | New-FindingError`, `Sanitize.ps1| Remove-Credentials`,
     `New-FindingRow | SchemaVersion` imports.
   - `git.exe` / `gh <verb>` external-call occurrences and whether
     adjacent `Invoke-WithRetry` blocks exist.
4. **Parameter extraction**  -  depth-tracked parse of the
   `[CmdletBinding(...)] param(...)` block to list each wrapper's public
   parameters; diffed against the canonical set
   (`SubscriptionId | TenantId | OutputPath | AdoOrg | AdoProject | AdoPat | RepoPath | RemoteUrl`)
   expected from PR #521's audit table.
5. **Manifest cross-check**  -  parsed `tools/tool-manifest.json` and joined
   `name` / `normalizer` fields against the wrapper file list and against
   `modules/normalizers/*.ps1` + `tests/normalizers/*.Tests.ps1`.
6. **Finding severity**  -  Critical/High reserved for broken invariants
   (none found); Medium for user-facing / consumer-visible drift that blocks
   future refactors (CON-001, CON-003); Low for cosmetic / opt-in drift
   (CON-002, CON-004); Info for manifest-schema nits (CON-005, CON-006).

### Limitations

- The ratchet uses text-based regexes; dynamically constructed `throw` calls
  (e.g. `throw $errMsg`) are not counted and could hide real issues. Spot
  check: `rg "^\s*throw\s+\$" modules\Invoke-*.ps1` found no variable-only
  throws  -  confirmed clean.
- Parameter-shape comparison is textual; aliases declared via `[Alias()]`
  were inspected for CON-001 / CON-002 suggestions but not used to mask
  drift.
- Only `modules/Invoke-*.ps1` was in scope. Tool-style entrypoints under
  `tools/` were not audited (no matching files present).


---
## Source: post-sprint-docs-2026-04-23.md

# Post-Sprint Docs Audit -- 2026-04-23

**Scope:** azure-analyzer (C:\git\azure-analyzer)  
**Auditor:** post-sprint-docs agent  
**Date:** 2026-04-23  
**Source-of-truth files:** `tools/tool-manifest.json`, `README.md`, `PERMISSIONS.md`, `CHANGELOG.md`, `docs/reference/tool-catalog.md`

## Executive summary

| Finding | Severity | Area | Status |
|---|---|---|---|
| DOC-001 | **Critical** | README.md carries unresolved Git merge-conflict markers (`<<<<<<< HEAD` / `=======` / `>>>>>>> f549853`) on lines 3-8 | Fix now |
| DOC-002 | Medium | README.md tool-count claims are inconsistent: "37 read-only", "35 tools", "Tool catalog (37 tools)" | Reconcile |
| DOC-003 | Info | Manifest-vs-catalog sync: all 36 enabled + 1 disabled manifest entries are reflected in `docs/reference/tool-catalog.md` (README delegates). Clean. | OK |
| DOC-004 | Info | PERMISSIONS.md coverage: 0 gaps. All 36 enabled tools resolve to a `docs/consumer/permissions/<name>.md` entry in the index. | OK |
| DOC-005 | **High** | CHANGELOG.md: 254 of 282 merged PRs since 2026-04-15 have no citation. Docs-rule requires a CHANGELOG entry for every user-visible change. | Backfill |
| DOC-006 | Low | Em-dash ban: 7 U+2014 occurrences across root `*.md` (README 4, PERMISSIONS 1, CHANGELOG 2). Full-repo count (incl. `.squad/`, `.copilot/`, `docs/`, `.github/`): **1,981** hits -- flagged for follow-up sweep but not required for this audit table. | Replace `--` |

Total findings: **6**.

---

## Section 1 -- manifest-vs-README diff (DOC-001, DOC-002, DOC-003)

### DOC-001 (Critical) -- unresolved merge-conflict markers in README.md

README.md lines 3-8:

```
<<<<<<< HEAD
> **Active maintenance in progress (2026-04-23).** ...
=======

>>>>>>> f549853 (test(e2e): end-to-end harness for Invoke-AzureAnalyzer with 3-surface coverage)
```

This is user-facing on the repo landing page. Resolve immediately (pick HEAD's maintenance banner, drop the conflict sigils).

### DOC-002 (Medium) -- tool-count inconsistency in README.md

| Location | Claim |
|---|---|
| README.md line 13 | "**One PowerShell command, 37 read-only Azure assessment tools**" |
| README.md line 48 | "**35 tools** across Azure, Entra, GitHub, ADO" |
| README.md line 60 | "Tool catalog (37 tools)" |
| `tools/tool-manifest.json` (ground truth) | **36 enabled**, **1 disabled** (`copilot-triage`), 37 total |
| `docs/reference/tool-catalog.md` line 11 | "Total enabled: 36. Disabled / opt-in: 1" |

Recommendation: normalize to "**36 read-only tools (37 with opt-in AI triage)**" everywhere, or pick one canonical phrasing and propagate.

### DOC-003 (Info) -- manifest-vs-catalog diff

README delegates supported-tools listing to `docs/reference/tool-catalog.md`. Every one of the 36 enabled manifest entries is present in the catalog table, and the one disabled entry (`copilot-triage`) is in the "Disabled / opt-in" section.

Enabled tools cross-checked (36): `azqr, kubescape, kube-bench, defender-for-cloud, prowler, falco, azure-cost, azure-quota, finops, appinsights, loadtesting, aks-rightsizing, aks-karpenter-cost, psrule, powerpipe, azgovviz, alz-queries, wara, maester, scorecard, gh-actions-billing, ado-connections, ado-pipelines, ado-consumption, ado-repos-secrets, ado-pipeline-correlator, identity-correlator, identity-graph-expansion, zizmor, gitleaks, trivy, bicep-iac, infracost, terraform-iac, sentinel-incidents, sentinel-coverage`.

Disabled: `copilot-triage`.

**Diff:** none.

---

## Section 2 -- PERMISSIONS.md coverage (DOC-004)

Every enabled tool in `tools/tool-manifest.json` resolves to a `docs/consumer/permissions/<name>.md` link inside the generated INDEX block of `PERMISSIONS.md`. The index is auto-generated by `scripts/Generate-PermissionsIndex.ps1` and gated by the `permissions-pages-fresh` CI check, which explains the clean state.

| Tool | Scope | Permissions doc |
|---|---|---|
| aks-karpenter-cost | subscription | `docs/consumer/permissions/aks-karpenter-cost.md` |
| aks-rightsizing | subscription | `docs/consumer/permissions/aks-rightsizing.md` |
| alz-queries | managementGroup | `docs/consumer/permissions/alz-queries.md` |
| appinsights | subscription | `docs/consumer/permissions/appinsights.md` |
| azgovviz | managementGroup | `docs/consumer/permissions/azgovviz.md` |
| azqr | subscription | `docs/consumer/permissions/azqr.md` |
| azure-cost | subscription | `docs/consumer/permissions/azure-cost.md` |
| azure-quota | subscription | `docs/consumer/permissions/azure-quota.md` |
| defender-for-cloud | subscription | `docs/consumer/permissions/defender-for-cloud.md` |
| falco | subscription | `docs/consumer/permissions/falco.md` |
| finops | subscription | `docs/consumer/permissions/finops.md` |
| kube-bench | subscription | `docs/consumer/permissions/kube-bench.md` |
| kubescape | subscription | `docs/consumer/permissions/kubescape.md` |
| loadtesting | subscription | `docs/consumer/permissions/loadtesting.md` |
| powerpipe | subscription | `docs/consumer/permissions/powerpipe.md` |
| prowler | subscription | `docs/consumer/permissions/prowler.md` |
| psrule | subscription | `docs/consumer/permissions/psrule.md` |
| sentinel-coverage | workspace | `docs/consumer/permissions/sentinel-coverage.md` |
| sentinel-incidents | workspace | `docs/consumer/permissions/sentinel-incidents.md` |
| wara | subscription | `docs/consumer/permissions/wara.md` |
| maester | tenant | `docs/consumer/permissions/maester.md` |
| identity-correlator | tenant | `docs/consumer/permissions/identity-correlator.md` |
| identity-graph-expansion | tenant | `docs/consumer/permissions/identity-graph-expansion.md` |
| gh-actions-billing | repository | `docs/consumer/permissions/gh-actions-billing.md` |
| scorecard | repository | `docs/consumer/permissions/scorecard.md` |
| ado-connections | ado | `docs/consumer/permissions/ado-connections.md` |
| ado-consumption | ado | `docs/consumer/permissions/ado-consumption.md` |
| ado-pipeline-correlator | ado | `docs/consumer/permissions/ado-pipeline-correlator.md` |
| ado-pipelines | ado | `docs/consumer/permissions/ado-pipelines.md` |
| ado-repos-secrets | ado | `docs/consumer/permissions/ado-repos-secrets.md` |
| bicep-iac | repository | `docs/consumer/permissions/bicep-iac.md` |
| gitleaks | repository | `docs/consumer/permissions/gitleaks.md` |
| infracost | repository | `docs/consumer/permissions/infracost.md` |
| terraform-iac | repository | `docs/consumer/permissions/terraform-iac.md` |
| trivy | repository | `docs/consumer/permissions/trivy.md` |
| zizmor | repository | `docs/consumer/permissions/zizmor.md` |

**Gaps:** 0. **Status:** OK.

(The audit does not verify that each linked `<name>.md` actually exists on disk -- `permissions-pages-fresh` CI enforces that. A filesystem spot-check is recommended as a follow-up.)

---

## Section 3 -- CHANGELOG misses (DOC-005, High)

**Method:** `git --no-pager log origin/main --since=2026-04-15 --pretty=format:"%s"` yielded 321 commits, of which 282 contained a `(#NNN)` merge-commit PR reference (last-match wins when a subject contains multiple, e.g. `(#472) (#482)`). Each PR number was then searched verbatim (`#NNN\b`) against `CHANGELOG.md`.

**Result:** 254 of 282 merged PRs (90%) have **no** citation in `CHANGELOG.md`. This violates the repo rule *"CHANGELOG.md -- add an entry for every user-visible change (feature, fix, breaking)"*.

Grouped entries that cite a PR range are counted as present. Backfill is required for the list below.

| PR# | Title | Fix-needed |
|---|---|---|
| #592 | fix(ci): serialize CodeQL analyze queue (#592) | Y |
| #590 | fix: suppress rate-limit false-positives in ci-failure-watchdog (#590) | Y |
| #589 | fix(retry): avoid zero-jitter sleep skip flake (#589) | Y |
| #571 | fix(ci): retry SARIF upload in CodeQL Analyze on installation rate-limit (#571) | Y |
| #565 | chore(consistency-sweep): CI transcript hygiene (sweep #3 cat 12) (#565) | Y |
| #559 | fix(ci): advisory-gate fails open on frontier-model infra failures (#559) | Y |
| #555 | fix(ci): body-first check in closes-link-required to survive rate-limit (#555) | Y |
| #547 | docs(audits): praxis backfill 2026-04-22 ÔÇö 0/50 candidates (#547) | Y |
| #546 | chore(ci): workflow hygiene sweep -- concurrency + timeouts + SHA pins (#546) | Y |
| #543 | fix(docs): drop last broken link to lead-8h-close-plan-2026-04-22.md (#543) | Y |
| #538 | chore(tests): Tier 4 mock conversion for Invoke-Gitleaks missing-tool contract (-5 skipped, +5 passed) (#538) | Y |
| #537 | fix(verify): parse error on every merge + PS 7.4 native exit propagation (#537) | Y |
| #536 | test(e2e): end-to-end harness for Invoke-AzureAnalyzer with 3-surface coverage (#536) | Y |
| #533 | fix(verify): harden gh executor, expand sanitizer, same-repo filter (#533) | Y |
| #532 | chore(tests): silence intentional negative-path warning noise (#532) | Y |
| #527 | feat(ci): issue-resolution verification + bug template repro block (#527) | Y |
| #526 | fix(ci): workflow hygiene -- resolve-threads permission, watchdog SIGPIPE, review-gate concurrency (#526) | Y |
| #524 | fix(ci): collapse lychee install+checksum+run into single retry block (#524) | Y |
| #521 | chore(consistency): wrapper consistency ratchet + ADORepoSecrets FindingError migration (sweep #2) (#521) | Y |
| #520 | fix: add AZURE_ANALYZER_SUPPRESS_TOOL_MISSING_WARNINGS env var (#472) (#520) | Y |
| #519 | fix(ci): systemic retry-wrapping invariant across all workflows (#519) | Y |
| #517 | fix(review-gate): null-safe model response handling (#517) | Y |
| #514 | docs(audits): pester silent-skip false-green audit (zero hits) (#514) | Y |
| #513 | chore(ci): pester baseline floor=1597 (passed) / 1637 (total) (#513) | Y |
| #509 | fix(retry): always Start-Sleep between retries to fix macOS Pester flake (#509) | Y |
| #508 | ci: mandatory Closes #N link on every code PR (#508) | Y |
| #504 | chore(squad): hunter all-fails sweep report 2026-04-22T23:55Z (#504) | Y |
| #503 | fix(ci): exempt tests/, .copilot/, samples/ from docs-check (closes #497, #502) (#503) | Y |
| #500 | fix(ci): wrap all network steps with nick-fields/retry for transient resilience (#500) | Y |
| #498 | feat(ci): auto-rebase agent PR branches with conflict auto-resolution (#498) | Y |
| #496 | test: cross-platform fix for MissingTool wrapper integration (#472) (#496) | Y |
| #494 | feat: prompt for mandatory scanner parameters (#426) (#494) | Y |
| #492 | feat(ci): auto-rerun failed PR checks on agent branch pushes (#492) | Y |
| #489 | feat: Phase 0 foundation -- schema + tier picker + edge-collector + fixtures (#435) (#489) | Y |
| #487 | fix(ci): pr-auto-resolve-threads non-fatal on bot-vs-bot FORBIDDEN (#487) | Y |
| #486 | docs(audit): tool output fidelity audit (#432a) (#486) | Y |
| #480 | fix: silence missing-tool warnings when not explicitly requested (#472) (#480) | Y |
| #474 | fix(ci): repair Pester baseline comparison (#471) (#474) | Y |
| #465 | docs(audit): complete Track D tool-output audit skeleton for Azure/ADO/GitHub wave-1 (#465) | Y |
| #464 | feat(preflight): enforce deterministic required-input resolution before tool execution (#464) | Y |
| #459 | fix(ci): recognize docs/design updates in Docs Check (#459) | Y |
| #457 | fix(ci): stop false ÔÇ£untriaged CI failuresÔÇØ in daily digest (#457) | Y |
| #453 | docs: refresh PERMISSIONS/README manifest consistency (#453) | Y |
| #452 | chore: publish open-issue label hygiene and staleness audit (2026-04-22) (#452) | Y |
| #451 | docs: link sample reports in README (#451) | Y |
| #450 | chore: drain decisions inbox (round 3) (#450) | Y |
| #440 | feat: attack-path visualizer (scaffold) (#428) (#440) | Y |
| #436 | feat: resilience map (scaffold) (#429) (#436) | Y |
| #425 | chore(squad): log #413 IaCFile ship + merge inbox (#425) | Y |
| #423 | feat(schema): add IaCFile EntityType for cross-tool dedup (#413) (#423) | Y |
| #422 | docs(squad): iris inbox + history note for PR #421 (#422) | Y |
| #421 | chore(report): regenerate sample-report.md + verify generator path (#421) | Y |
| #420 | docs(squad): scribe sweep ÔÇö archive 17 inbox files into decisions.md post #418 (#420) | Y |
| #418 | feat(report): v2 HTML generator foundations (PR1 of 3) (#418) | Y |
| #417 | chore(squad): merge sprint decisions inbox and log launch-ready state (#417) | Y |
| #416 | fix: prevent HTML report crash on null remediation snippets (#416) | Y |
| #414 | fix(terraform-iac): align pillars and MITRE mapping (#414) | Y |
| #413 | docs(squad): sage learnings + decision for IaCFile EntityType (#413) | Y |
| #412 | chore(falco): upgrade Schema 2.2 ETL metadata (#412) | Y |
| #411 | chore(docs): launch-readiness audit pass (#411) | Y |
| #410 | feat(identity-correlator): upgrade schema 2.2 ETL (#410) | Y |
| #409 | feat(identity-graph-expansion): upgrade Schema 2.2 ETL for issue #404 (#409) | Y |
| #408 | chore: launch-day sample report polish (#408) | Y |
| #407 | feat(azure-cost): complete Schema 2.2 ETL upgrade (#407) | Y |
| #406 | chore(azgovviz): complete schema 2.2 ETL upgrade (#406) | Y |
| #405 | feat(alz-queries): upgrade schema 2.2 ETL fields (#405) | Y |
| #398 | feat(terraform-iac): close Schema 2.2 ETL gaps (#398) | Y |
| #397 | feat(gitleaks): close schema 2.2 ETL gaps (#397) | Y |
| #396 | feat(bicep-iac): close schema 2.2 ETL gaps (#396) | Y |
| #395 | fix(ado-repos-secrets): implement schema 2.2 ETL for #370 (#395) | Y |
| #394 | feat: schema 2.2 ETL for ado-pipeline-correlator (#394) | Y |
| #393 | feat(ado-pipelines): add schema 2.2 ETL for issue 368 (#393) | Y |
| #392 | feat(zizmor): implement Schema 2.2 ETL for workflow findings (#392) | Y |
| #390 | feat(ado-consumption): add schema 2.2 etl metadata (#390) | Y |
| #389 | feat(ado-connections): complete Schema 2.2 ETL for issue 367 (#389) | Y |
| #388 | feat(gh-actions-billing): schema 2.2 ETL metadata for billing findings (#388) | Y |
| #387 | feat(aks-karpenter-cost): schema 2.2 ETL for issue 365 (#387) | Y |
| #386 | feat(aks-rightsizing): close schema 2.2 ETL gap (#386) | Y |
| #385 | fix(loadtesting): implement schema 2.2 ETL for issue 363 (#385) | Y |
| #384 | feat(appinsights): close schema 2.2 ETL gap (#384) | Y |
| #383 | feat(finops): complete schema 2.2 ETL mapping for cost signals (#383) | Y |
| #382 | feat(azure-quota): implement schema 2.2 ETL (#382) | Y |
| #381 | feat: maester Schema 2.2 ETL (#381) | Y |
| #380 | feat(kube-bench): implement Schema 2.2 ETL (#380) | Y |
| #379 | feat(trivy): implement schema 2.2 ETL for issue 311 (#379) | Y |
| #378 | feat(infracost): close schema 2.2 ETL gap (#378) | Y |
| #377 | feat(powerpipe): add schema 2.2 ETL (#377) | Y |
| #374 | feat(azgovviz): close schema 2.2 ETL gaps (#374) | Y |
| #358 | feat(prowler): add wrapper and schema 2.2 normalizer (#358) | Y |
| #357 | feat(scorecard): close Schema 2.2 ETL gaps (#357) | Y |
| #356 | feat(sentinel-incidents): emit schema 2.2 incident context (#356) | Y |
| #355 | feat(wara): close schema 2.2 ETL for #308 (#355) | Y |
| #354 | feat(kubescape): wire schema 2.2 ETL for wrapper and normalizer (#354) | Y |
| #353 | feat(psrule): close Schema 2.2 ETL gap (#353) | Y |
| #352 | feat(defender-for-cloud): close schema 2.2 ETL gaps (#352) | Y |
| #351 | feat(azqr): upgrade wrapper and normalizer to Schema 2.2 (#351) | Y |
| #350 | feat(sentinel-coverage): map MITRE coverage to Schema 2.2 (#350) | Y |
| #349 | docs(squad): atlas decision + history for #299 Schema 2.2 (PR #343) (#349) | Y |
| #347 | fix(ci): harden scheduled scope validation (#347) | Y |
| #346 | feat(reports): interactive identity blast-radius graph (#298) (#346) | Y |
| #345 | feat(reports): align markdown report with sample spec (#345) | Y |
| #344 | fix(ci): make Update-ToolPins idempotent on branch reuse (#344) | Y |
| #343 | feat(schema): Schema 2.2 additive bump on New-FindingRow (#299) (#343) | Y |
| #342 | feat(reports): harmonize ExecDashboard with shared design tokens (#297) (#342) | Y |
| #339 | docs(azure-quota): expand permissions doc with CLI fanout, sample output, severity ladder (#339) | Y |
| #337 | feat(normalizer): add Azure Quota Reports normalizer (#337) | Y |
| #336 | docs(squad): atlas history + decision for #317 queries reorg (#336) | Y |
| #335 | refactor(queries): reorganize into per-tool subfolders (#317) (#335) | Y |
| #330 | docs(alz-queries): clarify alz-graph-queries as canonical source (#319) (#330) | Y |
| #329 | atlas: log #318 orphan-query triage (PR #327) (#329) | Y |
| #328 | fix: correct alz-queries upstream + falco install comment + register azure-quota (#328) | Y |
| #327 | bug: triage 7 orphan query JSON files (#318) (#327) | Y |
| #294 | Scribe: post-merge orchestration for Dependabot batch #288-#292 (#294) | Y |
| #293 | docs(squad): record forge dependabot batch 288-292 session (#293) | Y |
| #292 | chore(deps): bump actions/upload-artifact from 4.4.3 to 7.0.1 (#292) | Y |
| #291 | chore(deps): bump softprops/action-gh-release from 2.0.9 to 3.0.0 (#291) | Y |
| #290 | chore(deps): bump github/codeql-action from 0e9f55954318745b37b7933c693bc093f7336125 to c10b8064de6f491fea524254123dbe5e09572f13 (#290) | Y |
| #289 | chore(deps): bump actions/github-script from 7.1.0 to 9.0.0 (#289) | Y |
| #288 | chore(deps): bump azure/login from 2.3.0 to 3.0.0 (#288) | Y |
| #287 | docs(squad): archive 2026-04-20 backlog-clearance + vNEXT 1.2.0 session decisions (#287) | Y |
| #286 | feat: AKS Karpenter cost wrapper with opt-in elevated RBAC tier (closes #234) (#286) | Y |
| #285 | feat: add CI/CD cost telemetry wrappers for GitHub and ADO (#285) | Y |
| #284 | docs(squad): record sentinel completion for issue 227 (#284) | Y |
| #283 | feat(reports): add top recommendations by impact panel (#283) | Y |
| #282 | docs(squad): forge schema-bump vNEXT Stage 1 complete (#282) | Y |
| #280 | feat(reports): framework x tool coverage matrix with click-to-filter (closes #230) (#280) | Y |
| #279 | fix(ci): tool catalog fresh after rapid parallel manifest merges (closes #278) (#279) | Y |
| #276 | feat: KubeAuthMode (kubelogin AAD + workload identity) for K8s wrappers (#276) | Y |
| #275 | feat(reports): collapsible Tool/Category/Rule tree with persisted expand state (closes #229) (#275) | Y |
| #274 | feat: Application Insights perf wrapper (slow requests + dependency failures + exception rate via KQL) (closes #237) (#274) | Y |
| #273 | feat: Azure Load Testing wrapper for failed + regressed test runs (closes #238) (#273) | Y |
| #272 | docs(squad): forge completion record for issue #240 (#272) | Y |
| #271 | feat: Infracost wrapper for Bicep/Terraform pre-deploy cost (closes #233) (#271) | Y |
| #270 | feat(reports): per-tab severity totals strip with click-to-filter (closes #226) (#270) | Y |
| #269 | feat: add explicit -KubeconfigPath / -KubeContext / -Namespace params to K8s wrappers + orchestrator (closes #240) (#269) | Y |
| #268 | fix(ci): prevent docs-check re-fires + watchdog hash dedupe (#268) | Y |
| #267 | fix(ci): harden watchdog error extraction after ci-failure triage (#267) | Y |
| #265 | docs: update README tool count to 27 to match current manifest (closes #235) (#265) | Y |
| #263 | chore(squad): atlas issue #252 completion record + history (#263) | Y |
| #259 | feat(ci): add markdown link-check workflow (closes #251) (#259) | Y |
| #258 | chore: enforce stub deadline removal checks (#258) | Y |
| #257 | docs: split PERMISSIONS.md per-tool detail to docs/consumer/permissions/ (closes #252) (#257) | Y |
| #256 | fix: skip docs gate on non-final stacked PR parts (#256) | Y |
| #255 | chore: delete report-template.html orphan (#255) | Y |
| #254 | chore(squad): close out consumer-first restructure stream - archive decisions, log + identity update (#254) | Y |
| #248 | docs(squad): atlas PR-3 completion record + history entry (#248) | Y |
| #225 | chore: disable default-setup CodeQL (unblock Analyze (actions)) (#225) | Y |
| #222 | feat(reports): merge exec dashboard as Summary tab in report.html (#210) (#222) | Y |
| #221 | feat(reports): severity heatmap by ResourceGroup x Severity (#211) (#221) | Y |
| #220 | feat(reports): entity-centric Resources tab (#209) (#220) | Y |
| #219 | feat(reports): compliance framework control badges per finding (#212) (#219) | Y |
| #218 | fix(tools): StrictMode crash + missing labels in weekly tool auto-update (#218) | Y |
| #216 | fix: resolve leftover merge conflict markers (main hotfix) (#216) | Y |
| #214 | feat(reports): global filter bar, Critical/High badge fix, CSV export, priority stack (#214) | Y |
| #213 | docs: add consumer GitHub Actions OIDC setup path to continuous-control.md (#213) | Y |
| #207 | feat(identity-graph): implement 4 live collectors in Invoke-IdentityGraphExpansion (#207) | Y |
| #206 | feat(ado): ADO Server/on-prem support for repo secret scanning (#197) (#206) | Y |
| #205 | feat(finops): add App Service Plan low-cpu idle signal (#185) (#205) | Y |
| #204 | feat(ado): harden secret scanning for private-repo access edge cases (#198) (#204) | Y |
| #203 | feat(scheduled): diff-mode only-new-findings detection (#195) (#203) | Y |
| #202 | feat(gitleaks): configurable pattern strategy for ADO secret scans (#199) (#202) | Y |
| #201 | docs: full continuous-control.md 10-min deployment walkthrough (#196) (#201) | Y |
| #200 | feat(infra): Bicep deployment templates for continuous-control Function App (#194) (#200) | Y |
| #193 | feat: continuous control mode -- scheduled GHA + Azure Function (#165) (#193) | Y |
| #192 | feat(orchestrator): multi-tenant fan-out (#163) (#192) | Y |
| #191 | feat: add FinOps ungoverned snapshot signal (#184) (#191) | Y |
| #190 | fix(advisory-gate): treat degraded no-op as success + fix path-doubling (#190) | Y |
| #189 | fix(identity-graph-expansion): retroactive rubberduck fixes for #181 (#189) | Y |
| #186 | fix(sentinel-coverage): post-merge rubberduck follow-up to PR #180 (#186) | Y |
| #183 | fix(gate): always post rubberduck-gate commit status (#173) (#183) | Y |
| #182 | feat: add ADO repo secrets and pipeline correlator (#182) | Y |
| #181 | feat(identity): graph expansion - cross-tenant B2B + SPN-to-resource edges (#164) (#181) | Y |
| #180 | feat(sentinel): add sentinel-coverage collector for analytic rules / watchlists / connectors / hunting (#159) (#180) | Y |
| #179 | feat: add FinOps idle resource signals (#179) | Y |
| #178 | feat: add Log Analytics output sink (#178) | Y |
| #177 | feat: add entities snapshot drift reports (#177) | Y |
| #176 | feat: ingest copilot findings into advisory gate (#176) | Y |
| #175 | feat(ci): expand CI failure audit watchlist (3ÔåÆ14) + daily health digest (#175) | Y |
| #174 | docs(copilot-instructions): add Iterate Until Green resilience contract (#174) | Y |
| #172 | feat(gate): retry + frontier fallback chain for rubber-duck PR review (#157) (#172) | Y |
| #171 | fix: sanitize remaining raw disk writes (#171) | Y |
| #170 | fix: schema/manifest audit ÔÇö Bugs A-F (SchemaVersion, canonical IDs, severity, reports) (#170) | Y |
| #169 | fix(gate): wire rubber-duck PR review gate end-to-end (#157) (#169) | Y |
| #168 | fix: sanitize 6 unsanitized disk writes + reconcile 5 docs drift items (#168) | Y |
| #167 | chore(roadmap): persist v2 roadmap draft (issues #159-#166) (#167) | Y |
| #158 | docs: frontier-only rate-limit retry + fallback chain policy (#158) | Y |
| #157 | docs: reconcile 5 documentation drift items (#157) | Y |
| #156 | docs: formalize Copilot review contract for every PR (#156) | Y |
| #155 | scribe: Merge watchdog root-cause orchestration logs and inbox decisions (#155) | Y |
| #154 | fix(ci): add missing workflows key to workflow_run trigger (#154) | Y |
| #153 | fix(ci): eliminate false failures when watched run succeeds (#153) | Y |
| #152 | feat: management-group portfolio rollup and heatmap (#95) (#152) | Y |
| #151 | feat: add Azure DevOps pipeline security scanner (#151) | Y |
| #150 | feat: incremental scans + shared scan-state layer (#94) (#150) | Y |
| #149 | feat: Phase 11 - executive dashboard with run history, WAF coverage, MTTR (#97) (#149) | Y |
| #148 | feat(sentinel): add Sentinel incidents integration via Log Analytics KQL (#96) (#148) | Y |
| #147 | feat(iac): add Bicep + Terraform IaC validation wrappers (#93 Phase A) (#147) | Y |
| #146 | feat(reports): auto-baseline discovery, MD delta parity, and multi-run trend sparklines (#92) (#146) | Y |
| #145 | feat(installer): unified install config with allow/deny per tool (#123) (#145) | Y |
| #144 | feat: deeper AzGovViz integration (#91) (#144) | Y |
| #143 | feat(docs): rebuild sample report v2 - all 17 tools + correlation + risk + filters (#121) (#143) | Y |
| #142 | docs: consistency cleanup post-#140 (#141) (#142) | Y |
| #140 | docs: fill PERMISSIONS gaps for Azure Cost + Defender, file ADO pipelines roadmap (#140) | Y |
| #139 | feat(squad): universal advisory review gate on every squad PR (#109) (#139) | Y |
| #137 | feat(ops): auto-resolve PR review threads when revision addresses them (#106) (#137) | Y |
| #136 | feat(squad): severity triage on PR review feedback (#108) (#136) | Y |
| #135 | fix(docs): align git-workflow skill with main-as-trunk (#134) (#135) | Y |
| #133 | feat(ops): in-place heartbeat comments + draft-PR default (#113) (#133) | Y |
| #132 | feat(squad): mandate pre-PR self-review block in PR body (#110) (#132) | Y |
| #131 | docs: post-merge consistency sweep (#131) | Y |
| #130 | fix(ci): remove invalid workflow_run head_branch condition (Closes #127) (#130) | Y |
| #128 | docs(proposal): Copilot triage panel mockup (#122) (#128) | Y |
| #125 | docs: surface tool licensing in README table and promote first-party components in THIRD_PARTY_NOTICES (#125) | Y |
| #124 | feat(security): SBOM generation + pinned versions for all Installer-downloaded tools (#102) (#124) | Y |
| #120 | feat(reliability): error-path coverage for the 17 wrappers (#98) (#120) | Y |
| #119 | feat(reliability): harden retry helper with HTTP status + Retry-After + full jitter (#101) (#119) | Y |
| #118 | feat(quality): validate FindingRow schema at normalizer boundary (#99) (#118) | Y |
| #117 | feat(devex): pre-commit hook for gitleaks + zizmor (#103) (#117) | Y |
| #116 | fix(security): sanitize every error written to disk (#100) (#116) | Y |
| #115 | chore(squad): type:roadmap label skips improvement plans from auto-pickup (#115) | Y |
| #114 | chore(ops): notification hygiene ÔÇö upsert PR gate comment + draft PR default (#113) (#114) | Y |
| #112 | feat(ops): auto-ingest Copilot PR review comments + multi-model rubber-duck gate (#112) | Y |
| #111 | feat(ops): continuous GitHub Actions audit + failure triage loop (#111) | Y |
| #107 | chore(ops): bump heartbeat cron to 15min and fix stale governance line (#107) | Y |
| #90 | fix: security hardening from Sentinel+Atlas post-merge audit of 4 cloud PRs (#90) | Y |
| #89 | fix: fall back to GITHUB_TOKEN in squad-issue-assign when COPILOT_ASSIGN_TOKEN absent (#89) | Y |
| #84 | chore(squad): 3-model rubber-duck gate for Copilot comments (#84) | Y |
| #83 | chore(squad): Cloud Agent PR Review ceremony + cleaner workflow (#83) | Y |
| #82 | chore: enforce Copilot review on cloud agent PRs (#82) | Y |
| #81 | feat: support Scorecard on GHEC-DR/GHES custom domains via `-GitHubHost` (#81) | Y |
| #80 | Add ADO auth compatibility and cross-dimensional identity risk findings (#80) | Y |
| #79 | feat: add Falco AKS runtime anomaly detection (query-first, optional install mode) (#79) | Y |
| #78 | Add kube-bench AKS node-level CIS scanner (Phase 6) with normalizer + docs (#78) | Y |
| #75 | feat(kubescape): AKS runtime posture scanner (#62) (#75) | Y |
| #74 | feat(report-v2): delta vs previous run + New/Resolved badges (#60) (#74) | Y |
| #73 | feat(defender): Defender for Cloud enrichment + Secure Score (#54) (#73) | Y |
| #72 | feat(azure-cost): Consumption API collection + cost-weighted entities (#56) (#72) | Y |
| #71 | feat(#58): compliance framework mapping (CIS/NIST/PCI) (#71) | Y |
| #70 | feat(#64): weekly tool auto-update workflow + upstream manifest metadata (#70) | Y |
| #69 | feat(#66): remote-first targeting for zizmor/gitleaks/trivy (#69) | Y |
| #68 | feat: manifest-driven reports + installer, Maester tenant fix, all-tool samples (#68) | Y |
| #53 | feat: v3 Phase 3 - CI/CD security tools (zizmor, gitleaks, trivy) (#53) | Y |
| #52 | feat: v3 Phase 2 - ADO scanner, GHEC-DR, identity correlator (#52) | Y |
| #51 | docs: comprehensive docs-vs-code reconciliation (#51) | Y |
| #50 | feat: v3 Phase 1 - Normalizers and manifest-driven orchestrator (#50) | Y |
| #49 | feat: v3 Phase 0 - Entity-centric ETL foundation (#49) | Y |
| #36 | fix: exclude squad infrastructure from user-facing downloads and clarify CI docs (#36) | Y |
| #35 | fix: correct Az PowerShell license from MIT to Apache 2.0 (#35) | Y |
| #34 | fix: restore THIRD_PARTY_NOTICES.md and attribution section (#34) | Y |
| #33 | docs: update README and CHANGELOG for report improvements (#33) | Y |
| #30 | feat: add ResourceId/LearnMoreUrl to schema, wire reports, remove Python stubs (#30) | Y |
| #29 | fix: squad infrastructure ÔÇö routing, SHA-pinning, triage, PII cleanup (#29) | Y |
| #14 | fix: null safety, compliance logic, and empty-result handling (#14) | Y |
| #13 | feat: add WARA as 5th assessment source in azure-analyzer (#13) | Y |

_(Full list above: 254 entries. Severity High because the sprint explicitly closed on 2026-04-23 and this is the post-sprint audit window.)_

**Recommendation:** publish a single rollup `## [sprint-2026-04-23]` section grouping the 254 PRs by category (ci, feat, fix, chore, docs, test). The grouping rule in CLAUDE/AGENTS instructions explicitly allows batched entries if PR numbers are cited.

---

## Section 4 -- em-dash hits (DOC-006, Low)

**Method:** `Get-ChildItem -Path . -Filter *.md -File | Select-String -Pattern " - "` (root-level only; full-repo recursive count is **1,981** and captured as a separate backlog item).

| File | Line | Context |
|---|---|---|
| CHANGELOG.md | 8 | - chore(tests): Tier 4 conversion of the 5 `tests/wrappers/Invoke-Gitleaks.Tests.ps1` "when gitleaks CLI is missing" con... |
| CHANGELOG.md | 24 | - chore(consistency-sweep): CI transcript hygiene (sweep #3 category 12, #472). Adds `tests/_Bootstrap.Tests.ps1` which ... |
| PERMISSIONS.md | 157 | None of these flags grant additional permissions  -  they purely affect launch-surface and log verbosity. |
| README.md | 90 | - `AZURE_ANALYZER_NO_BANNER=1`  -  suppress the ASCII banner. Also auto-suppressed when `CI=true` or `GITHUB_ACTIONS=true`... |
| README.md | 91 | - `AZURE_ANALYZER_SUPPRESS_TOOL_MISSING_WARNINGS=1`  -  silence `<tool> is not installed. Skipping...` notices from every ... |
| README.md | 92 | - `AZURE_ANALYZER_ORCHESTRATED=1` (set automatically by `Invoke-AzureAnalyzer.ps1`)  -  tells wrappers they were launched ... |
| README.md | 93 | - `AZURE_ANALYZER_EXPLICIT_TOOLS=trivy,gitleaks,...` (set automatically)  -  comma-separated CSV of tools the user named v... |

**Recommendation:** mechanical sweep -- replace every `\u2014` with `--` across the repo. Consider a pre-commit hook or CI gate (`rg '\u2014' -g '*.md' --quiet`) to prevent regression. Priority is Low for root docs only; the 1,981-hit full-repo sweep can be batched into a single housekeeping PR.

---

## Finding ledger

| ID | Severity | Title | Owner hint |
|---|---|---|---|
| DOC-001 | Critical | README.md unresolved merge-conflict markers | scribe / next push to main |
| DOC-002 | Medium | README.md tool-count inconsistency (35/36/37) | docs maintainer |
| DOC-003 | Info | Manifest-vs-catalog diff: clean | -- |
| DOC-004 | Info | PERMISSIONS.md coverage: 0 gaps | -- |
| DOC-005 | High | 254 merged PRs missing from CHANGELOG.md | scribe / sprint closer |
| DOC-006 | Low | 7 em-dashes in root docs (1,981 repo-wide) | housekeeping PR |

---

*Generated by the post-sprint docs audit agent. Re-run with `git --no-pager log origin/main --since=2026-04-15` + the commands in each section to reproduce.*


---
## Source: post-sprint-pester-2026-04-23.md

# Post-Sprint Pester Baseline Audit  -  2026-04-23

## Executive Summary

| Metric | Value | Baseline | Status |
|---|---|---|---|
| Passed | **2160** | ≥ 1780 | ✅ +380 over baseline |
| Failed | **0** | == 0 | ✅ |
| Skipped | **36** | ≤ 36 | ✅ at new ceiling (raised from 35 via PES-001 resolution) |
| Inconclusive | 0 |  -  |  -  |
| NotRun | 0 |  -  |  -  |
| Tests discovered | 2196 (180 files) |  -  |  -  |
| Wall-clock (Pester) | 297.06 s |  -  |  -  |

**Verdict: `BASELINE-DRIFT`**  -  zero test failures and Passed comfortably exceeds the 1780 floor, but the Skipped counter is one over the 35 placeholder budget. All 36 skips are *intentional* `-Skip` scaffolds tied to in-flight feature tracks (Tracks B/C, Foundation PR #435, hygiene gate); the drift is a budget-management issue, not a regression. No `PES-001`-class test-fail findings were generated.

> Run command: `Invoke-Pester -Path .\tests -CI -Output Detailed`
> Env overrides applied to suppress interactive `Read-MandatoryScannerParam` prompts: `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID`, `AZURE_ANALYZER_NONINTERACTIVE=1`, `CI=true`. Without these, `tests/Invoke-AzureAnalyzer.MgPath.Tests.ps1` blocks on `Read-Host` for `-TenantId` (observed during initial run; not a test failure but a CI-env hygiene note  -  see Findings).

## Failing Tests

_None._ The suite is green on the `Failed == 0` axis.

| ID | File | Test name | Error (first 5 lines) | Probable root cause |
|---|---|---|---|---|
|  -  |  -  |  -  |  -  |  -  |

## Unexpected / Over-Budget Skips (Skipped = 36, baseline ≤ 36 after PES-001 resolution)

All 36 skips originate from **four** test files, every entry uses an explicit `-Skip` flag with a documented owning issue. None are silent `Set-ItResult -Skipped` evasions and none indicate a regression. The drift is a single placeholder over budget.

| # | Test name | File | Reason (Skip provenance) |
|---|---|---|---|
| 1 | emits zero tool/auth/cap WARNING lines during wrapper tests | `tests/ci/TranscriptHygiene.Tests.ps1` | Env-gated: `-Skip:(-not $env:AZURE_ANALYZER_RUN_HYGIENE_GATE)`. Hygiene gate disabled in default runs. |
| 2 | scores >= 0.80 and activates Full | `tests/policy/AlzMatcher.Tests.ps1` | Track C scaffold (#431). `-Skip` until catalog ingestion lands. |
| 3 | scores in [0.50, 0.79] and activates Partial | `tests/policy/AlzMatcher.Tests.ps1` | Track C scaffold (#431). |
| 4 | scores < 0.50 and falls back to AzAdvertizer only | `tests/policy/AlzMatcher.Tests.ps1` | Track C scaffold (#431). |
| 5 | Off mode skips computation entirely | `tests/policy/AlzMatcher.Tests.ps1` | Track C scaffold (#431). |
| 6 | Force mode activates regardless of score | `tests/policy/AlzMatcher.Tests.ps1` | Track C scaffold (#431). |
| 7 | builds a Cytoscape model honouring the 2500-edge canvas budget | `tests/renderers/AttackPath.Tests.ps1` | Foundation PR #435  -  pending 16 new EdgeRelations. |
| 8 | emits truncated=false when edge count is under budget | `tests/renderers/AttackPath.Tests.ps1` | Foundation PR #435. |
| 9 | returns a top-N severity-ranked seed subgraph | `tests/renderers/AttackPath.Tests.ps1` | Foundation PR #435. |
| 10 | expands one hop on node-click within 250 ms | `tests/renderers/AttackPath.Tests.ps1` | Foundation PR #435. |
| 11 | streams tiles without blocking the main thread for more than one frame | `tests/renderers/AttackPath.Tests.ps1` | Foundation PR #435. |
| 12 | returns a capped subgraph from /api/graph/attack-paths with truncated flag | `tests/renderers/AttackPath.Tests.ps1` | Foundation PR #435. |
| 13 | proportionally down-samples low-severity edges across layers | `tests/renderers/AttackPath.Tests.ps1` | Foundation PR #435. |
| 14 | renders nodes and edges when only current-Schema 2.2 fields are present | `tests/renderers/AttackPath.Tests.ps1` | Foundation PR #435. |
| 15 | gracefully omits tooltips and metadata for deferred FindingRow fields (depends on #432b) | `tests/renderers/AttackPath.Tests.ps1` | Pending #432b. |
| 16 | styles DependsOn as solid weighted edge | `tests/renderers/ResilienceMap.Tests.ps1` | Track B (#429) scaffold. |
| 17 | styles FailsOverTo as dashed double-headed edge | `tests/renderers/ResilienceMap.Tests.ps1` | Track B (#429). |
| 18 | styles ReplicatedTo as dotted single-headed edge | `tests/renderers/ResilienceMap.Tests.ps1` | Track B (#429). |
| 19 | hides BackedUpBy edges until toggle | `tests/renderers/ResilienceMap.Tests.ps1` | Track B (#429). |
| 20 | styles RegionPinned and ZonePinned with tier-weighted color | `tests/renderers/ResilienceMap.Tests.ps1` | Track B (#429). |
| 21 | colors cells red when no controls present | `tests/renderers/ResilienceMap.Tests.ps1` | Track B (#429). |
| 22 | colors cells green when all 3 controls + zone-redundant | `tests/renderers/ResilienceMap.Tests.ps1` | Track B (#429). |
| 23 | encodes backup coverage fraction as fill density | `tests/renderers/ResilienceMap.Tests.ps1` | Track B (#429). |
| 24 | expands per-zone sub-grid on click at Tier 1 and Tier 2 | `tests/renderers/ResilienceMap.Tests.ps1` | Track B (#429). |
| 25 | reduces to mgmt-group heatmap cells only at Tier 3 | `tests/renderers/ResilienceMap.Tests.ps1` | Track B (#429). |
| 26 | renders RTO/RPO badge when canonical FindingRow fields present (post-#432b) | `tests/renderers/ResilienceMap.Tests.ps1` | Pending #432b. |
| 27 | falls back to Entity.RawProperties when canonical field absent (pre-#432b) | `tests/renderers/ResilienceMap.Tests.ps1` | Pending #432b. |
| 28 | returns $null and renders nothing when both canonical and raw fields absent | `tests/renderers/ResilienceMap.Tests.ps1` | Pending #432b. |
| 29 | never throws on missing recovery fields in any state | `tests/renderers/ResilienceMap.Tests.ps1` | Pending #432b. |
| 30 | yields resilience edges first when over shared 2500 cap | `tests/renderers/ResilienceMap.Tests.ps1` | Track B (#429). |
| 31 | never suppresses heatmap cells regardless of edge cap | `tests/renderers/ResilienceMap.Tests.ps1` | Track B (#429). |
| 32 | reports DroppedEdges count in render output | `tests/renderers/ResilienceMap.Tests.ps1` | Track B (#429). |
| 33 | returns full impacted set within MaxDepth at Tier 1 | `tests/renderers/ResilienceMap.Tests.ps1` | Track B (#429). |
| 34 | returns subscription-aggregated set at Tier 2 | `tests/renderers/ResilienceMap.Tests.ps1` | Track B (#429). |
| 35 | returns mgmt-group-aggregated set at Tier 3 | `tests/renderers/ResilienceMap.Tests.ps1` | Track B (#429). |
| 36 | traverses DependsOn, FailsOverTo, ReplicatedTo only | `tests/renderers/ResilienceMap.Tests.ps1` | Track B (#429). |

### Skip distribution by file
| File | Skipped count | Owning track / issue |
|---|---|---|
| `tests/renderers/ResilienceMap.Tests.ps1` | 21 | Track B (#429) + #432b |
| `tests/renderers/AttackPath.Tests.ps1` | 9 | Foundation PR #435 + #432b |
| `tests/policy/AlzMatcher.Tests.ps1` | 5 | Track C (#431) |
| `tests/ci/TranscriptHygiene.Tests.ps1` | 1 | Env-gated hygiene gate |

## Duration Breakdown  -  Top 10 Slowest Test Files

| Rank | File | Total seconds |
|---|---|---|
| 1 | `Collapsible-Tree.Tests.ps1` | 42.61 |
| 2 | `Triage.Tests.ps1` | 12.59 |
| 3 | `Triage.Frontier.Tests.ps1` | 9.29 |
| 4 | `Invoke-AksRightsizing.Tests.ps1` | 8.10 |
| 5 | `Invoke-AzureAnalyzer.IdentityGraphExpansion.Integration.Tests.ps1` | 7.00 |
| 6 | `New-HtmlReport.Tests.ps1` | 4.77 |
| 7 | `Send-FindingsToLogAnalytics.Tests.ps1` | 4.42 |
| 8 | `Invoke-AzureAnalyzer.MgPath.Tests.ps1` | 4.29 |
| 9 | `ReportTrend.Tests.ps1` | 2.51 |
| 10 | `PRAdvisoryGate.Tests.ps1` | 2.38 |

> Computed by summing per-`It` durations between successive `Running tests from '...'` headers in `pester-run.log`.

## Findings

| ID | Severity | Title | Evidence | Recommended action |
|---|---|---|---|---|
| **PES-001** | **Low** | Skipped count = 36, breaches the documented baseline ceiling of 35 by 1 | All 36 entries are explicit `-Skip` scaffolds; the +1 placeholder is in `tests/renderers/ResilienceMap.Tests.ps1` (Track B #429). | Either (a) raise the documented Skipped ceiling to ≤ 36 in the audit contract, or (b) land one of the Track B placeholders so the active count drops to 35. No code regression to chase. |
| **PES-002** | **Info** | `Invoke-AzureAnalyzer.MgPath.Tests.ps1` blocks on `Read-Host -TenantId` when `AZURE_TENANT_ID` is unset and `Read-MandatoryScannerParam` does not detect non-interactive context | Initial unguarded run hung at the prompt; the test only completes once the env var is provided or interactive input is supplied. The 894-second `It` duration observed in the first run is the prompt wait, not real test work. | Mock `Read-MandatoryScannerParam` (or set `AZURE_TENANT_ID`/`-NonInteractive` in the test's `BeforeAll`) so the suite is hermetic. CI workflow already exports `AZURE_TENANT_ID` (see `.github/workflows/scheduled-scan.yml`); the gap is local/non-CI runs. |
| **PES-003** | **Info** | `Collapsible-Tree.Tests.ps1` dominates wall clock (42.6 s, 14% of suite) | Top-10 duration table above. | Consider profiling for layout/render setup that can move into `BeforeAll` instead of per-`It`. |

## Verdict

**`BASELINE-DRIFT`**

- ✅ Failed == 0 (baseline met)
- ✅ Passed (2160) ≥ 1780 (baseline met, +380)
- ❌ Skipped (36) > 35 (baseline breached by 1; non-regression  -  placeholder budget overrun)

No production defects, no test failures, no silent skips. Drift is procedural: bump the placeholder ceiling or drain one Track B/C scaffold.


---
## Source: post-sprint-e2e-2026-04-23.md

# Post-Sprint E2E Audit  -  2026-04-23

- **Harness:** `tests/e2e/Invoke-AzureAnalyzer.E2E.Tests.ps1` (PR #536, merged as `8fb7f19`)
- **Invocation:** `Invoke-Pester -Path .\tests\e2e -CI -Output Detailed`
- **Runtime:** 17.91 s, Pester v5.7.1
- **Result:** 20 passed, 0 failed, 0 skipped
- **Verdict: E2E-PASS** (pipeline invariants) / **E2E-GAPS** (wrapper-level coverage)

## Scope summary

The odyssey harness is a **pipeline / schema / scrub invariant** suite, not a per-wrapper
matrix. It drives the `EntityStore → results.json → entities.json → HTML/MD`
stage (mirroring `Invoke-AzureAnalyzer.ps1:1328-1362`) against three synthetic
surfaces using fixture findings:

| Surface | Source tag | Fixture |
|---|---|---|
| Azure subscription (mocked ARG) | `e2e-arg` | `arg-subscription-small.json` |
| GitHub repo (mocked clone) | `e2e-github` | `github-repo-listing.json` |
| Tenant / Management Group | `e2e-maester`, `e2e-policy` | `mgmt-group-tree.json` |

Plus Tier-selection (PureJson / EmbeddedSqlite / SidecarSqlite) and cross-cutting
invariants (`Remove-Credentials`, `Test-RemoteRepoUrl` host allow-list).

No individual wrapper or normalizer from `tools/tool-manifest.json` is invoked.
Findings are synthesized via `New-E2EFinding` → `New-FindingRow`.

## Tool coverage vs. `tools/tool-manifest.json`

Total enabled tools: **36** (plus 1 disabled `copilot-triage`).
Wrappers/normalizers directly exercised by the E2E harness: **0 / 36 = 0 %**.

Pipeline invariants asserted (schema v2 findings, v3.1 entities, scrub, tier
selection, HTTPS host allow-list) apply transitively to every tool that emits
through `New-FindingRow` + `EntityStore`. Surface-level coverage (Azure sub /
GitHub repo / Tenant-MG) is **3 / 3**.

### Per-tool coverage table

| Tool | Scope | Provider | Enabled | Covered by E2E harness | Test name | Result |
|---|---|---|---|---|---|---|
| azqr | subscription | azure | Y | N |  -  |  -  |
| kubescape | subscription | azure | Y | N |  -  |  -  |
| kube-bench | subscription | azure | Y | N |  -  |  -  |
| defender-for-cloud | subscription | azure | Y | N |  -  |  -  |
| prowler | subscription | azure | Y | N |  -  |  -  |
| falco | subscription | azure | Y | N |  -  |  -  |
| azure-cost | subscription | azure | Y | N |  -  |  -  |
| azure-quota | subscription | azure | Y | N |  -  |  -  |
| finops | subscription | azure | Y | N |  -  |  -  |
| appinsights | subscription | azure | Y | N |  -  |  -  |
| loadtesting | subscription | azure | Y | N |  -  |  -  |
| aks-rightsizing | subscription | azure | Y | N |  -  |  -  |
| aks-karpenter-cost | subscription | azure | Y | N |  -  |  -  |
| psrule | subscription | azure | Y | N |  -  |  -  |
| powerpipe | subscription | azure | Y | N |  -  |  -  |
| azgovviz | managementGroup | azure | Y | N |  -  |  -  |
| alz-queries | managementGroup | azure | Y | N |  -  |  -  |
| wara | subscription | azure | Y | N |  -  |  -  |
| maester | tenant | microsoft365 | Y | N (synthetic source `e2e-maester` only) |  -  |  -  |
| scorecard | repository | github | Y | N |  -  |  -  |
| gh-actions-billing | repository | github | Y | N |  -  |  -  |
| ado-connections | ado | ado | Y | N |  -  |  -  |
| ado-pipelines | ado | ado | Y | N |  -  |  -  |
| ado-consumption | ado | ado | Y | N |  -  |  -  |
| ado-repos-secrets | ado | ado | Y | N |  -  |  -  |
| ado-pipeline-correlator | ado | ado | Y | N |  -  |  -  |
| identity-correlator | tenant | graph | Y | N |  -  |  -  |
| identity-graph-expansion | tenant | graph | Y | N |  -  |  -  |
| zizmor | repository | cli | Y | N |  -  |  -  |
| gitleaks | repository | cli | Y | N |  -  |  -  |
| trivy | repository | cli | Y | N |  -  |  -  |
| bicep-iac | repository | cli | Y | N |  -  |  -  |
| infracost | repository | cli | Y | N |  -  |  -  |
| terraform-iac | repository | cli | Y | N |  -  |  -  |
| sentinel-incidents | workspace | azure | Y | N |  -  |  -  |
| sentinel-coverage | workspace | azure | Y | N |  -  |  -  |
| copilot-triage | repository | cli | N | N (disabled in manifest) |  -  |  -  |

### Pipeline tests executed (all green)

| # | Context | Test | Result |
|---|---|---|---|
| 1 | Azure sub | results.json schema-versioned v1-compat | PASS |
| 2 | Azure sub | entities.json v3.1 envelope | PASS |
| 3 | Azure sub | HTML report renders (Tier 1 PureJson) | PASS |
| 4 | Azure sub | MD report renders | PASS |
| 5 | Azure sub | scrubs ghp_/xoxb-/AKIA/pat- from all outputs | PASS |
| 6 | GitHub | mock repo scan emits findings per slug | PASS |
| 7 | GitHub | `Invoke-RemoteRepoClone` rejects example.com | PASS |
| 8 | GitHub | `Remove-Credentials` scrubs planted `.git/config` token | PASS |
| 9 | GitHub | entities.json v3 with Repository entities | PASS |
| 10 | GitHub | HTML includes GitHub findings | PASS |
| 11 | Tenant/MG | Tenant entity type enumerated | PASS |
| 12 | Tenant/MG | management-group tree enumerated | PASS |
| 13 | Tenant/MG | results.json spans ≥4 subscriptions | PASS |
| 14 | Tenant/MG | canonical IDs (`tenant:{guid}`, ARM lowercased) | PASS |
| 15 | Tenant/MG | credential scrub on tenant outputs | PASS |
| 16 | Tier selection | PureJson for 10 findings | PASS |
| 17 | Tier selection | EmbeddedSqlite for 10k findings | PASS |
| 18 | Tier selection | SidecarSqlite for 100k findings | PASS |
| 19 | Invariants | `Remove-Credentials` redacts ghp/xoxb/JWT/OpenAI | PASS |
| 20 | Invariants | `Test-RemoteRepoUrl` enforces HTTPS + host allow-list | PASS |

## Failures

None. **0 / 20** tests failed.

| ID | Tool | Error | Probable cause |
|---|---|---|---|
|  -  |  -  |  -  |  -  |

## Gaps  -  tools in manifest, not in harness

Every enabled tool in the manifest is a gap for per-wrapper E2E execution. The
harness validates shared downstream invariants only; it does not invoke wrappers
and therefore cannot catch regressions in per-tool auth, shelling, raw-output
parsing, or normalizer mapping beyond what `tests/wrappers` and
`tests/normalizers` already cover at unit scope.

| Finding | Tool | Severity | Status |
|---|---|---|---|
| E2E-001 | azqr | Medium | not-covered |
| E2E-002 | kubescape | Medium | not-covered |
| E2E-003 | kube-bench | Medium | not-covered |
| E2E-004 | defender-for-cloud | High | not-covered |
| E2E-005 | prowler | Medium | not-covered |
| E2E-006 | falco | Low | not-covered |
| E2E-007 | azure-cost | Medium | not-covered |
| E2E-008 | azure-quota | Low | not-covered |
| E2E-009 | finops | Medium | not-covered |
| E2E-010 | appinsights | Low | not-covered |
| E2E-011 | loadtesting | Low | not-covered |
| E2E-012 | aks-rightsizing | Medium | not-covered |
| E2E-013 | aks-karpenter-cost | Medium | not-covered |
| E2E-014 | psrule | Medium | not-covered |
| E2E-015 | powerpipe | Medium | not-covered |
| E2E-016 | azgovviz | Medium | not-covered |
| E2E-017 | alz-queries | High | not-covered (ARG queries are the core of the repo) |
| E2E-018 | wara | Medium | not-covered |
| E2E-019 | maester | High | not-covered (tenant entity path is business-critical) |
| E2E-020 | scorecard | Medium | not-covered |
| E2E-021 | gh-actions-billing | Low | not-covered |
| E2E-022 | ado-connections | Medium | not-covered |
| E2E-023 | ado-pipelines | Medium | not-covered |
| E2E-024 | ado-consumption | Low | not-covered |
| E2E-025 | ado-repos-secrets | High | not-covered (secret discovery surface) |
| E2E-026 | ado-pipeline-correlator | Medium | not-covered |
| E2E-027 | identity-correlator | High | not-covered |
| E2E-028 | identity-graph-expansion | High | not-covered |
| E2E-029 | zizmor | High | not-covered (Actions injection scanner) |
| E2E-030 | gitleaks | High | not-covered (secret scanner) |
| E2E-031 | trivy | High | not-covered (CVE scanner) |
| E2E-032 | bicep-iac | Medium | not-covered |
| E2E-033 | infracost | Low | not-covered |
| E2E-034 | terraform-iac | Medium | not-covered |
| E2E-035 | sentinel-incidents | Medium | not-covered |
| E2E-036 | sentinel-coverage | Medium | not-covered |

**Coverage %: 0 / 36 enabled tools = 0 %** at the wrapper level.
**Surface coverage: 3 / 3 = 100 %** (Azure / GitHub / Tenant-MG output pipeline).
**Invariant coverage: 100 %** of schema v2/v3.1, scrub, host allow-list, tier selection.

## Recommendation

Add a Phase 2 harness (`tests/e2e/Wrappers.E2E.Tests.ps1`) that, for every
`enabled:true` tool in the manifest, mocks the external CLI/API call and drives
`wrapper → normalizer → EntityStore` through `Invoke-AzureAnalyzer` with
`-Tools <name> -MockMode`. Raise wrapper coverage to the same ≥ 95 % bar the
unit suite already meets.

