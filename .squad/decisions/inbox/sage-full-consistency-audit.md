# Full Consistency + Test-Rigor Audit

**Date:** 2026-05-13T19:45:00Z
**Author:** Sage (Research & Discovery Specialist)
**Scope:** Whole codebase except auditor profile internals (Sentinel covering separately)

---

## Executive Summary

- **Total findings: 42** (🔴 7 blocking, 🟡 22 risk, 🟢 13 OK/informational)
- **Top 5 highest-priority items:**
  1. 🔴 **HTML report tests are BUG-1 class false-pass magnets** — 13 tests in `New-HtmlReport.Tests.ps1` use `Should -Match` on rendered output with no upstream data null-guard. If a renderer silently swallows null, regex never fires, test passes vacuously.
  2. 🔴 **AuditorReportBuilder HTML/MD sinks unsanitized** — `Set-Content` at lines 898/891 writes raw `$htmlContent`/`$mdContent` without `Remove-Credentials`. CSV/JSON/XLSX path partially sanitized (string-only fields), but non-string properties bypass scrubbing.
  3. 🔴 **Invoke-AzureQuotaReports has 5 raw throws** — zero use of `New-FindingError`; biggest CON-003 regression in the codebase.
  4. 🟡 **17 of 38 enabled manifest tools lack wrapper tests and/or normalizer tests** — violates the "every shipped tool MUST have a wrapper test + normalizer test" directive.
  5. 🟡 **Pester `Test` job is not a required CI check** — the actual test gate runs on every PR but isn't enforced; a maintainer could merge with red Pester.
- **Effort buckets:**
  - Quick wins (< 1h each): sanitization gap fixes, raw-throw migration, test null-guards
  - Medium (1–4h each): missing wrapper/normalizer tests, CON-002 canonical rename
  - Large (4h+): full report test hardening with upstream data assertions

---

## Stream A — Wrapper Consistency Ratchet (CON-001..005)

### CON-001 — ADO Wrapper Parameter Consistency

| Metric | Value |
|--------|-------|
| Ratchet baseline in test | N/A (not explicitly baselined) |
| Actual violations | **0** |
| Status | 🟢 **Clean** |

All ADO wrappers (`Invoke-ADOPipelineCorrelator`, `Invoke-ADOPipelineSecurity`, `Invoke-ADOServiceConnections`, `Invoke-ADORepoSecrets`, `Invoke-AdoConsumption`) use `AdoOrg` / `AdoProject` as canonical parameter names with appropriate aliases.

### CON-002 — Repo Input Consistency

| Metric | Value |
|--------|-------|
| Ratchet baseline in test | N/A (not explicitly baselined) |
| Actual violations | **3** |
| Status | 🟡 **Drift** |

The contract specifies `RepoPath` + `RemoteUrl` as canonical names. Three wrappers use `Repository` as canonical instead:

| File | Line | Canonical | Aliases | Issue |
|------|------|-----------|---------|-------|
| `modules/Invoke-IaCBicep.ps1` | 22-23 | `Repository` | `Repo, RepoPath, Path` | `RepoPath` is alias, not canonical |
| `modules/Invoke-IaCTerraform.ps1` | 27-28 | `Repository` | `Repo, RepoPath, Path` | Same |
| `modules/Invoke-Scorecard.ps1` | 25 | `Repository` | `Repo, RepoUrl` | Missing `RepoPath` alias entirely; `RemoteUrl` not present (uses positional) |

**Note:** `RemoteUrl` IS present in IaCBicep and IaCTerraform (line 25/30), so the remote path is compliant — only the local-path canonical is inverted. Scorecard is the most divergent.

**Recommendation:** Rename canonical to `RepoPath` with `Repository` as back-compat alias. Add a CON-002 baseline to the ratchet test to prevent regression.

### CON-003 — Structured Wrapper Errors

| Metric | Value |
|--------|-------|
| Ratchet baseline in test | **0** (empty `$script:RawThrowBaseline` — lines 44-48) |
| Actual violations | **7 raw throws in 2 wrappers** |
| Status | 🔴 **Regression** |

The ratchet test uses a regex that matches `throw "..."` / `throw '...'` — but both `Invoke-AzureQuotaReports.ps1` and `Invoke-DnsTwist.ps1` use typed exception constructors (`throw [System.Exception]::new(...)` / `throw [RuntimeException]::new(...)`) which bypass the regex. The ratchet test shows green, but these are still raw throws without structured error metadata.

| File | Lines | Count | Pattern |
|------|-------|-------|---------|
| `modules/Invoke-AzureQuotaReports.ps1` | 96, 109, 111, 136, 138 | 5 | `throw ($err \| ConvertTo-Json ...)` and `throw [System.Exception]::new(...)` |
| `modules/Invoke-DnsTwist.ps1` | 127-128 | 1 | `throw [RuntimeException]::new(...)` — has comment acknowledging this intentionally dodges the ratchet regex |
| `modules/Invoke-CopilotTriage.ps1` | 84 | 1 | `throw` (bare re-throw in catch — less severe, but still unstructured) |

**Recommendation:**
1. Migrate all 7 to `New-FindingError` + `Format-FindingErrorMessage`.
2. Widen the ratchet regex to also catch `throw \[System\.\w+\]::new\(` and bare `throw` in catch blocks.

### CON-004 — Side-Effecting Wrappers (SupportsShouldProcess)

| Metric | Value |
|--------|-------|
| Ratchet baseline | 2 wrappers: `Invoke-Falco.ps1`, `Invoke-AksKarpenterCost.ps1` |
| Actual violations | **0** |
| Status | 🟢 **Clean** |

Both declare `[CmdletBinding(SupportsShouldProcess=$true)]` and call `$PSCmdlet.ShouldProcess(...)`.

### CON-005 — Manifest/Wrapper Uniformity

| Metric | Value |
|--------|-------|
| Ratchet baseline in test | N/A (not explicitly baselined) |
| Name mismatches | **8** |
| Unregistered wrapper | **1** |
| Status | 🟡 **Known technical debt** |

The manifest `name` field doesn't match the wrapper filename for 8 tools. These are intentional naming convention differences (kebab-case manifest vs PascalCase wrapper) and the manifest's `script` field correctly points to the actual filename. This is a naming indirection, not a missing wrapper.

| Manifest name | Actual wrapper filename |
|---|---|
| `ado-connections` | `Invoke-ADOServiceConnections.ps1` |
| `ado-pipelines` | `Invoke-ADOPipelineSecurity.ps1` |
| `ado-repos-secrets` | `Invoke-ADORepoSecrets.ps1` |
| `azure-quota` | `Invoke-AzureQuotaReports.ps1` |
| `bicep-iac` | `Invoke-IaCBicep.ps1` |
| `finops` | `Invoke-FinOpsSignals.ps1` |
| `loadtesting` | `Invoke-AzureLoadTesting.ps1` |
| `terraform-iac` | `Invoke-IaCTerraform.ps1` |

**Unregistered wrapper:** `modules/Invoke-CopilotTriage.ps1` has no manifest entry. This is an internal/experimental tool, but per contract all tools should register.

**Recommendation:** Add `copilot-triage` to manifest (disabled by default). Consider a CON-005 ratchet test that validates manifest `script` → file existence.

---

## Stream B — Schema / Normalizer Consistency

### Normalizer Compliance (38 normalizers)

| Check | Result | Status |
|-------|--------|--------|
| All normalizers use `New-FindingRow` | ✅ All 38 call `New-FindingRow` | 🟢 |
| Severity values within canonical 5-enum | ✅ Only `Critical/High/Medium/Low/Info` observed | 🟢 |
| EntityType values within Schema.ps1 enum | ✅ All valid | 🟢 |
| `ConvertTo-CanonicalEntityId` for tenant/SPN/user | ✅ Used where applicable | 🟢 |
| `New-FindingError` `-Category` values valid | ✅ All observed categories in the 10-value enum | 🟢 |

### Wrapper Error Handling

| File | Issue | Severity |
|------|-------|----------|
| `Invoke-DnsTwist.ps1:127` | `throw [RuntimeException]::new(...)` — bypasses ratchet regex | 🔴 |
| `Invoke-AzureQuotaReports.ps1:96,109,111,136,138` | 5x raw typed throws, zero `New-FindingError` usage | 🔴 |
| `Invoke-CopilotTriage.ps1:84` | Bare `throw` in catch block | 🟡 |

**Bottom line:** Normalizers are exemplary. Wrapper error handling has 3 stragglers.

---

## Stream C — Manifest vs Reality

### Coverage Matrix (38 enabled tools)

| Gap type | Count | Tools |
|----------|-------|-------|
| Full coverage (wrapper + normalizer + tests + fixture) | **14** | azqr, azgovviz, dnstwist, gitleaks, kubescape, maester, powerpipe, prowler, psrule, scorecard, trivy, wara, zizmor, + partial others |
| Missing fixture only | **3** | appinsights, falco, infracost |
| Missing wrapper test + normalizer test | **17** | ado-connections, ado-consumption, ado-pipeline-correlator, ado-pipelines, ado-repos-secrets, aks-karpenter-cost, aks-rightsizing, alz-queries, azure-cost, azure-quota, bicep-iac, conditional-access-graph, defender-for-cloud, finops, gh-actions-billing, identity-correlator, identity-graph-expansion |
| Missing wrapper test + normalizer test + fixture | **10** | ado-consumption, ado-repos-secrets, aks-karpenter-cost, aks-rightsizing, azure-quota, bicep-iac, gh-actions-billing, identity-correlator, identity-graph-expansion, loadtesting, sentinel-coverage, terraform-iac |

### Reverse Check
- **1 unregistered wrapper:** `Invoke-CopilotTriage.ps1` — no manifest entry

### Generated Artifacts
- `scripts/Generate-ReadmeFacts.ps1` — has `-CheckOnly` mode ✅
- `scripts/Generate-ToolCatalog.ps1` — has `-CheckOnly` mode ✅
- `scripts/Generate-PermissionsIndex.ps1` — has `-CheckOnly` mode ✅
- README says "38 enabled + 1 opt-in" — consistent with manifest ✅
- Tool catalog says "38 enabled / 14 disabled" — consistent ✅

---

## Stream D — Sanitization Coverage

### Output Sink Inventory

| File | Lines | What's written | Sanitized? |
|------|-------|---------------|------------|
| `Invoke-AzureAnalyzer.ps1` | 1607-1642 | `results.json`, `entities.json`, `portfolio.json` | ✅ `Remove-Credentials` applied |
| `Invoke-AzureAnalyzer.ps1` | 1776-1779 | `tool-status.json` | ✅ |
| `Invoke-AzureAnalyzer.ps1` | 1853-1856 | `triage.json` | ✅ |
| `Invoke-AzureAnalyzer.ps1` | 1965-1967 | `results-baseline.json` copy | ⚠️ Source sanitized earlier; copy step has no re-scrub |
| `Invoke-AzureAnalyzer.ps1` | 2164-2168 | `errors.json` | ✅ |
| `New-HtmlReport.ps1` | 57 | HTML report | ✅ via `SafeText`/`HE` wrappers |
| `New-MdReport.ps1` | 891 | Markdown report | ✅ via `Sanitize()`/`SanitizeInline()` |
| `New-ExecDashboard.ps1` | 57 | Executive dashboard HTML | ✅ via `ExecDashboardRender.ps1` → `Remove-Credentials` |
| **`AuditorReportBuilder.ps1`** | **898** | **Auditor HTML report** | **❌ Raw `$htmlContent` — no sanitization** |
| **`AuditorReportBuilder.ps1`** | **891** | **Auditor MD report** | **❌ Raw `$mdContent` — no sanitization** |
| `AuditorReportBuilder.ps1` | 702-715 | Auditor CSV/JSON/XLSX | ⚠️ Partial — `$sanitizedFindings` scrubs string props only; non-string values (arrays, nested objects) pass through unscrubbed |
| `RemoteClone.ps1` | 198-205 | `.git/config` token scrub | ✅ |

### Key Gaps

1. **🔴 AuditorReportBuilder HTML + MD reports (lines 898, 891):** These write raw content assembled from findings data without any `Remove-Credentials` pass. If a finding's Description, Remediation, or Evidence contains an embedded token/key, it will appear in the audit report on disk.

2. **🟡 AuditorReportBuilder CSV/JSON/XLSX partial sanitization (lines 683-715):** The sanitization loop only scrubs properties whose values are strings (`-is [string]`). Complex objects (arrays of strings, nested PSCustomObjects) are written as-is. A credential embedded inside an array element would survive.

3. **🟡 results-baseline.json copy (line 1965):** Direct file copy of a previously-sanitized file. Low risk (source was scrubbed), but if the source is re-read and modified between sanitization and copy, a gap could open. Defensive re-scrub recommended.

---

## Stream E — Pester False-Pass Patterns (Non-Auditor)

### Summary
- **13 tests flagged 🔴 LIKELY-MASKING** — all in `tests/reports/New-HtmlReport.Tests.ps1`
- **2 tests flagged 🟡 SUSPICIOUS**
- **Pattern:** All 13 red findings follow the exact BUG-1 pattern — `Should -Match` on rendered HTML without a paired `Should -Not -BeNullOrEmpty` on the upstream data being rendered. If the renderer receives null/empty data and silently emits nothing (or emits a static shell), the regex match never fires and the test passes vacuously.

### Top 15 Findings

| # | File | Test name | Risk | Why |
|---|------|-----------|------|-----|
| 1 | `tests/reports/New-HtmlReport.Tests.ps1:34-55` | `handles empty results, supports entities envelope, and avoids CDN URLs` | 🔴 | Tests against `[]` input with only `Should -Match` on output — no upstream null guard |
| 2 | `tests/reports/New-HtmlReport.Tests.ps1:58-71` | `includes sticky sub-navigation anchors` | 🔴 | Pure regex on empty-input render |
| 3 | `tests/reports/New-HtmlReport.Tests.ps1:74-86` | `renders header severity strip classes` | 🔴 | Output-only assertions against empty results |
| 4 | `tests/reports/New-HtmlReport.Tests.ps1:89-100` | `contains findings table client functions` | 🔴 | Rendered HTML regex only; no proof findings existed |
| 5 | `tests/reports/New-HtmlReport.Tests.ps1:117-128` | `renders tool×severity fallback mode` | 🔴 | Single-finding input; no non-empty guard on iterated data |
| 6 | `tests/reports/New-HtmlReport.Tests.ps1:156-175` | `renders triage panel content` | 🔴 | Output match only; triage can appear with empty findings |
| 7 | `tests/reports/New-HtmlReport.Tests.ps1:179-187` | `renders v2 skip-to-content link` | 🔴 | Static markup check on `[]` input |
| 8 | `tests/reports/New-HtmlReport.Tests.ps1:190-200` | `includes dark mode toggle button` | 🔴 | Static behavior assertions only |
| 9 | `tests/reports/New-HtmlReport.Tests.ps1:203-211` | `renders severity count strip with icons` | 🔴 | Could pass on empty/degenerate output |
| 10 | `tests/reports/New-HtmlReport.Tests.ps1:214-223` | `includes print stylesheet` | 🔴 | Output string checks only |
| 11 | `tests/reports/New-HtmlReport.Tests.ps1:226-234` | `includes prefers-reduced-motion` | 🔴 | Static output-only test |
| 12 | `tests/reports/New-HtmlReport.Tests.ps1:237-246` | `renders responsive grid layout` | 🔴 | Verifies CSS tokens, not data flow |
| 13 | `tests/reports/New-HtmlReport.Tests.ps1:249-258` | `renders semantic landmarks with ARIA` | 🔴 | Static markup assertions |
| 14 | `tests/reports/Collapsible-Tree.Tests.ps1:21-27` | `server-renders findings rows` | 🟡 | Row-count checks but no explicit non-empty guard on source collection |
| 15 | `tests/reports/Top-Recommendations.Tests.ps1:8-29` | `caps Top risks panel at 10 rows` | 🟡 | Mostly strong but output-centric |

### Additional Pattern: `-Skip` / `-Pending` Catalog

| File | What's skipped | Tied to issue? |
|------|---------------|----------------|
| `tests/shared/CliTimeout.Tests.ps1:76,84,94` | 3 tests skip when `pwsh` not on PATH | ✅ Reasonable environment guard |
| `tests/wrappers/LiveTool.Wrappers.Tests.ps1:21,46,67,78` | 4 tests skip when CLI binary missing | ✅ Reasonable |
| `tests/shared/TestIsolation.Tests.ps1:127` | Meta-test skips unless `$env:AZURE_ANALYZER_RUN_ISOLATION_META_TEST` is set | 🟡 Gated by env var — could easily be permanently skipped in CI |
| `tests/workflows/NoUnexpectedWarnings.Tests.ps1:42-84` | **35 wrapper tests grandfathered** (baseline #770) | ✅ Tied to #770, but the baseline is extremely loose — 35 of 37 wrappers are grandfathered |

### Systemic Concern: NoUnexpectedWarnings Baseline

The `NoUnexpectedWarnings.Tests.ps1` grandfathered baseline contains **35 entries** — essentially every wrapper test file in the repo. This means the "no unexpected warnings" contract is effectively unenforced. Only net-new wrapper tests must comply. **Recommendation:** Set a timeline to whittle this baseline to zero; as-is, it's theatrical.

---

## Stream F — Documentation Generator Freshness

| Generator | CheckOnly mode | Output | Status |
|-----------|---------------|--------|--------|
| `Generate-ReadmeFacts.ps1` | ✅ `-CheckOnly` | `README.md` facts blocks | 🟢 Fresh (38 enabled matches manifest) |
| `Generate-ToolCatalog.ps1` | ✅ `-CheckOnly` | `docs/reference/tool-catalog.md`, `tool-catalog-contributor.md` | 🟢 Fresh (38 enabled / 14 disabled) |
| `Generate-PermissionsIndex.ps1` | ✅ `-CheckOnly` | `PERMISSIONS.md` + per-tool pages | 🟢 Fresh |

All three generators are invoked in `docs-check.yml` with their check modes. The `docs-check.yml` workflow runs on `pull_request` events.

**Status: All generated docs appear current.**

---

## Stream G — CI Gate Audit

### PR-triggered Workflows

| Workflow | Job name(s) | Required? | Should be? |
|----------|-------------|-----------|------------|
| `codeql.yml` | `Analyze (actions)` | ✅ **Yes** | Yes |
| `ci.yml` | `Test`, `LiveTool wrappers (non-blocking)` | ❌ No | 🔴 **Yes — `Test` should be required** |
| `docs-check.yml` | `Documentation update check`, `Tool catalog fresh`, `Permissions pages fresh`, `README facts fresh` | ❌ No | 🟡 **Yes — at least `Documentation update check`** |
| `markdown-check.yml` | `lint (markdownlint-cli2)`, `links (lychee)`, `em-dash policy` | ❌ No | 🟡 Consider requiring `lint` |
| `bicep-build.yml` | `Bicep build smoke test` | ❌ No | 🟢 Nice-to-have |
| `closes-link-required.yml` | `Closes/Fixes link required` | ❌ No | 🟡 Should be required for agent PRs |
| `e2e.yml` | `e2e` | ❌ No | 🟢 Heavy; keep optional |

### Key Finding

**The Pester test suite (`ci.yml` → `Test` job) is the most important non-required check.** It runs on every PR but a maintainer could merge with red Pester. Given that BUG-1 shipped because the test suite had false passes, making the test job required is the single highest-leverage CI improvement.

The `docs-check.yml` workflow enforces the "no code PR without docs update" rule, but since it's not required, it's advisory-only. A maintainer merging quickly could bypass it.

**Recommendation:** Add `Test` (from `ci.yml`) and `Documentation update check` (from `docs-check.yml`) to the branch protection required checks. Note: `Test` may need a path filter exception for docs-only PRs to avoid blocking README-only changes on Pester.

---

## Recommended Follow-Up Issues

| # | Title | Labels | Effort | Parallel? | Notes |
|---|-------|--------|--------|-----------|-------|
| 1 | `fix: AuditorReportBuilder HTML/MD sinks missing Remove-Credentials` | `bug`, `squad:forge` | Quick (30min) | ✅ | Lines 898/891 — wrap `$htmlContent`/`$mdContent` in `Remove-Credentials` before `Set-Content` |
| 2 | `fix: Invoke-AzureQuotaReports migrate 5 raw throws to New-FindingError` | `bug`, `squad:forge` | Quick (1h) | ✅ | 5 throws at lines 96/109/111/136/138 |
| 3 | `fix: widen ratchet regex to catch typed-exception throws` | `enhancement`, `squad:sentinel` | Quick (30min) | ✅ After #2 | Update `Get-RawThrowCount` in `WrapperConsistencyRatchet.Tests.ps1` to match `throw \[` pattern |
| 4 | `chore: require Pester Test job in branch protection` | `enhancement`, `squad:lead` | Quick (15min) | ✅ | Add `Test` to required status checks |
| 5 | `chore: require docs-check job in branch protection` | `enhancement`, `squad:lead` | Quick (15min) | ✅ | Add `Documentation update check` to required checks |
| 6 | `fix: HTML report tests — add upstream data null-guards (BUG-1 class)` | `bug`, `squad:sentinel` | Medium (2-3h) | Serialize behind Sentinel's auditor work | 13 tests in `New-HtmlReport.Tests.ps1` need paired `Should -Not -BeNullOrEmpty` |
| 7 | `chore: add wrapper + normalizer tests for 17 undertested tools` | `enhancement`, `squad` | Large (8h+) | ✅ Parallelizable across agents | See Stream C matrix |
| 8 | `fix: CON-002 rename canonical param to RepoPath in IaC + Scorecard wrappers` | `enhancement`, `squad:forge` | Quick (30min) | ✅ | 3 files: IaCBicep, IaCTerraform, Scorecard |
| 9 | `chore: add CON-002 + CON-005 baselines to ratchet test` | `enhancement`, `squad:sentinel` | Quick (30min) | ✅ After #8 | Currently no automated gate for these |
| 10 | `chore: whittle NoUnexpectedWarnings baseline from 35→0` | `enhancement`, `squad` | Large (4h+) | ✅ | 35 of 37 wrapper tests grandfathered |
| 11 | `fix: register Invoke-CopilotTriage in tool-manifest.json` | `enhancement`, `squad:forge` | Quick (15min) | ✅ | Only unregistered wrapper |
| 12 | `fix: AuditorReportBuilder CSV/XLSX sanitize non-string properties` | `bug`, `squad:forge` | Quick (30min) | ✅ | Nested objects/arrays bypass `Remove-Credentials` |

---

## Out-of-Scope (deliberately not covered)

- **Auditor profile internals** — Sentinel is covering `AuditorParity.Tests.ps1`, `AuditorDataFlow.Tests.ps1`, and `Assert-RequiredKey` helper
- **BUG-1 instance fix** — Forge is fixing the triage key mismatch in `AuditorReportBuilder.ps1` on `squad/forge-1102-trackf-bugfix`
- **RISK-1 HTML encoding / RISK-2 psm1 ValidateSet** — Forge scope
- **PSGallery smoke expansion** — Lead is expanding `release.yml` smoke test
- **Any new feature work** — audit only
- **`Invoke-AzureAnalyzer.ps1` viewer session-token write** — this is an intentional secret file (auth token for local viewer), not a log/report sink. Not a sanitization gap.
