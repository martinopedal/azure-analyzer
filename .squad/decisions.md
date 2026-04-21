# Squad Decisions

> Entries older than 30 days archived to `decisions-archive.md` (2026-04-21).

## Active Decisions

### Canonical Entity IDsin Test Fixtures (2026-04-18)
- **Decision:** Wrapper and normalizer fixtures must use canonical entity ID shapes expected by `ConvertTo-CanonicalEntityId` (`Subscription` as bare GUID, `Repository` as `host/owner/repo`).
- **Rationale:** Strict `New-FindingRow` validation now enforces canonical IDs, and non-canonical fixture data causes false-negative unit test failures unrelated to wrapper behavior.
- **Implementation:** Updated fixtures/tests for azure-cost, defender-for-cloud, gitleaks, scorecard, trivy, plus subscription-ID handling in Azure Cost/Defender normalizers.
- **Status:** Active

### CI Failure Watchdog Automation (2026-04-17)
- **Decision:** Implement CI failure triage as a dedicated `workflow_run` watchdog plus an opt-in local PowerShell watcher that share the same dedup contract using hash: first 12 chars of `sha256("{workflow}|{first-error-line}")`.
- **Rationale:** Converts failed runs into actionable backlog items. Prevents issue spam by grouping repeats by deterministic workflow+error signature. Keeps behavior consistent between GitHub-hosted and local polling loops.
- **Security:** Self-trigger loops blocked with workflow-name exclusion. Error lines sanitized before issue generation. Workflow payload values passed through environment variables.
- **Implementation:** `.github/workflows/ci-failure-watchdog.yml`, `tools/Watch-GithubActions.ps1`, tests, docs updated.
- **Status:** Active

### Issue #127 Fix: CI Failure Watchdog Event Registration (2026-04-17)
- **Decision:** Fixed `.github/workflows/ci-failure-watchdog.yml` by adding missing `workflows:` key to `workflow_run` trigger.
- **Root Cause:** `workflow_run` event payload does not include `head_branch`; referencing it in job condition caused parse-time workflow failure preventing job initialization.
- **Chosen Fix:** Minimal and safe — applied job condition `if: github.event.workflow_run.conclusion == 'failure' && github.event.workflow_run.name != 'CI failure watchdog'` with proper trigger registration.
- **Validation:** 2 post-merge live runs returned `conclusion=success` with `event=workflow_run`.
- **PR:** #154 (SHA 0f287ad)
- **Status:** Active

### Error Sanitization Boundary (2026-04-18)
- **Decision:** Sanitize at error-capture time (in `catch` blocks), not write-time. Every exception message assigned to a `Message` property must wrap with `Remove-Credentials`.
- **Rationale:** Single boundary enforcement prevents bypasses. If we sanitized only at write-time, future developers might write new output paths and forget. Keeps error messages in result objects always safe.
- **Pattern:** `$result.Message = "Context: $(Remove-Credentials $_.Exception.Message)"`
- **Enforcement:** Grep audit for `Exception.Message|Error.Message|.Message`, Pester tests (6 scenarios: SAS URI, bearer token, connection string, GitHub PAT, null, multi-secret), CI gate (398/398 tests).
- **Status:** Active

### PR #116 Re-Gate Extension (2026-04-18)
- **Decision:** Apply Falco-established dot-source pattern to all missing runspace boundaries. Dot-source `shared/Sanitize.ps1` in parallel-runspace callsites. Add dot-source + fallback stub inside `Invoke-AzureAnalyzer.ps1` before invoking wrappers.
- **Rationale:** PowerShell 7 `ForEach-Object -Parallel` creates isolated runspaces where parent-scope functions are not inherited. Guarantees `Remove-Credentials` exists at runtime in each worker runspace.
- **Validation:** `Invoke-Pester -Path .\tests -CI` → 398 passed, 0 failed.
- **Status:** Active

### PR #120 Revision for Issue #126 Gate (2026-04-17)
- **Decision:** Applied five corrections to wrapper error paths: (1) parser safety via `"${testNumber}: $testDesc"` string formatting; (2) test hard-fail with `$ErrorActionPreference = 'Stop'`; (3) retry API alignment with `-MaxAttempts` canonical (backward-compat `-MaxRetries` mapped); (4) sanitization invariant on all 17 wrappers; (5) `PartialSuccess` semantics for multi-target scans with mixed success/failure.
- **Rationale:** Prevents parse regressions, improves test signal, reduces secret leakage, preserves findings during partial outages.
- **Status:** Active

### PR Review Gate Model Selection (2026-04-17)
- **Decision:** For PR review-gate triage, use three diverse models: `claude-opus-4.6`, `gpt-5.3-codex`, `goldeneye`. All 3 must approve before merge.
- **Rationale:** Single-model review under-captures edge cases. Trio gives overlap on core correctness while preserving disagreement signal. Avoids homogeneous failure modes.
- **Operating Rule:** Ingest PR reviews, generate model-specific prompt bundle, merge three responses into deterministic consensus. Read + comment + plan-write only (no auto-approve/dismiss).
- **Status:** Active

### Issue-First Workflow Directive (2026-04-18)
- **Decision:** Do not ship ad-hoc PRs; always work on issues first. When an issue is fully planned (acceptance criteria, design, scope confirmed), then create code and implement the issue plan. PRs reference and implement issue plans, never the other way around.
- **Rationale:** Consistency across the squad. The issue is the contract; the PR is the implementation. Forces planning before code.
- **Status:** Active

### Rubberduck-Gate in Required Checks (2026-04-21)
- **Decision:** Branch protection enforces BOTH `Analyze (actions)` AND `rubberduck-gate` (strict=true), not just `Analyze (actions)`.
- **Impact:** With strict=true, each PR merge invalidates downstream PRs in a batch. Requires `gh pr update-branch` + ~90s CI wait per subsequent merge.
- **Operational Guidance:** Run Dependabot batches sequentially, not in parallel. Update coordinator runbook to reflect dual-gate requirement.
- **Discovery:** Found during Dependabot batch #288-#292 processing (2026-04-21).
- **Status:** Active

### Upload-Artifact v7 Matrix Safety Pattern (2026-04-21)
- **Decision:** `actions/upload-artifact@v7` is safe in this repo because (a) zero `download-artifact` consumers, (b) both upload sites use unique artifact names (sbom-{sha}, scheduled-scan-{run_id}).
- **Future Watchpoint:** Any new matrix consumer of `actions/upload-artifact@v7` MUST suffix artifact name with matrix variable (v5+ no longer merges same-named artifacts across matrix legs).
- **Pattern Example:** `name: sbom-${{ matrix.os }}-${{ github.sha }}` instead of `name: sbom`
- **Status:** Documented

### GitHub-Script v9 Compatibility Pattern (2026-04-21)
- **Decision:** `actions/github-script@v9` removed `require('@actions/github')`. The `getOctokit` function is now injected as a parameter, not defined via `const` or `let`.
- **Incompatible Pattern:** `const getOctokit = require('@actions/github').getOctokit;` or redeclaring with `const getOctokit = ...`
- **Compatible Pattern:** Use the injected `getOctokit` directly: `const octokit = getOctokit();`
- **Audit Result:** Zero instances of incompatible patterns found in 9 inline-script consumers. Safe to deploy.
- **Status:** Documented

### Dependabot Stale Version Comment Quirk (2026-04-21)
- **Decision:** Dependabot sometimes bumps the action SHA to a newer version but leaves the version comment tag at the previous release.
- **Example:** PR #290 bumped codeql-action to SHA matching v4.35.2 but left comment as `v4.35.1`. PR #291 bumped action-gh-release to v3.0.0 SHA but left comment as `v2.2.0`.
- **Mitigation:** Always `git diff` before merging Dependabot PRs. Fix stale comments with a follow-up commit on the Dependabot branch (before merge) to maintain SHA-pin policy accuracy.
- **Status:** Documented

---

## 2026-04-22 — Report UX Redesign + Schema 2.2

Six-agent research arc covering 13 tools. Briefs delivered by Iris (Maester, Kubescape), Atlas (AzGovViz), Sage (azqr, PSRule, Defender, Prowler, Powerpipe), Forge (Trivy, Infracost, Scorecard), Lead (WARA, Sentinel). Sentinel synthesised, shipped locked mockup + Schema 2.2 contract + 15 issues (#299–#313).

### Report Architecture: Single-Scroll with Sticky Anchors (2026-04-22)
- **Decision:** Unified HTML report uses a single-page scroll with sticky in-page anchor pills (`#overview`, `#coverage`, `#heatmap`, `#risks`, `#findings`, `#entities`). No JS TabStrip.
- **Rationale:** AzGovViz's `display:none` tabs break Ctrl+F, hide findings behind a click (wrong CISO default), and add JS state management. Sticky anchors give equivalent density. Browser back-button, URL fragments, and print-to-PDF all work natively. Atlas and Sentinel independently converged on this.
- **Locked in:** `samples/sample-report.html` (58 KB design spec).
- **Status:** Active

### Schema 2.2 Additive Bump (2026-04-22)
- **Decision:** Add 13 optional parameters to `New-FindingRow` in `modules/shared/Schema.ps1`. Bump `$script:SchemaVersion = '2.2'`. All backward-compatible (empty defaults, existing tests green).
- **New fields:** `Frameworks [hashtable[]]`, `Pillar [string]`, `Impact [string]`, `Effort [string]`, `DeepLinkUrl [string]`, `RemediationSnippets [hashtable[]]`, `EvidenceUris [string[]]`, `BaselineTags [string[]]`, `ScoreDelta [double]`, `MitreTactics [string[]]`, `MitreTechniques [string[]]`, `EntityRefs [string[]]`, `ToolVersion [string]`.
- **EntityStore:** Envelope v3.1 → v3.2 with additive `RunContexts: object[]` sidecar. New helpers: `Merge-FrameworksUnion`, `Merge-BaselineTagsUnion`.
- **Umbrella issue:** #299
- **Status:** Active

### Framework Badge Palette (2026-04-22)
- **Decision:** Unified `<framework-chip>` component across all tools. Colors are framework-keyed (not tool-keyed): CIS is always amber regardless of source scanner.
- **Palette (WCAG-AA on white):** CIS `#D97706`, NIST `#374151`, MITRE `#B91C1C`, EIDSCA `#1F6FEB`, eIDAS2 `#7C3AED`, SOC/ISO `#0F766E`, CISA `#0F766E`, MCSB `#005A9E`, CAF `#1E3A8A`, WAF `#3A7D0A`, ORCA `#0891B2`.
- **Status:** Active

### Severity + Status Color Tokens (2026-04-22)
- **Decision:** Unified severity palette: Critical `#B00020`, High `#D93B00`, Medium `#B26A00`, Low `#0B6FA8`, Info `#5C6770`. Status: Pass `#1E8E3E`, Fail `#C5221F`, Investigate `#B26A00`, Skipped `#5C6770`, Error `#7B1FA2`. All WCAG-AA at 14px on white.
- **Status:** Active

### Heat-Map Default: Control-Domain × Subscription (2026-04-22)
- **Decision:** Default heatmap axis is Control-Domain (WAF Pillar) × Subscription. Two alternate toggles: Severity × ResourceGroup (operational), Framework × Subscription (compliance).
- **Rationale:** Execs under-served today; this answers "where are my CAF/WAF coverage gaps across the estate?" Endorsed by Sage, Atlas, Defender Compliance Manager pattern.
- **Cell encoding:** Defender-style split-bar (green/red/grey) preferred; v1 fallback is sequential single-hue ramp on `% compliant`.
- **Status:** Active

### Bugs Uncovered in ETL Review (2026-04-22)
- **PSRule severity hardcode** — `Invoke-PSRule.ps1` sets `Severity = 'Medium'` for every finding. Fix: map `Error→High`, `Warning→Medium`, `Information→Info`. Issue #301.
- **Scorecard severity inversion** — Score `-1` (errored) → `High` (should be `Info`); score `0` (true failure) → `High` (should be `Critical`). Issue #313.
- **WARA ImpactedResources truncation** — Only `[0]` taken; N-1 resources lost. Breaks effort axis. Issue #308.
- **WARA Remediation/LearnMoreUrl aliasing** — Both set to same URL; remediation text lost. Issue #308.
- **Defender missing regulatoryCompliance API** — No CIS/NIST/PCI/ISO framework tags collected. Issue #302.
- **azqr field-projection gap** — Raw JSON dump; no `RecommendationId`, `Impact`, or Pillar extracted. Issue #300.
- **Status:** Tracked — each assigned to its per-tool issue

### Per-Tool ETL Gap Summary (2026-04-22)

Condensed from 6 deep-dive briefs. Each tool's critical dropped fields and the target schema slot.

#### Maester (Issue #305)
| Dropped field | Target slot |
|---|---|
| `Tags` (Block.Tag + Test.Tag — EIDSCA/CIS/MITRE/eIDAS2/NIST) | `Frameworks[]` (first-class) |
| `TestId` (e.g. `EIDSCA.AF01`) | `RuleId` (first-class) |
| `TestDescription` (markdown) | `Properties.Description` (container) |
| `TestRemediation` (markdown with portal links) | `Remediation` (first-class — stop blanking it) |
| `HelpUrl` (parsed from `See https://...`) | `LearnMoreUrl` (first-class — stop blanking it) |
| `Result = Investigate / Error` (squashed to Compliant=true) | `Properties.ResultState` + `MissingDimensions[]` |
| `Duration`, `ScriptBlock`, `MgContext`, module version | `Properties` bag + `RunContexts` sidecar |

#### Kubescape (Issue #306)
| Dropped field | Target slot |
|---|---|
| Framework membership (`control.frameworks[]`) | `Frameworks[]` (first-class) |
| `control.description` / `control.remediation` (real text) | `Detail` / `Remediation` (stop fabricating) |
| `scoreFactor` (1–10 numeric) | `Properties.ScoreFactor` (container) |
| `failedPaths` / `fixPaths` (JSONPath + YAML remediation) | `Properties.FailedPaths` / `Properties.FixPaths` |
| Per-resource granularity (`results[].controls[].rules[]`) | One FindingRow per (controlID, resourceID) |
| Posture Score (0–100) + per-framework scores | `RunContexts` sidecar |
| Status counters (passed/failed/skipped/excluded/irrelevant) | `RunContexts` sidecar |

#### AzGovViz (Issue #307)
| Dropped field | Target slot |
|---|---|
| `*_HierarchyMap.json` (MG tree) | `ManagementGroup` entities + parent links |
| AzAdvertizer URLs (per-definition evidence links) | `LearnMoreUrl` or `Properties` |
| `PrincipalDisplayName` / `PrincipalUPN` | Dedicated extras on FindingRow |
| PIM eligibility flag | Dedicated extra |
| `*_ALZPolicyVersionChecker.csv` | New `ALZ-Policy` category findings |
| `*_OrphanedResources.csv` | New `CostOptimization` category findings |

#### azqr (Issue #300)
| Dropped field | Target slot |
|---|---|
| `RecommendationId` (stable GUID) | `RuleId` (first-class) |
| `Impact` (H/M/L, separate from Severity) | `Impact` (new Schema 2.2) |
| WAF Pillar mapping | `Pillar` (new Schema 2.2) |
| Azure-portal deep link | `DeepLinkUrl` (new Schema 2.2) |
| `Remediation` overloaded with URL | Fix: separate Remediation from LearnMoreUrl |

#### PSRule (Issue #301)
| Dropped field | Target slot |
|---|---|
| Rule severity/level (Error/Warning/Information) | `Severity` (fix the hardcode bug!) |
| WAF Pillar tag (`Azure.WAF/pillar=Security`) | `Pillar` (new Schema 2.2) |
| CIS/NIST/PCI/ISO annotation keys | `Frameworks[]` (new Schema 2.2) |
| Baseline tags (release: GA/preview/deprecated) | `BaselineTags[]` (new Schema 2.2) |
| Remediation snippets (Bicep examples) | `RemediationSnippets[]` (new Schema 2.2) |

#### Defender for Cloud (Issue #302)
| Dropped field | Target slot |
|---|---|
| Regulatory compliance tags (PCI/ISO/SOC/CIS/NIST) | `Frameworks[]` — requires new API call |
| MCSB control IDs | `Frameworks[{kind:'MCSB'}]` |
| Azure-portal deep link to assessment blade | `DeepLinkUrl` (new Schema 2.2) |
| `additionalData` evidence blob | `EvidenceUris` or `Properties.EvidenceData` |
| Secure Score delta vs previous run | `ScoreDelta` (new Schema 2.2) |

#### WARA (Issue #308)
| Dropped field | Target slot |
|---|---|
| `ImpactedResources[]` full array | Emit one finding per resource |
| `Potential Benefit` | `Properties.RemediationBenefit` |
| `Pillar` / `Recommendation Control` | `Pillar` (new Schema 2.2) |
| `Service` (short name) | `Properties.ServiceShortName` |
| Remediation text (distinct from URL) | `Remediation` (stop aliasing) |

#### Sentinel Incidents (Issue #309)
| Dropped field | Target slot |
|---|---|
| `Tactics[]` / `Techniques[]` (MITRE) | `MitreTactics` / `MitreTechniques` (new Schema 2.2) |
| `AlertIds[]` (full array) | `EntityRefs` or dedicated field |
| `RelatedAnalyticRuleIds` | Cross-link to coverage findings |
| `Labels[]`, `Comments[]` | `Labels` or `Properties` |
| `FirstActivityTime` / `LastActivityTime` | Dedicated extras |
| Entity refs (from SecurityAlert join) | `EntityRefs` (new Schema 2.2) |

#### Sentinel Coverage (Issue #310)
| Dropped field | Target slot |
|---|---|
| Analytic rule MITRE tactics/techniques | `MitreTactics` / `MitreTechniques` |
| Connector health / last heartbeat | Finding `Detail` |

#### Trivy (Issue #311)
| Dropped field | Target slot |
|---|---|
| CVSS V3Score / V3Vector | `Properties.CvssScore` / `Properties.CvssVector` |
| CweIDs[] | `Tags` (with `cwe-` prefix) |
| References[] (full list) | `EvidenceUris` |
| Result.Type (npm/go/os-pkgs) + Class | `Tags` (ecosystem/class) |
| Misconfigurations + Secrets scan types | Enable `--scanners vuln,misconfig,secret` |

#### Infracost (Issue #312)
| Dropped field | Target slot |
|---|---|
| `diff` mode (cost delta vs baseline) | New `CompareTo` wrapper param |
| `costComponents[]` breakdown | `Properties.CostComponents` |
| Project-level rollup totals | `ToolSummary` envelope |
| `MonthlyCost` / `Currency` (via Add-Member) | `Properties` bag (typed) |

#### Scorecard (Issue #313)
| Dropped field | Target slot |
|---|---|
| Aggregate `score` (0–10 hero KPI) | `ToolSummary` envelope |
| `check.details[]` (file:line evidence) | `EvidenceUris` or `Properties.Evidence` |
| `documentation.short` (check description) | `Properties.Description` |
| `scorecard.version` + `repo.commit` | `ProvenanceSource` / `ToolVersion` |
| `-1` severity inversion bug | Fix: errored → Info, 0 → Critical |

### PR Sequencing (2026-04-22)
- **Step 1:** Schema 2.2 + EntityStore merge helpers (#299) — no wrapper changes
- **Steps 2–14:** Per-tool wrapper+normalizer updates (#300–#313) — parallelizable
- **Step 15:** Report consumes Schema 2.2 fields (#295/#296) — does NOT block on steps 2–14
- **Step 16:** Remove Add-Member orphan props (cleanup)
- **Status:** Planned

### Renderer Graceful-Degradation Contract (2026-04-22)
- **Decision:** Report renderer must render new fields when present and non-empty; omit entirely when absent. Never parse a field out of another field's string blob. Never fabricate placeholders. Mockup placeholders are pedagogical, not contractual.
- **Status:** Active

---

## 2026-04-22 — ALZ Queries SoT Migration + Manifest Upstream Audit

Two-agent arc: Atlas (source-of-truth audit + issue filing), Sage (manifest-wide upstream-pointer sweep).

### ALZ Queries Upstream Realignment — Path A Adopted

- **Decision:** `martinopedal/alz-graph-queries` is the canonical upstream for `queries/alz_additional_queries.json`. The current manifest pin (`Azure/Azure-Landing-Zones-Library`) is wrong — that repo ships Bicep/policy, not ARG queries.
- **Rationale:** Wrapper docstring (`Invoke-AlzQueries.ps1:59`) and `.copilot/copilot-instructions.md` already treat `alz-graph-queries` as canonical. Only `tools/tool-manifest.json:638` disagrees. Path A (flip the pointer) is the smallest change to match reality. Paths B (MS Library canonical) and D (merge repos) were evaluated and rejected.
- **Migration plan (6 issues filed):**
  - **#314** — `fix:` flip `upstream.repo` to `martinopedal/alz-graph-queries`
  - **#315** — `feat:` add `scripts/Sync-AlzQueries.ps1` (manifest-driven query sync + install block)
  - **#316** — `feat:` CI drift detection via `alz-queries-sync.yml` + `alz-queries-fresh` docs-check job
  - **#317** — `chore:` reorganize `queries/` into `alz/`, `finops/` subfolders
  - **#318** — `bug:` 7 orphan `queries/*.json` files (appinsights-*, aks-rightsizing-*) never read by wrappers
  - **#319** — `docs:` clarify upstream contract in README + wrapper docstring
- **Dependency chain:** #314 → #315 → #316; #319 depends on #314; #317 and #318 are independent.
- **Status:** Active — issues filed, PRs not yet started

### Manifest Upstream-Pointer Audit — Clean (30/33)

- **Decision:** No other tools in `tools/tool-manifest.json` have ALZ-class wrong-upstream bugs.
- **Audit scope:** All 33 tools; 15 have `upstream` blocks, 18 are Az-module-only or REST-only.
- **Results:** 1 🔴 (`alz-queries` — already tracked above), 2 🟡 (minor), 30 🟢.
- **🟡 alz-queries install block:** manifest declares `psmodule` for `Az.ResourceGraph` only but wrapper also needs the query JSON on disk. Folded into #315 (sync script adds the missing artifact fetch).
- **🟡 falco docs gap:** `-InstallFalco` mode shells out to `helm` + `kubectl`, neither declared in manifest install block. Low priority — docs hygiene only, not a wrong pointer.
- **Notable verifications:** WARA upstream (`Azure/Azure-Proactive-Resiliency-Library-v2`) confirmed correct. AzGovViz upstream rename (`…-Generator` → `…-Reporting`) already reflected. Scorecard, zizmor, gitleaks, trivy all clean.
- **Status:** Documented — no new issues needed beyond the alz-queries chain

---

## 2026-04-22 — azure-quota-reports Wrap Verdict + falco Docs Issue

Two-agent arc: Atlas (azure-quota-reports research + 🟢 verdict), Sage (falco install-mode docs gap follow-up from upstream-audit).

### Azure-Quota-Reports: 🟢 Implement as Wrapper

**Decision:** Wrap `martinopedal/azure-quota-reports` into azure-analyzer as a new tool.

**Rationale:**
- **Zero overlap** with 30 existing tools (`grep quota tools/tool-manifest.json` returns nothing).
- **Closest neighbor** is WARA (emits reliability advice); azure-quota-reports enumerates `% quota used` per `(sub, region, sku)` — complementary, not duplicative.
- **Pattern match:** Mirrors subscription-fanout + Reader-only model of `azure-cost`, `finops`, `defender-for-cloud`.
- **Schema fit:** Maps cleanly to Schema 2.2 with no new fields needed.

**Schema Mapping:**
- **Compliant formula:** `compliant = (UsagePercent < 80%)`
- **EntityType:** `Subscription` (canonical bare GUID)
- **Pillar:** `Reliability` (Schema 2.2)
- **Category:** `Capacity` (new, semantically distinct from `CostOptimization`)
- **Severity ladder:** Critical (≥99%), High (≥95%), Medium (≥80%), Info (below)
- **RuleId:** `azure-quota:{Provider}:{QuotaId}:{Location}`
- **Properties preserved:** `CurrentUsage`, `Limit`, `Unit`, `UsagePercent`, `QuotaId`, `QuotaName`, `Provider`, `Location`, `Source`
- **Tags:** `['capacity', 'quota', $Provider]`
- **Status:** `Pass` (compliant), `Fail` (over threshold), `Error` (from _errors.csv rows)

**Issues Filed (5-issue chain):**
| Issue | Type | Description | Depends |
|-------|------|-------------|---------|
| #321  | feat | Register `azure-quota` in `tool-manifest.json` | — |
| #322  | feat | Add `modules/Invoke-AzureQuotaReports.ps1` wrapper | #321 |
| #323  | feat | Add `modules/normalizers/Normalize-AzureQuotaReports.ps1` | #322 |
| #324  | feat | Tests (wrapper + normalizer + fixture covering all 4 severity bands) | #323 |
| #325  | docs | Add permissions page + CHANGELOG + tool catalog | #324 |

**Design Notes:**
- Region fanout scales O(subs × ~60 regions × 2 providers). Mitigate with parallel runspaces (`-ThrottleLimit 8`) + `Invoke-WithRetry` for 429s.
- Out of scope: Reservations / Capacity Reservations (distinct `Microsoft.Capacity` API), `Microsoft.Quota` RP migration (tracked as lower-priority follow-up).

**Status:** Active — issues filed, PRs pending squad dispatch.

### Falco Install-Mode Docs Gap (Issue #320)

**Finding:** Falco manifest install block does not declare dependencies on `helm` + `kubectl` for `-InstallFalco` mode.

**Context:** Upstream-audit sweep found this as a secondary documentation gap (not a wrong upstream pointer like `alz-queries`). Low impact — both tools are commonly pre-installed — but manifests should be machine-readable.

**Issue #320:** `chore: clarify falco manifest install block — query-mode vs install-mode prerequisites`
- **Labels:** `squad`, `documentation`
- **Remediation:** Add `helm` and `kubectl` to the install block prerequisites list with optional/conditional markers if they're only needed for `-InstallFalco`.

**Status:** Active — issue filed.

---

## Governance

- All meaningful changes require team consensus
- Document architectural decisions here
- Keep history focused on work, decisions focused on direction


# Atlas - Orphan query triage (#318 -> PR #327)

**Date:** 2026-04-22
**PR:** https://github.com/martinopedal/azure-analyzer/pull/327
**Merge SHA:** 9c6ab7d7c1f0aff798a6767eb6ae8ee29d29ee2d
**Issue:** https://github.com/martinopedal/azure-analyzer/issues/318

## Verdict: all 7 -> (c) move to `queries/library/` + README

The orphans identified in the prior ALZ-queries source-of-truth audit were re-confirmed by listing `queries/*.json` and `rg`-grepping every filename across `modules/`, `tests/`, `scripts/`. Zero hits per file -> true orphans.

| File | Fate | Mirrors inline KQL in |
| --- | --- | --- |
| `appinsights-slow-requests.json` | (c) library | `Invoke-AppInsights.ps1` `$slowRequestQuery` |
| `appinsights-dependency-failures.json` | (c) library | `Invoke-AppInsights.ps1` `$dependencyFailureQuery` |
| `appinsights-exception-rate.json` | (c) library | `Invoke-AppInsights.ps1` `$exceptionRateQuery` |
| `aks-rightsizing-missing-hpa.json` | (c) library | `Invoke-AksRightsizing.ps1` `$querySet` |
| `aks-rightsizing-oomkilled.json` | (c) library | `Invoke-AksRightsizing.ps1` `$querySet` |
| `aks-rightsizing-over-provisioned.json` | (c) library | `Invoke-AksRightsizing.ps1` `$querySet` |
| `aks-rightsizing-under-provisioned.json` | (c) library | `Invoke-AksRightsizing.ps1` `$querySet` |

## Why uniform (c), not (a) delete or (b) wire up

- **(a) delete rejected:** Each file is a hand-curated catalog that aligns 1:1 with shipped detections. Files have operator-facing reference value (copy-paste into Log Analytics blade) and are an obvious extraction target if a future refactor moves inline KQL to JSON. Deletion is permanent loss of curation that nothing else captures.
- **(b) wire up rejected:** Both wrappers already ship complete, working inline KQL. Refactoring to JSON-loaded queries is a non-trivial change with its own normalizer/test surface and regression risk. Out of scope for an orphan-triage bug.
- **(c) library accepted:** `queries/library/` + a README codifies the convention so the next orphan-query audit will not re-flag these. README enumerates current contents, which wrapper each file mirrors, and the rules for adding new entries (sync with wrapper inline KQL, schema, do-not-put-loaded-files-here).

## Codified convention (new)

`queries/` is now split into two zones:

- `queries/*.json` (top level) -> **read by a wrapper**. The orchestrator depends on these.
- `queries/library/*.json` -> **reference catalogs**. Not loaded by any wrapper. Mirror inline KQL elsewhere in the repo.

The `queries/library/README.md` documents this and lists which wrapper each file mirrors. Future orphan audits should treat anything at the top of `queries/` not referenced by a wrapper as a candidate for either wiring up or moving to `library/`. Default to wiring up if data is valuable; default to moving to `library/` if the wrapper already has the same KQL inline.

## Verification

- `Invoke-Pester -Path .\tests -CI` -> **1349 passed / 0 failed / 5 skipped** (baseline preserved).
- All required CI checks green; `Analyze (actions)` green; `mergeStateStatus=CLEAN`.
- Em-dash gate clean.
- No Copilot review comments after ~3 min wait window. Squash-merged with `--delete-branch`.

## Follow-up (proposed, not filed)

A separate refactor could promote `queries/library/` to actual loaded queries by extracting inline KQL from `Invoke-AppInsights.ps1` and `Invoke-AksRightsizing.ps1`. That is a deliberate design choice (single source of truth in JSON), not an orphan-triage decision. File only if there is concrete value (e.g. user-customizable KQL thresholds without code edits).

## Learnings worth pulling into core context

- `git mv` of a true orphan produces zero Pester failures. Useful as a fast confirmation step for orphan audits: move to a sibling folder, run tests, watch for surprises.
- `gh pr merge --squash` invoked from inside a worktree fails with `'main' is already used by worktree at <root>`. Run merge from the repo root, from any path outside the worktree, or pass `--repo`. Mirrors the existing worktree-cleanup-from-root rule.
- CHANGELOG.md currently has two `Unreleased` headings; `[1.2.0 - Unreleased]` is the active band. Add new entries there, not in the older `[Unreleased]` legacy band below it.
- Em-dash gate (`rg -- "—"`) recursively scans new subdirectories too. New `README.md` files inside fresh folders need scrubbing before commit.

# Atlas — Schema 2.2 additive bump locked (#299 → PR #343)

**Date:** 2026-04-22
**PR:** #343 (squash-merged at `97b8277`)
**Closes:** #299
**Unblocks:** #300, #301, #302, #303, #304, #305, #306, #307, #308, #309, #310, #311, #312, #313 (14 per-tool ETL closures)

## Locked parameter names (additive on `New-FindingRow`)

| Param | Type | Default |
|---|---|---|
| `Frameworks` | `[hashtable[]]` | `@()` |
| `Pillar` | `[string]` | `''` |
| `Impact` | `[string]` | `''` |
| `Effort` | `[string]` | `''` |
| `DeepLinkUrl` | `[string]` | `''` |
| `RemediationSnippets` | `[hashtable[]]` | `@()` |
| `EvidenceUris` | `[string[]]` | `@()` |
| `BaselineTags` | `[string[]]` | `@()` |
| `ScoreDelta` | `[Nullable[double]]` | `$null` |
| `MitreTactics` | `[string[]]` | `@()` |
| `MitreTechniques` | `[string[]]` | `@()` |
| `EntityRefs` | `[string[]]` | `@()` |
| `ToolVersion` | `[string]` | `''` |

`$script:SchemaVersion` bumped `'2.1'` → `'2.2'`. `EntitiesFileSchemaVersion` stays at `'3.1'` (envelope unchanged this PR).

## EntityStore helpers (adjacent to `Merge-UniqueByKey`)

- **`Merge-FrameworksUnion`** — dedupes by `(kind, controlId)` tuple, first-occurrence wins, case-sensitive on both keys, accepts hashtable + PSCustomObject inputs. Skips entries missing either key.
- **`Merge-BaselineTagsUnion`** — case-sensitive ordinal string dedupe, preserves order; whitespace and `$null` entries skipped.

## Implementation notes for downstream issue authors (#300-#313)

1. **`Frameworks` shape:** hashtable with at minimum `kind` + `controlId`. Optional `version` and other keys are preserved but ignored by the dedupe key. Wrapper authors writing `Maester` / `PSRule` / `Defender` / `Kubescape` / `azqr` ETL should standardise on `@{ kind = 'CIS'; controlId = '1.1.1'; version = '1.4.0' }`.
2. **`Frameworks` parameter type left as `[object[]]`** in `New-FindingRow` (it pre-existed in v2.1). Spec said `[hashtable[]]` but tightening the type would break existing fixtures that pass mixed shapes. The *contract* is hashtable-shaped; the *type-binding* stays loose for back-compat. `Merge-FrameworksUnion` works against either shape.
3. **`ScoreDelta` is `Nullable[double]`** so callers can distinguish "not measured" (`$null`) from "measured zero" (`0.0`). Tests assert both branches.
4. **No enum tightening, no rename.** `Severity` / `EntityType` / `Platform` / `Confidence` enums all unchanged.
5. **Test version literals** (`'2.1'` → `'2.2'`) updated mechanically across 17 test files. No behavioural assertion modified. Future schema bumps should expect to do the same one-line sweep.

## Test delta

- Baseline: **1369 passed / 0 failed / 5 skipped**
- After: **1381 passed / 0 failed / 5 skipped** (+12: 4 in `Schema.Tests.ps1`, 8 in `EntityStore.Tests.ps1`)

## Process learnings

- **Main branch was churning during the merge window** — three rebase-with-conflict cycles required (CHANGELOG.md hot file). Each conflict was the same shape: my `### Added` entry vs. a sibling PR's `### Added` entry collapsed into one line. Lesson: when CHANGELOG is the only conflict, a 30-second rebase + edit is faster than `--auto` + waiting for the queue.
- **The `edit` tool silently no-oped once on a malformed `old_str`** (when I built the replacement from a multi-line PowerShell here-string). Verified by re-reading the file before commit; caught the unresolved markers and amended. Future fix: always re-grep for `<<<<<<<` after a programmatic conflict resolution.
- **`gh pr merge --auto`** worked once main settled; the `--admin` flag is incompatible with `--auto` on this repo (must drop `--admin` when using `--auto`).
- **No Copilot review comments** arrived in the 8-minute window. Per `.copilot/copilot-instructions.md` "Cloud agent PR review contract" the squash-merge is permitted when there are no open Copilot threads.

# Lead inbox drop: PSRule ETL #301 (2026-04-22)

## Context
- Target issue: #301
- Contract source: `.squad/decisions.md` Schema 2.2 lock (PR #343 / 97b8277)

## Append-only updates
- Implemented wrapper enrichment in `modules/Invoke-PSRule.ps1` for `RuleId`, severity from PSRule `Level`, `Pillar`, `Frameworks`, `BaselineTags`, `DeepLinkUrl`, and `ToolVersion`.
- Implemented normalizer pass-through in `modules/normalizers/Normalize-PSRule.ps1` using `New-FindingRow` Schema 2.2 params only.
- Added remediation snippet extraction from recommendation markdown fenced code blocks with text fallback.
- Extended fixtures and tests:
  - `tests/fixtures/psrule-raw-results.json`
  - `tests/fixtures/psrule-output.json`
  - `tests/wrappers/Invoke-PSRule.Tests.ps1`
  - `tests/normalizers/Normalize-PSRule.Tests.ps1`
- Documentation updates in this PR: `README.md`, `CHANGELOG.md`.

# Decision: Identity blast-radius graph (#298) — vanilla SVG + Verlet, no D3

**Date:** 2026-04-22
**Owner:** Sage
**Status:** Implemented in PR for #298

## Choice

Pure vanilla JS + inline SVG with a tiny Verlet force-layout (~3 KB minified-equivalent
source). **No D3 dependency.**

## Why not D3

- The spec allows D3 if total payload stays under 200 KB inlined. D3-force alone (the only
  D3 sub-module we'd actually use) ships ~18 KB minified, and we'd still need to wire the
  drag/zoom and click handlers ourselves.
- For the expected node count (5–80 identity entities — Users / SPs / Groups / Apps /
  AzureResources) a quadratic O(n²) repulsion + linear spring loop converges in ~240
  iterations with no perceptible delay, all in <100 lines of code.
- Avoiding D3 keeps the report a single self-contained HTML file with zero supply-chain
  surface area — consistent with the "no CDN, inline everything" project rule and with the
  existing report's pattern (no JS deps anywhere else in the report).

## Empty-state threshold

5 nodes (per spec). Fewer than 5 → render a neutral "Identity graph unavailable" panel
explaining the threshold. The legend is hidden in the empty state to avoid visual noise.

## Edge synthesis

The current `entities.json` v3.1 envelope ships nodes but not yet typed edges. For the
generator path we synthesize `HasRoleOn` edges from identity-typed entities (User /
ServicePrincipal / Group / Application) to AzureResource entities sharing the same
`SubscriptionId`. This is a temporary heuristic — it gives a plausible blast-radius
visualisation today and will be replaced when `EntityStore.Edges` ships the real
ownership / role assignment / group membership / federated-credential edges.

The sample mockup uses hand-crafted edges that exercise all four edge kinds called out in
the spec.

## Click-to-filter

- Sample mockup: extends the existing `state.entity` filter and `applyFilters()` chain.
- Generator: hides non-matching `<tr>` in `findings-table` via a `display:none` toggle —
  consistent with how the existing `filterTable()` helper already works. A "clear filter"
  link restores the full table.

## Payload

Sample report `samples/sample-report.html`: 36 KB → ~62 KB (inlined renderer + mock data).
Generator-emitted reports: +~5 KB inline JS + ~50–500 bytes of embedded JSON model.
Both well under the 200 KB budget.

# Atlas decision: ado-pipeline-correlator Schema 2.2 ETL

- Normalizer emits Schema 2.2 blast-radius metadata for pipeline correlation findings: Pillar, Impact, Effort, DeepLinkUrl, RemediationSnippets, EvidenceUris, BaselineTags, EntityRefs, ToolVersion.
- Wrapper now emits correlation status (`correlated-direct`, `uncorrelated`, `build-not-found`, `correlated-fallback-project`) plus build, commit, and repository linkage fields to support cross-tool graphing.
- Correlation finding titles now include `[build:<id> secret:<findingId>]` to preserve dedup behavior (`Source|EntityId|Title|Compliant`) across multi-build and multi-secret scenarios.
- Added fixture, wrapper tests, and normalizer tests for direct and uncorrelated paths.

# Atlas decision - azure-quota Schema 2.2 ETL

Date: 2026-04-21
Issue: #360

## Decision
Use stable AzureResource entity IDs per subscription + location + service for azure-quota normalized findings.

## Why
EntityStore dedup keys on Platform|EntityType|EntityId. Quota emits many metric rows for the same service in the same region. A stable combo entity ID keeps one entity row per quota surface while preserving per-metric finding rows.

## Applied mapping
- Pillar: Reliability
- Impact from UsagePercent: High >= 90, Medium >= 75, Low < 75
- Effort heuristic: vm -> Medium, network -> Low
- ScoreDelta: UsagePercent
- DeepLinkUrl: Azure Portal quota blade with subscription, region, service
- EvidenceUris: quota docs by service
- EntityRefs: subscriptionId and location
- ToolVersion: azure-cli version from `az version`
- Frameworks, MITRE, BaselineTags: intentionally empty

# Atlas decision drop: Defender ETL Schema 2.2 closeout

Date: 2026-04-21
Issue: #302

## Decision

Implement Defender for Cloud Schema 2.2 plumbing in wrapper + normalizer using `New-FindingRow` fields only for renderable schema attributes.

## Implemented mapping

- Wrapper now captures and emits:
  - `ToolVersion`
  - `Pillar` (`Security`)
  - `Frameworks` (MCSB, ISO27001, PCI, CIS, NIST, SOC2 when found in Defender payloads)
  - `DeepLinkUrl`
  - `EvidenceUris`
  - `MitreTactics`, `MitreTechniques` from Defender alerts
- Wrapper adds Defender alerts endpoint fan-out (`Microsoft.Security/alerts`) and skips dismissed/resolved alerts.
- Normalizer passes Schema 2.2 fields through `New-FindingRow`.
- Removed Defender normalizer Add-Member extras for schema-owned fields.

## Test coverage

- Updated defender fixture with assessment + alert records carrying schema fields.
- Extended normalizer tests for Schema 2.2 pass-through and MITRE assertions.
- Added wrapper success-path tests with mocked secure score, assessments, and alerts payloads.

# Atlas decision: aks-karpenter-cost Schema 2.2 ETL

## Context
Issue #365 required end-to-end Schema 2.2 enrichment for aks-karpenter-cost wrapper and normalizer, while preserving entity and finding dedup behavior.

## Decisions
- Wrapper now emits Schema 2.2 fields for each finding: Pillar, Impact, Effort, DeepLinkUrl, RemediationSnippets, EvidenceUris, BaselineTags, ScoreDelta, EntityRefs, ToolVersion.
- Pillar is Cost Optimization by default, with Cost Optimization; Reliability for consolidation-disabled risk.
- Impact maps from NodeHours and ObservedPercent thresholds, with high impact for no-node-limit.
- Effort is Low for reader telemetry findings and Medium for provisioner remediation actions.
- Deep links use Microsoft_Azure_ContainerService portal blade URLs.
- Evidence URIs include Container Insights query links and Karpenter manifest API URIs.
- ToolVersion is stamped as kubectl plus Karpenter API version when available.
- EntityStore metadata merge now uses Merge-FrameworksUnion and Merge-BaselineTagsUnion to keep Schema 2.2 union semantics stable.

## Validation
- Targeted Pester suites for wrapper, normalizer, and EntityStore passed.
- Full Pester run passed with existing non-fatal warning baseline.

# atlas-powerpipe-etl-schema-22

- Issue: #304
- Scope: Add Powerpipe wrapper and normalizer with Schema 2.2 fields.
- Decision:
  - Implement `Invoke-Powerpipe.ps1` with graceful skip when CLI is missing.
  - Implement `Normalize-Powerpipe.ps1` to emit Frameworks, Pillar, Impact, Effort, DeepLinkUrl, RemediationSnippets, EvidenceUris, BaselineTags, Mitre fields, EntityRefs, and ToolVersion.
  - Register `powerpipe` in `tools/tool-manifest.json` and update docs and tests in the same PR.

# Decision: queries/ reorganized into per-tool subfolders

**Date:** 2026-04-21
**Author:** Atlas
**Issue:** #317
**PR:** #335 (merged at `b8aa059`)
**Status:** Inbox - ratify into `decisions.md` next sweep.

## Context

`queries/` was a flat folder mixing three different concerns:

1. `alz_additional_queries.json` - the canonical ALZ ARG query catalog, owned by `Invoke-AlzQueries.ps1`, kept in sync from `martinopedal/alz-graph-queries` by `scripts/Sync-AlzQueries.ps1` (PR #331, Forge).
2. Seven `finops-*.json` catalogs read via a `Get-ChildItem -Filter 'finops-*.json'` glob inside `Invoke-FinOpsSignals.ps1`.
3. `library/` (PR #327, Atlas) - 8 reference-only files mirroring inline-wrapper KQL with a README explaining they are operator docs, not data.

Wrapper ownership of (1) and (2) was invisible at the file-tree level, and the orphan-query audit (decisions.md - ALZ Queries SoT) had already shown that `Get-ChildItem` glob ownership is also invisible to grep. Adding more wrappers to the flat layout would have compounded the confusion.

## Decision

Per-tool subfolder per owning wrapper. Convention codified in new `queries/README.md`:

| Subfolder        | Owner       | Loaded by                         |
| ---------------- | ----------- | --------------------------------- |
| `queries/alz/`     | alz-queries | `modules/Invoke-AlzQueries.ps1`     |
| `queries/finops/`  | finops      | `modules/Invoke-FinOpsSignals.ps1`  |
| `queries/library/` | reference   | (no wrapper - operator docs only) |

All 8 runtime files moved via `git mv` to preserve blame. `library/` left intact - subdivision rejected (only 8 files, README explains origin, would be premature folder churn).

## Alternatives considered

- **`queries/alz-graph-queries/`** instead of `queries/alz/` - rejected. Bakes the upstream repo name into the local layout; `alz/` matches the wrapper basename (`Invoke-AlzQueries`) and the manifest tool name (`alz-queries`).
- **Subdivide `library/` now** (e.g. `library/aks-rightsizing/`, `library/appinsights/`) - rejected. Out of scope for #317; 8 files do not justify it.
- **Top-level `library/` flattened** to remove the level - rejected. Would re-mix reference and runtime concerns and contradict #318.

## Consequences

- Future tools that ship a runtime query catalog drop it under their own `queries/<tool-name>/` subfolder. README documents the rule.
- Wrapper defaults for `Invoke-AlzQueries.ps1` and `Invoke-FinOpsSignals.ps1`, the destination default for `Sync-AlzQueries.ps1`, and the affected tests (`Sync-AlzQueries.Tests.ps1`, `Invoke-FinOpsSignals.Tests.ps1`) updated in the same commit.
- README.md, docs/consumer/permissions/finops.md, queries/library/README.md updated; CHANGELOG.md entry added.
- Pester baseline preserved at 1354/1354.
- 3-of-3 rubber-duck APPROVE (Opus 4.6, GPT-5.3-codex, Goldeneye) before implementation.

## Cross-refs

- decisions.md - ALZ Queries SoT (orphan-query audit, glob-ownership lesson)
- PR #327 - `queries/library/` introduction
- PR #331 - `Sync-AlzQueries.ps1` (wrote to top-level pre-reorg)
- Issue #318 - library subfolder

### audit-schema22-gap-survey (2026-04-21)
Total tools audited: 22

WARRANTS
- kube-bench: #359
- azure-quota: #360
- finops: #361
- appinsights: #362
- loadtesting: #363
- aks-rightsizing: #364
- aks-karpenter-cost: #365
- gh-actions-billing: #366
- ado-connections: #367
- ado-pipelines: #368
- ado-consumption: #369
- ado-repos-secrets: #370
- ado-pipeline-correlator: #371
- zizmor: #372
- gitleaks: #373
- bicep-iac: #375
- terraform-iac: #376

SKIP
- falco: Current wrapper output only carries rule name, priority, pod, and process with no stable native metadata for at least two Schema 2.2 enrichments.
- azure-cost: Output is cost rollup telemetry and top resource spend with no native control or taxonomy metadata beyond existing v2 fields.
- alz-queries: Query payload exposes category and severity only, and does not carry framework, MITRE, baseline, snippet, or evidence link metadata.

ALREADY-COVERED
- identity-correlator: Wrapper emits FindingRow objects through New-FindingRow before normalization, so SchemaVersion already resolves to 2.2.
- identity-graph-expansion: Wrapper emits v2 FindingRows and normalizer is pass-through with defensive canonicalization.

### 2026-04-21T11:12:00Z: User directive — launch deadline
**By:** Martin Opedal (via Copilot)
**What:** Hard deadline: ALL current workstreams must merge to main before 2026-04-22 08:00 local (CET). Active scope: #295, #296, #297, #298, #299, #300-#313 (14 ETL issues), #325, #326. Iterate-Until-Green is non-negotiable; no agent may abandon a PR. Frontier-only roster as always; fallback chain on rate limits, never downgrade tier.
**Why:** Launch day. Everything in flight ships or it doesn't go out.

## Forge decision drop, issue #300 azqr Schema 2.2 ETL

- Wrapper now captures azqr `--version` once per run and stamps `ToolVersion` on the envelope and each finding.
- Wrapper projects raw azqr output into stable finding fields, including `RecommendationId`, `Impact`, `Effort`, `DeepLinkUrl`, `Pillar`, `Frameworks`, `MitreTactics`, `MitreTechniques`, `RemediationSnippets`, `EvidenceUris`, `BaselineTags`, and `EntityRefs`.
- Pillar mapping follows azqr taxonomy with canonical WAF values: `Security`, `Reliability`, `CostOptimization`, `PerformanceEfficiency`, `OperationalExcellence`.
- Normalizer now passes Schema 2.2 fields through `New-FindingRow` only, preserving backward-compatible fields and adding `RuleId` from `RecommendationId`.
- Azqr frameworks are normalized to Schema 2.2 tuple shape (`kind`, `controlId`) and include WAF pillar membership.
- Tests expanded with realistic fixture payloads and assertions for every new azqr-emitted Schema 2.2 field.

# forge-finops-etl-schema22-mapping

- Date: 2026-04-21
- Issue: #361
- Decision: FinOps wrapper emits recommendation text plus tool version; normalizer owns Schema 2.2 mapping for Pillar, Impact, Effort, DeepLinkUrl, RemediationSnippets, EvidenceUris, ScoreDelta, EntityRefs, ToolVersion.
- Rationale: Keep wrapper v1 envelope minimal and stable while centralizing schema logic in ETL.
- Mapping: Pillar fixed to Cost Optimization; Impact from monthly cost bands (>500 High, 100-500 Medium, <100 Low); Effort heuristic maps IdleVM and orphaned disk paths to Low, oversized App Service SKU to Medium, network-control redesign paths to High.
- Evidence strategy: each finding links to Cost Management blade deep link and query-id search URL in alz-graph-queries.

# Forge Decision Inbox — Manifest cleanup (#314 #320 #321)

Date: 2026-04-22

## Decision

For the new `azure-quota` manifest registration, keep the existing CLI installer-compatible `install.command` field and also include `install.commands` from the locked mapping so current installer/tests stay green while preserving the planned schema signal.

## Rationale

- Current installer logic and Pester assertions (`tests/shared/Installer.Tests.ps1`) require `install.command` for `kind: "cli"`.
- Issue #321 mapping requires `commands: ["az"]`.
- Carrying both keys avoids breaking baseline behavior now and avoids a follow-up rebase churn when wrapper/normalizer work lands in #322-#325.

## Follow-up

- Consolidate on a single CLI install schema (`command` vs `commands`) in a dedicated compatibility PR once installer + tests are updated together.

# Forge update - Prowler ETL #303

- Date: 2026-04-21
- Scope: Added Prowler wrapper + normalizer pipeline to Schema 2.2 with tests and manifest wiring.
- Wrapper: captures ToolVersion, Pillar, Frameworks, BaselineTags, MITRE fields, remediation snippets, and deep link URL from Prowler output.
- Normalizer: emits via `New-FindingRow`, canonical ARM EntityId, and `EvidenceUris` from `ResourceArn`.
- Tests: added wrapper + normalizer suites and realistic multi-framework fixtures; includes framework union assertion with `Merge-FrameworksUnion`.

# Forge decision note — Sync ALZ queries (#315)

## Context
- Issue #315 asked for a manifest-driven ALZ query sync script.
- Upstream for `alz-queries` is now correctly set in `tools/tool-manifest.json` to `martinopedal/alz-graph-queries` (built on #314).
- Query-folder reshaping (`queries/alz/`) is deferred to #317.

## Decision
- Implement sync target as **top-level local** `queries/alz_additional_queries.json` (no `queries/alz/` subfolder yet).
- Resolve upstream repo from manifest (`tools[].name == "alz-queries" -> upstream.repo`) and normalize to HTTPS clone URL.
- Default upstream source path is `queries/alz_additional_queries.json` (relative to upstream repo root), matching current upstream layout.
- Enforce clone/fetch through shared helpers (`RemoteClone.ps1`, `Retry.ps1`, `Installer.ps1::Invoke-WithTimeout`, `Sanitize.ps1`) and throw rich installer-style failures via `New-InstallerError`.

## Why
- Keeps #315 narrowly scoped and avoids churn before #317 lands.
- Maintains security invariants (HTTPS-only + allow-list + credential scrubbing/sanitized output) by reusing shared infra.
- Makes re-runs no-op by hash comparison, enabling safe CI/operator use.

## Follow-up
- When #317 moves query files into tool subfolders, adjust `DestinationRelativePath` default from top-level `queries/` to the new ALZ folder while preserving dry-run + idempotence semantics.

# Decision: ado-connections Schema 2.2 ETL shape

- Date: 2026-04-21
- Issue: #367
- Owner: Iris

## Decision

Implement Schema 2.2 additive fields in both ado-connections wrapper and normalizer, with auth-posture semantics:

- Pillar fixed to `Security`
- Impact and Effort derived from auth mechanism and sharing state
- BaselineTags from auth scheme, auth mechanism, and shared vs scoped state
- DeepLinkUrl to ADO service connection settings
- EvidenceUris containing service endpoint REST URI and audit settings URI
- EntityRefs containing org, project, and service connection references
- ToolVersion fixed to `ado-rest-api-7.1`

Canonical entity identity in normalized rows is `org/project/connectionId` to keep EntityStore dedup deterministic.

## Consequences

- No new permission scope is required
- Existing v1 wrapper envelope remains intact
- Schema 2.2 fields flow end to end into findings and entity rollups

# Iris drop-box: AzGovViz ETL Schema 2.2 (#307)

## 2026-04-21

- Implemented wrapper enrichment in `modules/Invoke-AzGovViz.ps1` for `Pillar`, `Frameworks`, `BaselineTags`, `DeepLinkUrl`, `EvidenceUris`, and `ToolVersion`.
- Added AzGovViz cost signal parsing for `*OrphanedResources*.csv` and mapped it to `Category=Cost` and `Pillar=Cost`.
- Added policy framework projection shape:
  - `@{ Name = 'ALZ'; Controls = @(<policySetId>) }`
  - `@{ Name = 'MCSB'; Controls = @(<mcsbControlIds...>) }`
- Normalizer now emits Schema 2.2 fields through `New-FindingRow` and resolves entity scope to `Subscription`, `ManagementGroup`, `Tenant`, or `AzureResource`.
- Added parent reference emission in `EntityRefs` for subscription, management-group, and tenant chain hints when available.
- Extended AzGovViz fixtures and tests to verify pillar derivation, framework and baseline extraction, and entity dedup behavior through `EntityStore`.

# Iris decision brief - HTML report alignment (#295)

## Decision

Implement the report page as a single-scroll layout matching `samples/sample-report.html`, while keeping data rendering server-side for findings rows and using client-side JS only for sort/filter/expand/theme interactions.

## Key implementation choices

1. **Heatmap fallback contract**: default matrix is Domain x Subscription when subscriptions exist; if no subscription dimension is present, fallback mode becomes Tool x Severity. Framework x Subscription remains available as a third mode when framework/sub data exists.
2. **Schema 2.2 fields** are rendered defensively (`if present -> render`, `if absent -> omit`) for: `Pillar`, `Frameworks`, `Impact`, `Effort`, `DeepLinkUrl`, `RemediationSnippets`, `EvidenceUris`, `MitreTactics`, `MitreTechniques`.
3. **Sanitization boundary**: all dynamic strings pass through `Remove-Credentials` and HTML escaping before writing report output.

## Why

This preserves backward compatibility for pre-#299 payloads, aligns UI with the locked mockup, and avoids leaking unsanitized secrets in generated HTML.

# kube-bench Schema 2.2 ETL mapping decision

Date: 2026-04-21
Issue: #359

## Decision

- Treat kube-bench findings as Security pillar findings.
- Emit Frameworks as CIS Kubernetes Benchmark plus CIS-AKS for AKS managedClusters.
- Set Impact from severity (High/Critical => High, Medium => Medium, Low/Info => Low).
- Emit BaselineTags as ControlId and Status.
- Emit DeepLinkUrl from LearnMoreUrl.
- Emit RemediationSnippets as one snippet with language inferred as yaml when remediation looks like Kubernetes manifest, otherwise bash.
- Emit ToolVersion from the kube-bench image tag passed to the wrapper.
- Emit EntityRefs with cluster ResourceId and optional node reference when present in kube-bench result rows.

## Rationale

These mappings satisfy the locked Schema 2.2 additive contract while preserving existing dedup behavior and aligning with Kubescape ETL patterns.

# Iris Kubescape ETL Schema 2.2 history

## 2026-04-21
- Implemented kubescape wrapper ETL for Schema 2.2 fields: ToolVersion from `kubescape --version`, Pillar set to `Security`, Frameworks with `Name` and `Controls`, MitreTactics, MitreTechniques, and BaselineTags from framework names.
- Updated kubescape normalizer to pass Schema 2.2 fields only through `New-FindingRow`, including EvidenceUris mapped to kubescape control docs and RuleId/Controls from ControlId.
- Added realistic raw kubescape fixture and expanded wrapper plus normalizer tests to verify multi-framework propagation and MITRE pass-through.

# Iris decision: loadtesting schema 2.2 ETL

Date: 2026-04-21
Issue: #363

## Decision
Implement Schema 2.2 ETL for Azure Load Testing findings in both wrapper and normalizer.

## Scope
- Add Pillar, Impact, Effort, DeepLinkUrl, EvidenceUris, BaselineTags, ScoreDelta, EntityRefs, ToolVersion to loadtesting findings.
- Keep Frameworks, MitreTactics, and MitreTechniques empty for loadtesting.
- Derive Impact from RegressionPercent versus ThresholdPercent.
- Keep stale cadence Effort at Low and regression Effort at Medium.

## Why
This aligns loadtesting output with locked Schema 2.2 and unblocks report and entity rollup usage of additive fields.

## Verification
- Updated wrapper and normalizer tests.
- Updated fixture with schema 2.2 fields.
- Full Pester run required before merge.

# Iris Decision Brief — Azure Quota normalizer severity ladder (#323)

## Context
Issue #323 introduces `modules/normalizers/Normalize-AzureQuotaReports.ps1` for v1 wrapper output from #322. We had to finalize the severity behavior for percent-based quota usage while honoring the locked compliance formula.

## Decision
Use this ladder in the normalizer:
- `UsagePercent >= 99` => `Critical`
- `UsagePercent >= 95` => `High`
- `UsagePercent >= Threshold` => `Medium`
- below threshold => `Info`

Compliance stays locked to:
- `Compliant = (UsagePercent < Threshold)` with fallback `Threshold = 80` when absent.

## Rationale
- Aligns with `.squad/decisions.md` schema mapping for azure-quota.
- Keeps risk escalation intuitive near exhaustion (`>=99` becomes immediate critical capacity risk).
- Preserves full record coverage: compliant rows still emit as informational findings so trend/heatmap consumers can see healthy capacity headroom.

# Iris decision — Azure Quota wrapper retry semantics (#324)

## Context
- While building deep wrapper tests for `Invoke-AzureQuotaReports.ps1` (#324), transient `az vm list-usage` failures were not retried.
- Root cause: `Invoke-AzJson` / `Invoke-AzNoOutput` returned non-zero `ExitCode` responses from `Invoke-WithTimeout` without throwing inside the `Invoke-WithRetry` script block.

## Decision
- Treat non-zero Azure CLI exit codes as exceptions inside the `Invoke-WithRetry` script block.
- Preserve installer-style failure surfacing by catching retry exceptions and rethrowing through `Throw-QuotaFailure` (`New-InstallerError` payload, sanitized output).

## Why
- `Invoke-WithRetry` retries on thrown errors; returning a failed response object bypassed retry entirely.
- This keeps behavior consistent with the shared retry contract and makes transient CLI/API failures resilient while preserving sanitized diagnostics for permanent failures.

## Impact
- Wrapper now retries transient CLI failures as designed.
- Permanent failures still surface as sanitized `New-InstallerError` payloads.
- New wrapper tests lock this behavior with realistic CLI fixtures.

# Iris decision — Azure Quota wrapper (#322)

## Context
Issue #322 requires a new wrapper for azure-quota using Azure CLI fanout, while normalizer work is deferred to #323.

## Decision
Implement modules/Invoke-AzureQuotaReports.ps1 as a v1-envelope collector that:
- accepts -Subscriptions and -Locations filters,
- defaults to all enabled subscriptions (az account list) and per-subscription physical regions (az account list-locations),
- executes az vm list-usage and az network list-usages for each (subscription, location) pair,
- computes compliant as UsagePercent < Threshold with default threshold 80.

## Why
This keeps the wrapper cloud-first and fanout-capable without coupling to normalizer decisions. It also matches the locked mapping (Pillar=Reliability, Category=Capacity, EntityType=Subscription) while preserving raw quota details for #323 normalizer work.

# Schema 2.2 audit pass - normalizers

Generated: 2026-04-21 16:42:21 +02:00

Total normalizers audited: 36
Enabled-tool baseline coverage (score >= 6): 25/36 (69.4%)
Gap tools (<6): 11
Mid tools (6-8.9): 19
Reference quality (9-10): 6

## Audit table

| tool | score | missing fields | filed issue # |
|---|---:|---|---|
| falco | 0 | Pillar, Frameworks, MitreTactics, MitreTechniques, DeepLinkUrl, RemediationSnippets, EvidenceUris, BaselineTags, EntityRefs, ToolVersion, Impact, Effort | #399 |
| gitleaks | 0 | Pillar, Frameworks, MitreTactics, MitreTechniques, DeepLinkUrl, RemediationSnippets, EvidenceUris, BaselineTags, EntityRefs, ToolVersion, Impact, Effort | #373 |
| ado-pipeline-correlator | 1.2 | Pillar, Frameworks, DeepLinkUrl, RemediationSnippets, EvidenceUris, BaselineTags, EntityRefs, ToolVersion, Impact, Effort | #371 |
| alz-queries | 1.2 | Pillar, Frameworks, DeepLinkUrl, RemediationSnippets, EvidenceUris, BaselineTags, EntityRefs, ToolVersion, Impact, Effort | #400 |
| azgovviz | 1.2 | Pillar, Frameworks, DeepLinkUrl, RemediationSnippets, EvidenceUris, BaselineTags, EntityRefs, ToolVersion, Impact, Effort | #401 |
| azure-cost | 1.2 | Pillar, Frameworks, DeepLinkUrl, RemediationSnippets, EvidenceUris, BaselineTags, EntityRefs, ToolVersion, Impact, Effort | #402 |
| bicep-iac | 1.2 | Pillar, Frameworks, DeepLinkUrl, RemediationSnippets, EvidenceUris, BaselineTags, EntityRefs, ToolVersion, Impact, Effort | #375 |
| identity-correlator | 1.2 | Pillar, Frameworks, DeepLinkUrl, RemediationSnippets, EvidenceUris, BaselineTags, EntityRefs, ToolVersion, Impact, Effort | #403 |
| identity-graph-expansion | 1.2 | Pillar, Frameworks, DeepLinkUrl, RemediationSnippets, EvidenceUris, BaselineTags, EntityRefs, ToolVersion, Impact, Effort | #404 |
| terraform-iac | 1.2 | Pillar, Frameworks, DeepLinkUrl, RemediationSnippets, EvidenceUris, BaselineTags, EntityRefs, ToolVersion, Impact, Effort | #376 |
| zizmor | 1.2 | Pillar, Frameworks, DeepLinkUrl, RemediationSnippets, EvidenceUris, BaselineTags, EntityRefs, ToolVersion, Impact, Effort | #372 |
| azure-quota | 6.2 | Frameworks, RemediationSnippets, BaselineTags |  |
| defender-for-cloud | 6.2 | RemediationSnippets, BaselineTags, EntityRefs |  |
| kubescape | 6.2 | DeepLinkUrl, RemediationSnippets, EntityRefs, Impact, Effort |  |
| ado-consumption | 7.5 | Frameworks, RemediationSnippets |  |
| ado-repos-secrets | 7.5 | Frameworks, MitreTactics, MitreTechniques |  |
| appinsights | 7.5 | Frameworks, RemediationSnippets |  |
| finops | 7.5 | Frameworks, BaselineTags |  |
| loadtesting | 7.5 | Frameworks, RemediationSnippets |  |
| scorecard | 7.5 | MitreTactics, MitreTechniques, EntityRefs, Impact, Effort |  |
| sentinel-coverage | 7.5 | RemediationSnippets, EvidenceUris, BaselineTags, Impact, Effort |  |
| sentinel-incidents | 7.5 | RemediationSnippets, BaselineTags, Impact, Effort |  |
| ado-connections | 8.8 | Frameworks |  |
| aks-karpenter-cost | 8.8 | Frameworks |  |
| aks-rightsizing | 8.8 | Frameworks |  |
| gh-actions-billing | 8.8 | Frameworks |  |
| kube-bench | 8.8 | MitreTactics, MitreTechniques, EvidenceUris, Effort |  |
| prowler | 8.8 | EntityRefs, Impact, Effort |  |
| psrule | 8.8 | EvidenceUris, EntityRefs, Impact, Effort |  |
| trivy | 8.8 | MitreTactics, MitreTechniques |  |
| ado-pipelines | 10 | None |  |
| azqr | 10 | None |  |
| infracost | 10 | None |  |
| maester | 10 | Impact, Effort |  |
| powerpipe | 10 | None |  |
| wara | 10 | EvidenceUris |  |

## Recommended execution order

1. Security scanners with zero Schema 2.2 enrichment: falco, gitleaks.
2. Correlation and governance tools with broad metadata gaps: ado-pipeline-correlator, alz-queries, azgovviz, azure-cost.
3. Identity lineage tools: identity-correlator, identity-graph-expansion.
4. IaC and workflow scanners already tracked: bicep-iac, terraform-iac, zizmor.
5. Mid-band tools (6-8.9) to raise to 9+: focus on Frameworks, RemediationSnippets, MITRE completeness, and EntityRefs consistency.

## Notes

- Existing open ETL issues reused where already present (#371, #372, #373, #375, #376).
- New issues opened in this pass: #399, #400, #401, #402, #403, #404.

# lead-adopipelines-etl-schema22

- Issue: #368 ado-pipelines Schema 2.2 ETL.
- Decision: emit Schema 2.2 fields in wrapper and normalize through New-FindingRow for ado-pipelines only.
- Key mappings: Pillar=Security, RuleId-driven Impact/Effort, DeepLinkUrl by asset type, EvidenceUris include asset REST plus audit log.
- Entity contract: Platform=AzureDevOps, EntityType=AssetType, EntityId=AdoOrg/AdoProject/AssetType/AssetId.
- Baseline tags: Asset-{AssetType} plus control tag derived from RuleId.
- Exclusions: Frameworks and MITRE arrays intentionally left empty for ado-pipelines.

# Lead decision: aks-rightsizing Schema 2.2 ETL

Date: 2026-04-21
Issue: #364
Owner: Lead

## Decisions

1. Wrapper emits Schema 2.2 metadata at source for each finding: Pillar, Impact, Effort, DeepLinkUrl, RemediationSnippets, EvidenceUris, BaselineTags, ScoreDelta, EntityRefs, ToolVersion.
2. Normalizer maps all emitted fields into New-FindingRow and keeps Frameworks, MitreTactics, and MitreTechniques empty for this tool.
3. Workload entity identity is stable and deterministic: cluster resourceId + namespace + workload name. This allows EntityStore union merge to combine multi-category findings on the same workload.
4. ScoreDelta follows workload signal percent (waste for overprovisioned, saturation for underprovisioned and failure categories).
5. BaselineTags include category and metric forms for downstream filtering.

## Validation

- Targeted Pester suites for wrapper and normalizer are green.
- Full Pester suite is green after changes.

# Lead decision - infracost Schema 2.2 ETL

- Issue: #312
- Scope: `Invoke-Infracost.ps1` + `Normalize-Infracost.ps1`
- Decision: emit v1 `ToolSummary` and carry Schema 2.2 cost metadata end-to-end.
- Mapping:
  - `Pillar=Cost` for all findings.
  - `Impact` derived from finding monthly cost as percent of project total.
  - `Effort` derived from Terraform resource type complexity buckets.
  - `ScoreDelta` mapped from monthly baseline diff (`DiffMonthlyCost`).
  - `Frameworks` emits `{ kind: WAF, controlId: Cost }`.
- Evidence:
  - Wrapper stores breakdown payload path as `EvidenceUris` and propagates tool version (`infracost --version`).
  - Normalizer maps all fields through `New-FindingRow` v2.2 params.
- Validation:
  - Targeted tests: wrapper + normalizer green.
  - Full Pester suite green.

# PR Patrol Round 1

Timestamp: 2026-04-21

Actions:
- Queried open PR board and status checks.
- Rebasing unblocked ETL branches:
  - PR #392 (`squad/372-zizmor-etl`): rebased on `origin/main`, force-pushed.
  - PR #394 (`squad/371-adopipelinecorrelator-etl`): rebased on `origin/main`, force-pushed.
- Rechecked board after pushes.

Current board snapshot:
- PR #391: merge state `UNKNOWN`, checks pending.
- PR #392: merge state `BEHIND`, checks pending after rebase push (no failing checks).
- PR #394: merge state `BEHIND`, checks pending after rebase push (no failing checks).

Blockers:
- None yet. Waiting for current CI runs to complete.

# PR Patrol Round 2

Timestamp: 2026-04-21

Actions:
- Investigated CI red on PR #392 and PR #394.
- Root cause for PR #392 test failures (macOS and Ubuntu): `tests/hooks/PreCommit.Tests.ps1` resolved repo root via `git rev-parse` returning empty in CI context.
- Applied trivial unblock fix in PR #392 branch (`squad/372-zizmor-etl`): switched repo root resolution to `Resolve-Path (Join-Path $PSScriptRoot ''..\..'')` in all `BeforeAll` blocks.
- Ran targeted validation: `Invoke-Pester -Path .\tests\hooks\PreCommit.Tests.ps1 -CI` passed (23/23).
- Committed and pushed fix on PR #392.
- PR #394 had markdown link check red due known `keda.sh` timeout flake; triggered workflow rerun for run `24728424258`.
- Rebased and force-pushed PR #391 (`chore/gitignore-squad-local`) again to keep up with fast-moving main.
- Checked DIRTY PRs (#396/#397/#398): local branches are already up to date with `origin/main`; merge state shifted from DIRTY to pending/blocked while checks run.

Blockers:
- No hard blockers yet. Most open PRs are currently waiting on in-flight CI checks.

# PR Patrol Round 3

Timestamp: 2026-04-21

Actions:
- Re-polled open PR queue repeatedly after prior rebases and CI reruns.
- Rebased and force-pushed PR #391 (`chore/gitignore-squad-local`) to reduce BEHIND state drift.
- Checked all ETL worktrees (#372, #373, #375, #376) against `origin/main`; all local branches report up to date.
- Attempted merge sweep after 70s wait; no PR met merge criteria yet because required checks were still in progress.
- Verified no active CI failures at time of latest poll; queue is blocked on pending checks and transient merge-state recomputation (`DIRTY`/`BLOCKED` while CI in progress).

Current snapshot:
- PR #391: BEHIND, pending checks.
- PR #392: BLOCKED, pending checks.
- PR #396: DIRTY, pending checks.
- PR #398: DIRTY, pending checks.

Blockers:
- No hard code blocker currently identified.
- Primary blocker is in-flight CI completion across all open PRs.

# PR Patrol Round 4

Timestamp: 2026-04-21

Scope: PRs #405, #407, #408, #414

Actions taken:
- Pulled latest PR states and branch refs.
- Aggressive rebase pass:
  - #405 (`feat/400-alzqueries-schema22`): rebased twice on latest `origin/main`; resolved README and PERMISSIONS additive conflicts by keeping both entries; force-pushed.
  - #414 (`squad/376-terraformiac-postmerge-fix`): rebased and force-pushed repeatedly as main advanced.
  - #407 (`feat/402-azurecost-schema22`): verified worktree clean and branch up to date after prior conflict resolution.
  - #408 (`chore/launch-sample-report-polish`): branch already up to date with main.
- Investigated #408 red Ubuntu test; triggered workflow rerun (`24731301885`).
- Switched polling cadence to 30s and repeatedly checked readiness + attempted auto-merge when criteria were met.

Current snapshot:
- #405: checks still in progress (no current hard failure).
- #407: checks in progress.
- #408: merge state clean and mergeable; one check still pending.
- #414: mergeable, but still blocked by in-flight checks after latest rebase.

Blockers:
- No hard code blocker confirmed in this round.
- Main branch churn keeps re-introducing BEHIND/BLOCKED while checks are running.

# Lead drop-box: Sentinel incidents ETL (#309)

Date: 2026-04-21
Owner: Lead

Append-only notes:

- Locked implementation to Schema 2.2 (`97b8277`) and kept `New-FindingRow` as the only normalizer emission path.
- Wrapper now captures MITRE and entity context from incident fields and emits typed fields plus `Pillar`, `ToolVersion`, `Frameworks`, `MitreTactics`, `MitreTechniques`, `DeepLinkUrl`, `EvidenceUris`, and `EntityRefs`.
- Normalizer now passes schema fields through `New-FindingRow` and removes Add-Member extras.
- Added multi-tactic Sentinel fixtures and tests that assert `Merge-FrameworksUnion` behavior through EntityStore when multiple incidents hit the same workspace entity.

# Nova summary: falco schema 2.2

- Issue: #399
- Branch: feat/399-falco-schema22
- PR: #412
- Merge commit: 82754dfe9e8c63f5c0fc1c9dc14c6ac211f9c24e
- Status: merged

## Scope completed
- Upgraded `modules/Invoke-Falco.ps1` to emit Schema 2.2 ETL metadata for Falco runtime findings:
  - RuleId, Frameworks, Pillar, Impact, Effort, DeepLinkUrl, RemediationSnippets
  - EvidenceUris, BaselineTags, MitreTactics, MitreTechniques, EntityRefs, ToolVersion
- Upgraded `modules/normalizers/Normalize-Falco.ps1` to map and default all required Schema 2.2 fields through `New-FindingRow` with SchemaVersion 2.2.
- Added fixture-backed Falco normalizer coverage in `tests/normalizers/Normalize-Falco.Tests.ps1` and moved fixture to `tests/fixtures/falco/falco-output.json`.
- Updated `README.md`, `PERMISSIONS.md`, and `CHANGELOG.md` for the Falco Schema 2.2 ETL upgrade.

## Validation
- Targeted tests: `Invoke-Pester -Path .\\tests\\normalizers\\Normalize-Falco.Tests.ps1,.\\tests\\wrappers\\Invoke-Falco.Tests.ps1 -CI` passed.
- Full suite: `Invoke-Pester -Path .\\tests -CI` passed (1495 passed, 0 failed, 5 skipped, total 1500).
- PR checks were green before merge, including required `Analyze (actions)`.

# Sage decision: appinsights schema 2.2 ETL

Date: 2026-04-21
Issue: #362

## Decision
Implement Schema 2.2 mapping in both wrapper and normalizer for appinsights findings.

## Mapping
- Pillar from QueryType: requests and dependencies => PerformanceEfficiency, exceptions => Reliability.
- BaselineTags include query family tag and metric category tag.
- DeepLinkUrl uses Azure Portal AnalyticsBlade links with KQL and timespan.
- EvidenceUris includes overview link and analytics deep link.
- Impact and Effort use count and latency heuristics.
- ScoreDelta uses latency baseline delta when available, otherwise AvgDurationSeconds.
- EntityRefs include component ResourceId and parent App Service refs from hidden-link tags.
- ToolVersion comes from Az.ApplicationInsights module version with az CLI fallback.

## Entity dedup guardrail
Keep entity identity on Platform|EntityType|EntityId and finding identity on Source|EntityId|Title|Compliant. Update EntityStore merge logic to union Frameworks and BaselineTags for duplicate findings.

# Decision: Trivy Schema 2.2 ETL for issue #311

Date: 2026-04-21  
Owner: Sage

## Context

Issue #311 requires Trivy wrapper and normalizer support for the locked Schema 2.2 additive fields.

## Decision

Implement Schema 2.2 enrichment in `Invoke-Trivy.ps1` and pass-through in `Normalize-Trivy.ps1` with deterministic image digest entity IDs:

- Wrapper emits `Pillar`, `Impact`, `Effort`, `DeepLinkUrl`, `Frameworks`, `RemediationSnippets`, `EvidenceUris`, `BaselineTags`, `ScoreDelta`, `EntityRefs`, `RuleId`, and `ToolVersion`.
- Wrapper parses both `Vulnerabilities` and `Misconfigurations` and keeps one finding per CVE.
- Normalizer preserves all 2.2 fields through `New-FindingRow` and maps digest resource IDs to `trivy/image/sha256:...`.
- Tests and fixtures are updated to assert the new ETL contract.

## Rationale

This keeps Trivy aligned with Schema 2.2 and the entity dedup contract while preserving existing v1 envelope behavior and non-throwing wrapper semantics.

# Sage WARA ETL Log

## 2026-04-22
- Implemented WARA wrapper ETL updates for issue #308.
- Wrapper now captures ToolVersion from `Get-Module WARA`.
- Wrapper invokes collector plus analyzer and reads `Expert-Analysis-*.xlsx` metadata when available.
- Emission now preserves all impacted resources by outputting one finding per resource.
- Added v1 finding fields required for Schema 2.2 normalization: `Pillar`, `RecommendationId`, `Impact`, `Effort`, `DeepLinkUrl`, `BaselineTags`, `RemediationSteps`, `EntityRefs`, and `ToolVersion`.
- Normalizer now emits Schema 2.2 fields via `New-FindingRow` including `Frameworks`, `Pillar`, `Impact`, `Effort`, `DeepLinkUrl`, `RemediationSnippets`, `BaselineTags`, `EntityRefs`, and `ToolVersion`.
- Added tests for wrapper success path and normalizer assertions, including full WAF pillar coverage for Reliability, Security, Cost, Performance, Operational.

# Sentinel decision - issue #373 gitleaks Schema 2.2 ETL

Date: 2026-04-21
Issue: #373

## Decision
Implement full Schema 2.2 ETL mapping for gitleaks wrapper and normalizer with security metadata and deterministic repository dedup behavior.

## Implemented
- Wrapper now emits RuleId, Frameworks, Pillar, Impact, Effort, DeepLinkUrl, RemediationSnippets, EvidenceUris, BaselineTags, EntityRefs, ToolVersion.
- Added gitleaks tool-version capture via `gitleaks version`.
- Added cloud credential severity mapping to Critical, generic secret mapping to Medium.
- Added baseline tags from RuleId and tags.
- Added commit/blob evidence URI generation and workflow/commit entity refs.
- Normalizer now maps all schema 2.2 fields through `New-FindingRow`.
- Updated fixtures and wrapper/normalizer tests.
- Updated README, PERMISSIONS, CHANGELOG, and gitleaks permissions doc.

## Validation
- Targeted tests for gitleaks wrapper and normalizer pass.
- Full Pester suite run after changes.

# Sentinel decision - ado-consumption schema 2.2 ETL

Date: 2026-04-21
Issue: #369

## Decision
Implement schema 2.2 ETL in both wrapper and normalizer for ado-consumption with cost-governance metadata.

## Applied
- Added Pillar, Impact, Effort, DeepLinkUrl, EvidenceUris, BaselineTags, ScoreDelta, EntityRefs, ToolVersion emission in `Invoke-AdoConsumption.ps1`.
- Adopted RuleIds: Consumption-MinuteShareHigh, Consumption-DurationRegression, Consumption-FailRateHigh, Consumption-BudgetOverrun.
- Fail-rate findings override Pillar to Operational Excellence; others use Cost Optimization.
- Added az devops version capture for ToolVersion.
- Normalizer now maps all schema 2.2 fields into `New-FindingRow`.
- Updated fixture and tests for wrapper and normalizer.
- Updated README, PERMISSIONS docs, and CHANGELOG.

## Validation
- Targeted tests: `Invoke-AdoConsumption` and `Normalize-AdoConsumption` passed.
- Full suite: 1412 passed, 0 failed, 5 skipped.

# Sentinel Coverage ETL Drop

## 2026-04-21

- Implemented Schema 2.2 ETL for `sentinel-coverage` across wrapper and normalizer.
- Wrapper now emits `ToolVersion`, `Pillar`, `DeepLinkUrl`, `Frameworks`, `MitreTactics`, and `MitreTechniques`.
- Normalizer now maps those fields through `New-FindingRow` and sets workspace `EntityRefs`.
- Extended fixture and tests to verify MITRE technique IDs flow end-to-end.

# Sentinel decision - Maester Schema 2.2 ETL

- Date: 2026-04-21
- Issue: #305
- Scope: `Invoke-Maester.ps1`, `Normalize-Maester.ps1`, Maester fixtures and tests

Decision:
- Preserve one-test-to-one-finding shape and enrich each finding with Schema 2.2 optional fields.
- Derive `Frameworks` and `BaselineTags` from Maester tags for CIS Microsoft 365, NIST 800-53, and EIDSCA.
- Pass MITRE tactics and techniques from tags when present.
- Set `Pillar` to `Security`.
- Build `DeepLinkUrl` as `https://maester.dev/docs/tests/{TestId}`.
- Emit `EvidenceUris` from test source and Learn docs.
- Emit `RemediationSnippets` from "How to fix" markdown code blocks, fallback to text.
- Emit `EntityRefs` with tenant ID and service principal IDs from test scope.
- Emit `ToolVersion` from installed Maester module version.
- Keep tenant-scoped normalization (`EntityType=Tenant`, `Platform=Entra`) and canonicalize entity refs.

# Sentinel review patrol round 1

Date: 2026-04-21
Reviewer: martinopedal

- Queried open squad PRs with `gh pr list --state open --label squad`.
- Result: no open squad PRs.
- Schema 2.2 substantive review queue is empty for this round.

Status: board empty.

# Sentinel review patrol round 2

Date: 2026-04-21
Scope: Focused review requested for PR #396 and #398

## Reviewed
- PR #396 feat: bicep-iac Schema 2.2 ETL
  - Result: No blocking Schema 2.2 gaps found in this pass.
  - Action: Left non-blocking review comment noting pass.

- PR #398 feat(terraform-iac): Schema 2.2 ETL closure
  - Result: Substantive gaps found.
  - Gaps reported:
    1) Missing MITRE mapping for security findings in normalizer.
    2) Non-canonical pillar naming in adapter output.
    3) Schema scope expansion (new EntityType IaCFile) mixed into ETL PR.
  - Action: Left actionable review comment with file targets.

## Resume loop
- Continue polling open squad PRs after this focused pass.

# Sentinel review patrol round 3

Date: 2026-04-21

- Ran live board polling twice (90 seconds apart) for open `squad` PRs.
- Focus target remains #398 and incoming #399-#404 wave.
- This round is a polling checkpoint; substantive reviews will be posted immediately when new eligible PRs appear.

# Sentinel review patrol round 4

Date: 2026-04-21

- Polled open `squad` PRs.
- Active PR observed: #405 feat(alz-queries): close schema 2.2 ETL gaps.
- Author is `martinopedal` (same reviewer identity in this session), so no approve action taken per patrol rule to avoid self-approval.
- Queue remains monitored for incoming #399-#404 wave or other non-self-authored ETL PRs.

# Sentinel review patrol round 5

Date: 2026-04-21

## Reviewed
- PR #405 (alz-queries): substantive Schema 2.2 pass comment posted.
- PR #406 (azgovviz): substantive Schema 2.2 pass comment posted.

## Notes
- Self-approval intentionally not used.
- Continuing active polling for incoming ETL PR wave.

# Sentinel Scorecard ETL history (#313)

## 2026-04-21T00:00:00Z
- Started Sentinel implementation for OpenSSF Scorecard wrapper + normalizer ETL closure to Schema 2.2.
- Locked scope from issue #313 plus `.squad/decisions.md` Schema 2.2 contract and severity bug note.

## 2026-04-21T00:30:00Z
- Updated `modules/Invoke-Scorecard.ps1` to capture scorecard tool version, baseline tag, deep-link URL, pillar, frameworks, remediation snippets, check details, and score-driven severity.
- Added static category mapping and SLSA framework controls where applicable.

## 2026-04-21T01:00:00Z
- Updated `modules/normalizers/Normalize-Scorecard.ps1` to emit Schema 2.2 fields via `New-FindingRow` only.
- Implemented EvidenceUris extraction from scorecard check details (URLs, commit SHAs, file paths).

## 2026-04-21T01:30:00Z
- Extended fixtures and tests for wrapper and normalizer, including score boundary severity mapping and repository dedup check via `Merge-UniqueByKey`.
- Updated `CHANGELOG.md` and `README.md`; confirmed `PERMISSIONS.md` unchanged per task scope.
