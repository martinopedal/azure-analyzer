# Squad Decisions

> Entries older than 30 days archived to `decisions-archive.md` (2026-04-22).

## Active Decisions

### Multi-Model Development Process Codified (2026-01-15)
- **Decision:** All code changes follow the mandatory multi-model review pipeline: Build -> Review (3 models) -> Fix -> Re-gate -> CI -> Merge. Models: Opus 4.6, Goldeneye, GPT-5.3-codex. All 3 must approve before merge.
- **Why:** Ensures code quality through independent multi-perspective validation. Catches bugs that single-model review misses. Proven across 4 phases with 50+ findings caught.
- **Enforcement:** Documented in `.copilot/copilot-instructions.md` and `.squad/ceremonies.md` for automatic discovery by future sessions.
- **Status:** Active

### Canonical Entity IDs in Test Fixtures (2026-04-18)
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

## Governance

- All meaningful changes require team consensus
- Document architectural decisions here
- Keep history focused on work, decisions focused on direction
