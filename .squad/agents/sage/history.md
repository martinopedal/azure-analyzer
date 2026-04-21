# Project Context

- **Owner:** martinopedal
- **Project:** ALZ Additional Graph Queries - Research and tool ecosystem scouting
- **Stack:** Web research, GitHub API, Microsoft Learn, public tool evaluation
- **Created:** 2026-04-14

## Learnings

<!-- Append new learnings below. Each entry is something lasting about the project. -->

### 2026-04-20 - Consumer-first PowerShell module layout
- Researched 6 reference repos (PSRule for Azure, Pester, PSReadLine, ImportExcel, MS Graph PS SDK, AVM Bicep) plus SecretManagement as anti-example.
- Distilled README skeleton: tagline → badges → install → quick start → scenarios → docs link → contributing (1 paragraph) → license.
- Key GitHub mechanic: `CONTRIBUTING.md`, `SECURITY.md`, `CODE_OF_CONDUCT.md` are auto-detected ONLY in `{.github/, root, docs/}` (priority `.github/` first). Moving them anywhere else breaks the GitHub "Contributing" tab + PR-form link. Source: GitHub Docs community-health-files page.
- `LICENSE` and `CHANGELOG.md` MUST stay at root - `LICENSE` for GitHub's license detector, `CHANGELOG.md` because PSGallery `ReleaseNotes` typically links there.
- PSGallery package page is driven entirely by `PrivateData.PSData` (ProjectUri/LicenseUri/IconUri/ReleaseNotes/Tags) + manifest root fields. Source: learn.microsoft.com/powershell/gallery/concepts/package-manifest-affecting-ui.
- **azure-analyzer's `AzureAnalyzer.psd1` has NO `PrivateData.PSData` block at all** - must be added before first PSGallery publish or the package page will be a dead-end.
- **Placeholder GUID** in `AzureAnalyzer.psd1` (`0e0f0e0f-…`) must be regenerated before first publish.
- Restructure must include a grep-audit of hardcoded doc paths in `*.ps1`, `*.psm1`, `*.yml`, `*.md` and a `CODEOWNERS` audit - same-PR or it silently breaks.
- Brief delivered to `.squad/decisions/inbox/sage-consumer-module-patterns-2026-04-20T12-17-17Z.md`.

### 2026-04-21 - Report UX outside-in audit (sample-report.html discoverability + industry references)
- `samples/sample-report.html` (36KB) exists alongside `sample-report.md`, `sample-results.json`, `sample-findings-v2.json`, `sample-entities.json`, `sample-tool-status.json` - rich asset set, all unlinked.
- Zero links from `README.md` or `docs/consumer/README.md` to the samples directory. Only mentions: `CHANGELOG.md:185` (historical entry from when previews lived in README, since removed) and `docs/contributor/proposals/copilot-triage-panel.md` (lines 32, 657) which presupposes a sample-report.html link in README that no longer exists.
- Neither README has a "What does the output look like?" section. README line 62 describes the report textually but never points at the rendered sample.
- Industry references captured: AzGovViz (HierarchyMap tree + TenantSummary tabs + DataTables), azqr (multi-sheet Excel: Recommendations / ImpactedResources / ResourceTypes / Inventory), Powerpipe (benchmark dashboards + relationship diagrams + sankey), Prowler (HTML compliance dashboard).
- Heat-map recommendation: severity x resource-group already exists; the missing high-value heatmap is **control-domain x subscription** (CAF/WAF pillar coverage gap analysis) - this is what AzGovViz "TenantSummary" and Defender Compliance Manager both lean on.
- Brief written to `.squad/decisions/inbox/sage-report-ux-references.md`.

### 2026-04-21 - Report UX deep-dive v3 (azqr/PSRule/Defender/Prowler/Powerpipe visual specifics)
- Scope re-coordinated: Maester deferred to Iris, AzGovViz deferred to Atlas (parallel inbox briefs in flight).
- azqr taxonomy locked: 3-level Impact (High/Medium/Low only — no Critical/Info), 7 Categories (HighAvailability, DisasterRecovery, MonitoringAndAlerting, Security, Governance, Scalability, OtherBestPractices). Excel palette extracted: `#C00000` / `#ED7D31` / `#FFC000` / `#70AD47` / `#A6A6A6` with WCAG ratios noted.
- PSRule for Azure: 5 WAF pillars (Cost / Operational Excellence / Performance Efficiency / Reliability / Security) — adopt verbatim as our heat-map row axis; do not invent custom names.
- PSRule baseline pattern: borrow as `Save as Baseline` button to persist filter chips into localStorage / URL fragment — fixes a real gap in our report.
- Defender Secure Score gauge: 80px radius, 24px stroke, conic-gradient implementable in CSS (zero JS), thresholds `>=67%` green / `34-66%` amber / `<=33%` red. Direct evolution path from our existing donut.
- Defender Compliance split-bar cell `140x32px`, three segments green/red/grey — gold-standard pattern for our Subscription x WAF-Pillar heat map.
- Prowler severity pill CSS captured copy-paste-ready; 7-level severity (Critical/High/Medium/Low/Info/Pass/Muted) with verified WCAG contrast ratios per pair.
- Powerpipe KPI card spec captured: `240x96px min`, 12px uppercase label / 36px value / 12px delta arrow.
- Brief v3 written to `.squad/decisions/inbox/sage-report-ux-references.md` (now 25KB+, three sections: original Part B v2 + Part B+ deep-dive + cross-refs to Iris/Atlas briefs).

### 2026-04-21 - Report UX v4: ETL gaps end-to-end (azqr/PSRule/Defender/Prowler/Powerpipe)
- Read actual code at: `modules/Invoke-{Azqr,PSRule,DefenderForCloud}.ps1`, all three normalizers, `Schema.ps1` (v2.1), `EntityStore.ps1`.
- **PSRule wrapper bug found**: `Invoke-PSRule.ps1` hardcodes `Severity = 'Medium'` for every finding (line ~75) — every PSRule finding renders as Medium in the report regardless of actual rule level. Trivial fix, big signal improvement.
- **azqr wrapper limitation**: dumps raw JSON files into Findings array without field-aware projection — RecommendationId, WAF Pillar tags, Effort all dropped at the wrapper layer.
- **Defender wrapper limitation**: only calls 2 of 3 relevant Microsoft.Security endpoints — the regulatoryCompliance* API (CIS/PCI/NIST/SOC2/ISO mappings) is not invoked at all. Score numerics ride on Add-Member orphans (don't survive cross-tool merge).
- **Prowler / Powerpipe**: no wrappers exist — table is target-shape only. Recommend Prowler-when-bundled, Powerpipe-never (use visuals only).
- **v2.2 schema bump designed**: single PR adds 11 optional fields (Impact, Effort, Pillar, DeepLinkUrl, Frameworks[], BaselineTags[], RemediationSnippets[], EvidenceData, ScoreCurrent, ScoreMax, ScorePercent, ScoreDelta) — all back-compat with existing 842 Pester tests.
- **Cross-tool merge requirement**: `Merge-FrameworksUnion` / `Merge-BaselineTagsUnion` helpers needed in EntityStore so that Prowler+PSRule+azqr CIS-Azure tags on the same finding union rather than last-write-wins.
- 6-PR sequencing recommended in brief (XS bug fix → schema → 3 tool PRs → report consumption).

### 2026-04-22 - Tool manifest upstream-pointer audit (complete: 30/33 clean)
- Audited all 33 tools in `tools/tool-manifest.json` for ALZ-class wrong-upstream bugs after Atlas's `alz-queries` migration.
- 15 tools have `upstream` blocks; 18 do not (Az PS-module-only or REST-only tools).
- Only 🔴 found: `alz-queries` itself (already in flight). No second instance of a fundamentally wrong upstream pointer.
- Two 🟡 findings on the `alz-queries` and `falco` install blocks — both documentation/completeness, not wrong pointers. Falco install-mode quietly depends on `helm` + `kubectl` not declared in the manifest install block.
- Verified WARA pointer is correct: the `WARA` PSGallery module is published from `Azure/Azure-Proactive-Resiliency-Library-v2`, not the v1 archive — easy mistake to flag as stale, but it's right.
- Verified AzGovViz upstream rename (`…-Generator` → `…-Reporting`) is already reflected in the manifest.
- Deliverable: `.squad/decisions/inbox/sage-tool-upstream-audit.md`.

### 2026-04-22 - Report UX arc: briefs merged, Schema 2.2 locked

- All briefs merged to `decisions.md`. ETL gap tables preserved. Per-tool issues filed: #300 (azqr), #301 (PSRule), #302 (Defender), #303 (Prowler), #304 (Powerpipe).
- Schema 2.2 contract locked (#299): 13 new optional fields including `Frameworks`, `Pillar`, `Impact`, `Effort`, `DeepLinkUrl`, `BaselineTags`, `RemediationSnippets`, `EvidenceUris`.
- PSRule severity-hardcode bug (#301) confirmed as highest-leverage quick fix — single-line change, instant signal improvement.
- Heat-map default ratified: Control-Domain x Subscription (WAF Pillar axis).
