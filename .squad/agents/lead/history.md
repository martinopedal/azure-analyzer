# Project Context

- **Owner:** martinopedal
- **Project:** ALZ Additional Graph Queries - Azure Landing Zone checklist automation
- **Stack:** PowerShell, KQL (Azure Resource Graph), JSON
- **Created:** 2026-04-14

## Work Completed

- **2024-12-19:** Established routing infrastructure (routing.md with 11 rules, Module Ownership section)
- **2024-12-19:** Initialized casting/registry.json with 6 agents (Lead, Forge, Remote Fixer, Rubber Duck, Sentinel, Ralph)
- **2024-12-19:** Commit 85d8c5e - Routing + registry foundation for squad orchestration

## Learnings

<!-- Append new learnings below. Each entry is something lasting about the project. -->

### 2026-04-20 - Doc-restructure audit (consumer-first directive)

- **Module consumption is clone-and-import, not PSGallery.** `AzureAnalyzer.psd1` has no `PrivateData.PSData` (no Tags/Uris/ReleaseNotes) and the GUID is a placeholder (`0e0f0e0f-…`). Any PSGallery push needs a real GUID rotation first.
- **`AzureAnalyzer.psm1` dot-sources four root-level `.ps1` files** (`Invoke-AzureAnalyzer`, `New-HtmlReport`, `New-MdReport`, plus globs `modules/**/*.ps1`). Moving any of those four into `src/` is a manifest-breaking change - keep them at root.
- **README is 493 lines / ~54 KB** with 30+ headings. Quickstart at line 9 but Prereqs at line 319 and Permissions at line 607 - consumers hit auth errors before they hit the docs that explain auth.
- **`docs/` already mixes audiences**: `ARCHITECTURE.md` + `CONTRIBUTING-TOOLS.md` + `proposals/` (contributor) sit beside `continuous-control.md` + `sinks/` + `ai-triage.md` + `gitleaks-pattern-tuning.md` (advanced consumer). A `consumer/` vs `contributor/` split is the natural cut.
- **Root pollution to fix**: `pester.log`, `retry.log`, `testResults.xml` are committed build artefacts. `report-template.html` (40 KB) is an internal renderer asset masquerading as a root doc - belongs in `templates/`.
- **5 `output*/` directories at repo root** - confirm intent before gitignoring.
- **`.gitattributes` already hides `.squad/` + squad workflows from archive zips** via `export-ignore` - so consumer-vs-contributor separation for archive consumers is partially done; the remaining gap is the rendered `docs/` tree on github.com.
- **Inbound link surface to redirect**: `docs/ARCHITECTURE.md`, `docs/CONTRIBUTING-TOOLS.md`, `docs/continuous-control.md`, `docs/sinks/log-analytics.md`, `docs/ai-triage.md`, `docs/gitleaks-pattern-tuning.md`. README links into all six; CHANGELOG history likely too. Stub-with-meta-refresh pattern is the safe play.

### 2026-04-21 - Azure-native UI patterns research (WARA + Sentinel)

- **WARA is a 3-stage pipeline:** Collector (JSON) → Analyzer (Excel `Expert-Analysis-*.xlsx`, 6 sheets) → Reports (PowerPoint + Excel + bulk CSV). Reports drives PPT via clipboard copy from Excel — hence the clipboard-history caveat in the README. Source: https://azure.github.io/Azure-Proactive-Resiliency-Library-v2/tools/.
- **WARA Excel "Impacted Resources Analysis" sheet** is the canonical recommendation row: `Resource Name`, `Resource Type`, `Recommendation Title`, `Impact (H/M/L)`, `Recommendation Control` (≈ pillar), `Potential Benefit`, `Learn More`, `Long Description`, `Notes`, `Platform Issue TrackingId`. Mirror this in our HTML report row layout.
- **WAF pillar colours** (Azure Portal Fluent palette): Reliability `#0078D4`, Security `#D13438`, Cost `#107C10`, Operational `#5C2D91`, Performance `#FF8C00`. Use for posture/recommendation pillar pills.
- **Defender XDR severity palette** is a different palette: High `#A80000`, Medium `#D83B01`, Low `#FFB900`, Informational `#0078D4`. Use for threat/incident pills. Two palettes intentionally — pillar colour conveys *category*, threat colour conveys *urgency*.
- **WARA wrapper bug:** `modules\Invoke-WARA.ps1` line 102 takes only `ImpactedResources[0]` and drops the count, breaking the impact×effort matrix derivation (effort = bucketed resource count). Fix: preserve `ImpactedResourceCount` as extras and emit one finding per impacted resource.
- **Sentinel KQL projection gap:** `modules\Invoke-SentinelIncidents.ps1` lines 102–116 does NOT project `Tactics`, `Techniques`, `AlertIds`, `RelatedAnalyticRuleIds`, `Comments`, `Labels`, `FirstActivityTime`, `LastActivityTime`. Adding these is single-line KQL changes per column and unlocks MITRE pills + entity chips + alert correlation in the report.
- **Sentinel `Detail` field is pipe-concatenated** (line 188) — should be structured extras so the renderer can lay them out spatially (chips/pills/timeline) instead of one wrapped string.
- **Severity mapping decision:** Sentinel emits 4 levels (High/Medium/Low/Informational), our schema is 5. Keep current 1:1 mapping (Sentinel High → our High, never our Critical) — Mapping B (promote High → Critical) inflates Sentinel relative to WARA and breaks cross-tool severity comparisons.
- **No `sentinel-coverage` fixture exists** under `tests\fixtures\` (only `sentinel-incidents-output.json`). Add one alongside the report rebuild.
- **Architectural recommendation:** Add a top-level "Action Plan" tab to the unified HTML report rendering the WAF impact × effort 3×3 matrix as a tool-agnostic priority view. Default landing = "Quick Wins" quadrant. Opt-in behind `-ShowActionPlan` until WARA effort-axis data is preserved.
- **Inbox file:** `.squad\decisions\inbox\lead-azure-portal-ui-patterns.md` (handed to Sentinel).

### 2026-04-21 - ETL gap analysis (scope expansion: end-to-end, not render-layer)

- **5-layer ETL contract** for any new wrapper field: L1 source capture (wrapper) → L2 normalizer (`Normalize-*.ps1`) → L3 schema (`New-FindingRow` typed param) → L4 EntityStore (entity-bound aggregates + Edges) → L5 report (render). A field is only "preserved" when it round-trips through every layer; render-layer-only fixes are insufficient.
- **`Add-Member -NotePropertyName … -Force` extras are deprecated.** Both Sentinel normalizers use this pattern (Normalize-SentinelIncidents.ps1 lines 76–80, Normalize-SentinelCoverage.ps1 lines 76–80). Any field worth rendering is worth promoting to a typed `New-FindingRow` parameter; Add-Member becomes a migration bridge only.
- **`New-FindingRow` Schema 2.1 additions proposed** (all optional, backward-compat): `Pillar`, `ImpactedResourceCount`, `ImpactScore`, `EffortScore`, `ServiceShortName`, `RemediationBenefit`, `MitreTactics[]`, `MitreTechniques[]`, `EntityRefs[]`, `RelatedFindingIds[]`, `Status`, `Classification`, `RelatedAlertCount`, `ProviderName`, `ExternalUrl`, `FirstActivityTime`, `LastActivityTime`, `RelatedAlertIds[]`, `Labels[]`, `TrackingId`. Schema's existing `RuleId` parameter (line 206) is currently unused by Sentinel coverage normalizer — promote `RuleId` extras to use it.
- **WARA L1 must read the .xlsx, not only the collector JSON.** `Pillar` (Recommendation Control), `PotentialBenefit`, and `Status` (Reviewed/Pending) live only in the Analyzer-stage `Expert-Analysis-*.xlsx` Action Plan sheet. `ImportExcel` module is already a WARA transitive dependency — no new install needed. Decision: invoke both `Start-WARACollector` AND `Start-WARAAnalyzer` (~30s extra per assessment).
- **WARA wrapper bug confirmed:** `modules\Invoke-WARA.ps1` line 102 takes `ImpactedResources[0]` only — N–1 resources lost per recommendation. Fix: emit one finding per impacted resource so EntityStore can attach each to its own AzureResource entity.
- **WARA wrapper bug 2:** line 111 sets `Remediation` and `LearnMoreUrl` to the same value (`rec.LearnMoreLink`). They are distinct fields on the source — `Remediation` should come from `rec.Remediation` / `rec.Description.Steps`.
- **Sentinel KQL projection gap (single-line per column):** `modules\Invoke-SentinelIncidents.ps1` lines 102–116 doesn't project `Tactics`, `Techniques`, `AlertIds` (currently only counted), `RelatedAnalyticRuleIds`, `Comments`, `Labels`, `FirstActivityTime`, `LastActivityTime`. Adding them is mechanical; entity refs require a second KQL join to `SecurityAlert.Entities`.
- **Sentinel coverage gap:** `properties.tactics[]` and `properties.techniques[]` exist on every `Microsoft.SecurityInsights/alertRules` REST response but the wrapper doesn't capture them. Without them, the workspace-level MITRE coverage matrix (the §2.3 heatmap) cannot be rendered.
- **EntityStore v3.1 additive fields:** `Pillars[]`, `MitreCoverage[]`, `EntityRefsInbound[]` (Edges from incidents to user/host/ip entities), `EffortScoreSum`, `ImpactScoreMax`, `IncidentStatusDistribution`. Same workspace entity collects MITRE coverage from analytic rules (intent) AND from incident findings (outcome) → enables a coverage-vs-detection delta heatmap as the headline Sentinel visual.
- **PR sequencing:** 7-step plan that respects the Issue-First Workflow Directive — (1) Schema 2.1 additive params, (2) WARA wrapper xlsx + ImpactedResources fix, (3) Sentinel-incidents KQL + entity join, (4) Sentinel-coverage MITRE capture, (5) EntityStore v3.1 aggregates, (6) Report MITRE + Action Plan tabs, (7) Add-Member cleanup. Each step independently mergeable behind the standard 3-model gate; Pester baseline (842/842) must stay green.

### 2026-04-22 - Report UX arc complete — briefs merged, per-tool issues filed

- Brief merged to `decisions.md`. Schema 2.2 contract locked (#299 umbrella). Per-tool ETL issues filed: #308 (WARA), #309 (Sentinel Incidents), #310 (Sentinel Coverage).
- WARA bugs confirmed: ImpactedResources[0] truncation (#308) + Remediation/LearnMoreUrl aliasing (#308).
- Sentinel KQL projection gaps documented — 7 missing columns are single-line KQL additions per column.
- Two-palette severity approach ratified: WAF pillar colors for posture, Defender colors for threats.
