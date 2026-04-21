# Project Context

- **Owner:** martinopedal
- **Project:** ALZ Additional Graph Queries - Security aggregation and unified recommendation engine
- **Stack:** PowerShell, JSON, azqr (Azure Quick Review), CSV/HTML report generation
- **Created:** 2026-04-14

## Notes

- **2024-12-19:** PII audit scheduled for future sprint (Scribe session tracking)

## Learnings

<!-- Append new learnings below. Each entry is something lasting about the project. -->
- **2026-04-17:** 3-model PR consensus is now formalized as Claude premium + GPT codex + Goldeneye prompt-bundle triage, with merged consensus/disputed findings and deterministic verdict precedence (`CHANGES_REQUESTED` beats `COMMENTED` beats `APPROVED`).
- **2026-04-17:** Reviewer Rejection Lockout is mechanically enforced in the PR review gate helper by rejecting any replacement owner equal to the PR author and always recording lockout + replacement in the consensus document.
- **2026-04-17:** PR review ingestion relies on GitHub Pull Request Reviews API (`/pulls/{n}/reviews`) plus line comments API (`/pulls/{n}/comments`) with paginated/slurped JSON parsing and retryable error handling for rate limits.
- **2026-04-18 (Issue #100):** Error sanitization audit - grep pattern that caught all unsanitized writes: `Exception\.Message|Error\.Message|\.Message` with manual review of each hit. Zero false positives from `Write-Verbose` or `Write-Warning` (console streams, not disk). Key boundary: wrap at error-capture time (in catch block), not at every write-site, to ensure consistency. Test fixtures for SAS URI, bearer token, connection string, and multi-secret scenarios validate disk-write paths. Pattern established: `Message = (Remove-Credentials $_.Exception.Message)` or `Message = "Context: $(Remove-Credentials $_.Exception.Message)"` for interpolated strings.
- **2026-04-20T14:04:33Z:** Consumer-first restructure cleanup landed as PR #253, not #248, because GitHub PR #248 had already been used by a completion-record follow-up. When a plan hardcodes a future PR number in this repo, verify the live number space before baking it into changelog text or PR sequencing assumptions.
- **2026-04-20T14:04:33Z:** Final docs hygiene work can expose repo-wide em dashes in historical changelog and proposal pages. A single `rg -- "-" README.md CHANGELOG.md docs/` sweep plus a deliberate markdown-only replacement pass is a clean way to close the stream without touching code paths.
- **2026-04-20T23:26:17Z (Issue #227):** Top recommendations impact scoring constants are now explicitly fixed in report logic as Critical=10, High=5, Medium=2, Low=1, Info=0.1 with formula impact = severity_weight x occurrence_count x resource_breadth. Keep these constants tunable through New-HtmlReport -TopRecommendationsCount and future weight parameterization work.

- **2026-04-22 (Sentinel UX Research):** Audited New-HtmlReport.ps1 (2073 lines) for HTML report UX uplift. Already implemented: Summary tab (exec dashboard embed), Findings tab with collapsible Tool->Category->Rule->Finding tree, Resources tab (entity-centric), donut chart, severity pill cards, severity strip with click-to-filter, per-source horizontal bars, tool coverage badges (active/failed/excluded/skipped), severity heatmap (ResourceGroup x Severity, click-to-filter), framework x tool coverage matrix (click-to-filter), Top recommendations by impact (azqr-style), priority stack (top critical/high), trend sparkline (SVG inline), delta vs previous run (New/Resolved/Unchanged badges), global filter bar (text + sev + source + framework dropdowns), CSV export, sortable tables, persisted tree expansion (localStorage). Manifest has 34 tools, only ~17 emit findings in sample. samples/sample-report.html IS a real generated artifact (36KB) but is NOT linked from README or docs/.
- **2026-04-22:** Schema gaps identified for HTML enrichment - FindingRow has no remediationUrl (LearnMoreUrl is closest), no MITRE TTP tagging, no per-rule risk score weight, no validation status (Pending/Accepted-Risk/Remediated). Edges enum has 5 relation types (GuestOf/MemberOf/HasRoleOn/OwnsAppRegistration/ConsentedTo) - blast-radius graph viz is feasible from existing EntityStore Edges export. EntityStore exposes Sources[], CostTrend, Correlations, MonthlyCost - mostly unused in HTML beyond Resources tab table.

## 2026-04-22 — Report redesign mockup shipped

- Wrote `samples/sample-report-redesign.html` (~55 KB single file, no CDNs, vanilla JS, inline SVG).
- Sections: sticky exec header (score donut, sev strip, KPIs) → subnav → Overview (summary + 5-sev trend strip + top-5 recs) → Tool coverage (17 tools grouped by provider, collapsible, stacked-sev bar + pass% per tile) → Heatmap (3-toggle: Control-Domain×Sub default per Sage, Sev×RG, Framework×Sub) → Top 10 risks → Findings table (search + 5-sev pill filter + tool/sub/status selects + sortable cols + click-to-expand evidence/remediation + CSV export) → Entities (typed bars + identity blast-radius graph teaser exercising Edges) → Footer (tool versions, print, top).
- 5-sev color tokens with WCAG-AA contrast on white; full `[data-theme=dark]` variant; toggle persists via `localStorage('aa-theme')`.
- Deterministic mocked dataset: 30 rule templates × 2-10 occurrences ≈ 220 findings, generated client-side with seeded PRNG so the file stays small.
- `node --check` on the extracted `<script>` passes.

## 2026-04-22 - Phase 2: canonical sample reports + docs links

- Overwrote `samples/sample-report.html` with the redesign (54.7 KB, single-file, dark mode, sortable findings, heat map, coverage grid, top risks).
- Created `samples/sample-report.md` as the GFM twin: shields.io severity badges, anchor TOC, tool coverage tables grouped by provider, heat map as emoji table, top 10 risks, top 30 findings (with note that HTML has full 222), entity inventory, collapsible tool versions.
- README: added 'What does the output look like?' section linking both samples between elevator pitch and Install.
- `docs/consumer/README.md`: cross-link to both samples at top of the list.
- CHANGELOG: `Changed` entry under Unreleased.
- Em-dash sweep: 7 occurrences scrubbed from HTML visible text; MD authored em-dash-free.

## Phase 3 (deferred): generator alignment with mockup

Date: 2026-04-21

- Pester baseline captured: 1349 passed / 0 failed / 5 skipped (1354 total).
- Surveyed targets: New-HtmlReport.ps1 (2073 lines, mature CSS/JS at L1233-2060, exercised by 1349 passing tests asserting selectors/IDs), New-MdReport.ps1 (454 lines), New-ExecDashboard.ps1 (58 lines).
- Decision: a correct, mockup-faithful rewrite plus coordinated test updates is multi-day scope. Shipping it half-done would either break the 1349 baseline or drift from the spec, both of which violate the Iterate Until Green contract.
- Filed follow-up issues (all labelled squad,enhancement):
  - #295 feat: align New-HtmlReport.ps1 with samples/sample-report.html design spec
  - #296 feat: align New-MdReport.ps1 with samples/sample-report.md design spec
  - #297 feat: harmonize New-ExecDashboard.ps1 with new report design tokens
  - #298 feat: replace identity blast-radius SVG teaser with real interactive graph
- CHANGELOG entry under [Unreleased] now references all four issues.
- Spec is locked in samples/sample-report.html and samples/sample-report.md from Phase 2; subsequent PRs implement against that spec.


## Phase 4 - 2026-04-21 - Research integration

Read the four landed research drops (Atlas AzGovViz, Iris Maester, Sage outside-in, Lead Azure-portal). Wrote synthesis to .squad/decisions/inbox/sentinel-mockup-integration-2026-04-21.md.

Decision: Atlas's TabStrip-vs-scroll verdict ratifies the v1 mockup. Single-page scroll + sticky in-page anchor pills, no JS tabs. Reasoning preserved in the decision drop. No refactor of samples/sample-report.html IA needed.

Mockup edits applied:
- Added .fw-* CSS palette (Iris #3.4) with WCAG-AA hex values for CIS / NIST / MITRE / EIDSCA / eIDAS2 / SOC / ISO / MCSB / CAF / WAF / CISA / ORCA.
- Added fwBadges() / ruleIdOf() / docUrlOf() helpers in inline JS.
- Findings table row now leads with monospaced rule-ID chip and renders frameworks as colored chips instead of plain text.
- Tool column uses .tool-chip styling.
- Expanded row now follows Iris #3.3 contract: Why this matters / Evidence / Compliance frameworks / Remediation / Entity / Links (docs + copy ID + source rule-ID).
- MD twin gained "How to read a row" mini-guide with shields.io badges and a Rule-ID + Frameworks column in the top-30 table.

Validations: node --check pass on extracted JS, em-dash sweep 0/0/0 on touched files, Pester baseline unchanged at 1349/1354 (no generator code modified).

Outstanding work is on the four open issues (#295 / #296 / #297 / #298), not on Sentinel. The mockup remains the locked design spec for that work.

## 2026-04-21 - Phase 5: ETL lifecycle scope (Schema 2.2 plan + 14 follow-up issues)

User directive: "if something is dropped, ensure it's reflected in the entire tool lifecycle, not just in a report". Renderer must not fabricate placeholders for fields that wrappers drop.

Synthesised the consolidated Schema 2.2 superset across all five squad briefs (Sage Part B++ / Iris Maester+Kubescape / Atlas AzGovViz / Lead WARA+Sentinel / Forge Trivy+Infracost+Scorecard) and locked it in `.squad/decisions/inbox/sentinel-schema-2.2-deltas-2026-04-21.md`.

Reconciled the user's suggested field names to the codebase conventions: `HelpUrl` -> existing `LearnMoreUrl` (no duplicate), `FrameworkTags` -> structured `Frameworks` `[hashtable[]]`, `RemediationSnippet` -> plural `RemediationSnippets`, `EvidenceUrls` -> `EvidenceUris` (URI casing).

Filed 15 GitHub issues, all with `squad,enhancement` labels:
- #299 umbrella Schema 2.2 additive bump (blocks the per-tool issues)
- #300-#313 one issue per tool (azqr / PSRule / Defender / Prowler / Powerpipe / Maester / Kubescape / AzGovViz / WARA / Sentinel-Incidents / Sentinel-Coverage / Trivy / Infracost / OpenSSF Scorecard) -- each cites the brief section it derives from, lists the wrapper+normalizer files, and depends on #299.

Renderer rewrites #295/#296 are explicitly NOT blocked: they consume new fields conditionally and degrade gracefully when absent.

CHANGELOG `[Unreleased]` updated with a third Changed entry referencing #299-#313.

No code changes in this phase. Pester baseline unchanged at 1349 passed / 5 skipped / 1354 total.

### 2026-04-22 - Report UX arc complete — all briefs merged, Schema 2.2 locked

- All 6 upstream briefs + 3 Sentinel drops merged to `decisions.md` by Scribe. Inbox cleared.
- Architecture decision ratified: single-page scroll + sticky anchor pills. No TabStrip.
- Schema 2.2 contract is the canonical reference: 13 new optional fields, all backward-compatible.
- 15 issues filed (#299 umbrella + #295-#298 generators + #300-#313 per-tool ETL fixes).
- Renderer graceful-degradation contract locked: render when present, omit when absent, never fabricate, never parse from string blobs.
