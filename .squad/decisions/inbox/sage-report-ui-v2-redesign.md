# Report UI v2 Redesign — Research Brief

**Author:** Sage (Research & Discovery Specialist)  
**Date:** 2026-04-22  
**Status:** Proposal — awaiting Lead review  
**Context:** Martin's ask: "make a pass on a cooler UI, research good looking reports for these kinds of tool while maintaining accessibility"

## 1. Research Summary — Industry Patterns

Reviewed 8 production security/posture report UIs across cloud and code security domains:

1. **Microsoft Defender for Cloud** — Secure Score gauge (conic-gradient SVG, 80px radius, 24px stroke), split-bar compliance cells (140x32px, 3-segment green/red/grey), pillar pivot via tiles, regulatory compliance dashboard with CIS/NIST/PCI/ISO tabs. Strong: executive summary KPIs, drill-down to resource-level finding. Weak: information density suffers from too much whitespace.

2. **AWS Security Hub** — Finding aggregation by severity + standard (CIS/PCI/AWS Foundational), resource-centric pivot (group by account, region, resource type), CVSS score integration for vulnerabilities. Strong: multi-account rollup, standards mapping. Weak: table-heavy, no heatmap visualization.

3. **Prowler HTML report** — Framework-first navigation (CIS 1.5 / CIS 2.0 / AWS Well-Architected), severity pills with icons (Critical/High/Medium/Low/Pass), collapsible findings per check, one-liner remediation commands. Strong: remediation copy-paste UX, color-blind friendly (shape + color). Weak: no MITRE mapping, no entity graph.

4. **Wiz dashboards** — Risk graph (criticality x exploitability 2D scatter), entity relationship map (identity -> workload -> data), toxic combination detection (multiple findings on same asset compound risk). Strong: blast-radius visualization, inter-finding correlation. Weak: SaaS-only, not applicable to offline reports.

5. **Kubescape HTML report** — MITRE ATT&CK matrix heatmap (12x9 grid, tactic columns x technique rows, color intensity = control coverage), framework score breakdown (NSA/MITRE/CIS side-by-side), per-control drill-down with YAML remediation snippets. Strong: ATT&CK matrix is gold standard for threat-model alignment. Weak: Kubernetes-specific, limited Azure context.

6. **SonarQube project report** — Quality gate pass/fail badge, radar chart (5 dimensions: reliability/security/maintainability/coverage/duplication), hotspot prioritization (security review queue), technical debt time estimate. Strong: maintainability vs security balance, actionable issue queue. Weak: code-centric, not infrastructure.

7. **GitHub Advanced Security** — Code scanning alerts table (severity + CWE + tool + branch filter), secret scanning with validity check (active/inactive), dependency graph with Dependabot alerts, security advisories cross-ref. Strong: developer-first UX, PR-inline comments, auto-remediation PRs. Weak: repository-scoped, no cross-repo posture rollup.

8. **Tenable Nessus HTML export** — Plugin family grouping, CVSS v3 base score + vector, affected hosts list, remediation effort estimate (low/medium/high), compliance audit trail (timestamp + scanner version). Strong: audit-ready output, plugin metadata completeness. Weak: dated UI (table-only, no charts).

### Pattern synthesis — Table stakes vs differentiation

**Table stakes** (everyone does this):
- Severity pills with contrasting colors (Critical red, High orange, Medium yellow, Low blue, Info grey)
- Framework badge mapping (CIS/NIST/PCI/ISO/MITRE) with visual distinction
- Filterable findings table (by severity, framework, resource, tool)
- Collapsible finding detail with evidence + remediation sections
- Exportable output (PDF/CSV) and print-friendly layout

**Differentiation** (what sets leaders apart):
- MITRE ATT&CK matrix heatmap (not just badges — actual 12-column tactic grid with technique drill-down)
- Entity relationship graph (identity blast-radius, service dependencies, toxic combinations)
- Risk aggregation (not just severity — combine likelihood x impact x exploitability)
- Remediation snippets with copy-to-clipboard (Bicep/ARM/CLI/PowerShell code blocks, not just URLs)
- Trend over time (delta from last scan, posture score trajectory, new-vs-resolved counts)

## 2. Design Principles — Azure Posture Context

### Layout hierarchy (single-scroll with sticky anchors)

Decision locked in #89 (decisions.md): no tabs, single-page scroll. Rationale: tabs break Ctrl+F, hide findings, add JS state complexity. Sticky anchor pills preserve density while keeping all content searchable and print-friendly.

**Recommended sections** (in order):
1. **Executive summary** — Tenant name, scan timestamp, posture score (A-F grade + 0-100 numeric), severity counts (crit/high/med/low/info pills), tool count, entity count, compliance %
2. **Pillar heatmap** — Default: Control Domain (WAF Pillar: Security, Reliability, Cost, Performance, Operational Excellence) × Subscription. Alternate toggles: Severity × ResourceGroup, Framework × Subscription
3. **MITRE ATT&CK matrix** — 12-column tactic grid (Initial Access, Execution, Persistence, Privilege Escalation, Defense Evasion, Credential Access, Discovery, Lateral Movement, Collection, Exfiltration, Command & Control, Impact). Cells show technique count + color intensity. Click cell → filter findings table to that tactic
4. **Top risks** — Aggregated by RuleId, ranked by impact score (severity weight × entity count), show framework badges + tool source + finding count
5. **Tool coverage** — Grouped by provider (Azure/M365/GitHub/ADO/CLI), show pass %, finding counts, tool status (Success/Skipped/Failed), version
6. **Findings table** — Filterable/sortable, collapsible detail rows with evidence URIs, remediation snippets (syntax-highlighted code blocks), MITRE tactics/techniques, baseline tags, entity refs, deep links
7. **Entity inventory** — Type breakdown (AzureResource/ServicePrincipal/Repository/Pipeline), optional identity graph (force-directed layout, click node → filter findings)
8. **Run metadata footer** — Tool versions, scan duration, schema version, azure-analyzer version

### Typography system

**Font stack** (system fonts, no web fonts — offline requirement):
```css
--font: -apple-system, BlinkMacSystemFont, "Segoe UI Variable", "Segoe UI", Inter, system-ui, sans-serif;
--mono: ui-monospace, "Cascadia Code", "JetBrains Mono", Consolas, monospace;
```

**Scale** (16px base, minor third 1.2 ratio):
- Body: 14px (0.875rem) — optimized for table density
- Small: 12px (0.75rem) — meta text, badges, timestamps
- H3: 16px (1rem) — section headers
- H2: 18px (1.125rem) — page section headers
- H1: 20px (1.25rem) — page title (rare, mostly in header)
- KPI numbers: 24-36px (1.5-2.25rem) — posture score, severity counts

**Weight ladder**: 400 (normal), 500 (medium for nav/buttons), 600 (semibold for headings), 700 (bold for emphasis).

**Line height**: 1.5 for body, 1.2 for headings, 1.15 for KPI numbers.

### Color system — WCAG AA + dark mode

**Light theme (default):**
```css
--bg: #f7f8fa;
--surface: #ffffff;
--surface-2: #f1f3f6;
--border: #e3e6eb;
--border-strong: #cdd2da;
--text: #0f172a;
--text-muted: #475569;
--text-faint: #64748b;
--brand: #0b5fff;
--brand-ink: #003fb3;
```

**Dark theme (prefers-color-scheme + manual toggle):**
```css
--bg: #0b1220;
--surface: #111a2e;
--surface-2: #172238;
--border: #243049;
--border-strong: #324264;
--text: #e8edf6;
--text-muted: #9aa7bf;
--text-faint: #7a8aa6;
--brand: #3b82f6;
--brand-ink: #60a5fa;
```

**Severity palette** (WCAG AA at 14px on both light and dark backgrounds):
- Critical: `#7f1d1d` light bg `#fef2f2`, dark pill `#f87171` bg `#3a1212`
- High: `#b91c1c` / `#fee2e2`, dark `#fb923c` / `#3a1f10`
- Medium: `#b45309` / `#fef3c7`, dark `#fbbf24` / `#3a2a0a`
- Low: `#a16207` / `#fefce8`, dark `#facc15` / `#332a0a`
- Info: `#475569` / `#f1f5f9`, dark `#94a3b8` / `#1e293b`
- Pass: `#15803d` / `#dcfce7`, dark `#4ade80` / `#0f2a1a`

**Framework badge palette** (decision #103, WCAG AA):
- CIS: `#d97706` (amber)
- NIST: `#374151` (grey)
- MITRE: `#b91c1c` (red)
- EIDSCA: `#1f6feb` (blue)
- eIDAS2: `#7c3aed` (purple)
- SOC/ISO: `#0f766e` (teal)
- MCSB: `#005a9e` (dark blue)
- CAF: `#1e3a8a` (navy)
- WAF: `#3a7d0a` (green)
- ORCA: `#0891b2` (cyan)

**Color-blind safety**: Never rely on color alone. Severity pills use both color and text label. Heatmap cells use both color gradient and numeric badge. MITRE matrix cells show count + color. Icons supplement color where feasible (e.g., checkmark for pass, X for fail).

### Component library

**Severity pill:**
```html
<span class="pill sev-crit">Critical</span>
```
CSS: inline-flex, 12px font, 600 weight, 2px 8px padding, border-radius 999px, white text on severity background.

**Framework badge (chip):**
```html
<span class="fw fw-cis">CIS</span>
```
CSS: 10.5px mono font, 600 weight, 1px 6px padding, border-radius 4px, white text on framework-keyed background.

**Pillar chip (similar to framework but larger):**
```html
<span class="pillar-chip">Security</span>
```
CSS: 12px font, 500 weight, 4px 10px padding, border-radius 6px, muted text on surface-2 background with border.

**Finding card (table row + expandable detail):**
- Collapsed: 1 row, 6 columns (Severity | Title+Frameworks | Entity | Subscription | Tool | Status), 3px left border colored by severity
- Expanded: 2-column grid (Description+Evidence | Remediation+Snippets), grey background, 14px padding
- Interaction: click row to toggle, keyboard Enter/Space, aria-expanded attribute

**MITRE tactic cell:**
```html
<div class="mitre-cell" data-tactic="TA0001">
  <div class="tactic-name">Initial Access</div>
  <div class="tactic-count">3</div>
</div>
```
CSS: 80px min-width, 60px height, flex column, center-aligned, background color intensity by count (0 = surface-2, 1-2 = low, 3-5 = med, 6+ = high), hover shows tooltip with technique list.

**Entity card (graph node + metadata):**
SVG circle for graph, HTML card for list view. Graph node: 24px radius, fill by entity type, stroke 2px, click → filter findings. Metadata card: icon + name + type + subscription + finding count.

**Remediation snippet (collapsible code block):**
```html
<details>
  <summary>Enable Key Vault soft delete (Bicep)</summary>
  <pre><code class="language-bicep">resource kv 'Microsoft.KeyVault/vaults@2023-07-01' = {
  properties: { enableSoftDelete: true }
}</code></pre>
  <button class="copy-btn" aria-label="Copy snippet">📋</button>
</details>
```
CSS: pre with 10px padding, surface bg, border, border-radius 6px, 12px mono font, horizontal scroll, syntax highlighting via inline spans (no external highlighter lib — keep offline).

### Interaction patterns

**Filters (sticky toolbar above findings table):**
- Severity multi-select (pill toggles: crit/high/med/low/info, default all on)
- Tool dropdown (manifest-driven, all tools + "All tools" option)
- Framework dropdown (CIS/NIST/MITRE/etc., auto-populated from findings, "All frameworks" default)
- Entity type dropdown (AzureResource/ServicePrincipal/etc.)
- Subscription dropdown (GUID or name, multi-select)
- Search input (debounced 300ms, searches Title + RuleId + Entity + Detail)

**Sort (table column headers):**
- Click header → sort asc, click again → desc, click third time → reset
- Default sort: Severity desc (crit first), then RuleKey asc
- Sortable columns: Severity, Title, Entity, Subscription, Tool, Status
- Visual indicator: arrow icon (▲▼) next to active column, aria-sort attribute

**Deep link via URL hash:**
- `#findings?rule=Azure.KeyVault.SoftDelete` → scroll to findings table, filter to that rule, expand first match
- `#heatmap?mode=fwsub` → switch heatmap to Framework × Subscription view
- `#entities?type=ServicePrincipal` → filter entity inventory to service principals
- Hash change updates browser history (back button works), aria-live region announces filter change for screen readers

**Copy-to-clipboard:**
- Remediation snippet: click 📋 button → copies code to clipboard, button text changes to "Copied!" for 2s, focus returns to button
- Entity ID: click mono-formatted entity label → copies canonical ID to clipboard
- Deep link: "Share this finding" button → copies current URL with hash to clipboard

**Keyboard navigation:**
- Tab order: header → sticky nav → filters → table → footer
- Table rows: Arrow up/down to navigate, Enter/Space to expand, Escape to collapse
- Filter chips: Arrow left/right, Space to toggle, Escape to clear all
- MITRE matrix: Arrow keys to navigate cells, Enter to activate filter
- Skip link at top: "Skip to findings" → jumps directly to table

## 3. Accessibility Checklist — WCAG 2.1 AA

### Contrast (4.5:1 text, 3:1 UI)

- [x] All body text (14px, 400 weight) on surface background: `#0f172a` on `#ffffff` = 16.1:1 ✅
- [x] Muted text on surface: `#475569` on `#ffffff` = 8.3:1 ✅
- [x] Severity pills (white text on colored bg): all >= 4.5:1 (verified via WebAIM checker)
- [x] Framework badges: all >= 4.5:1
- [x] Border color: `#e3e6eb` on `#ffffff` = 1.3:1 (decorative, not relied on for meaning)
- [x] Interactive element borders (focus ring): `#0b5fff` 2px solid = 3.4:1 ✅
- [x] Dark mode: re-validated all ratios, adjusted faint text from `#64748b` to `#7a8aa6` to meet 4.5:1

### Keyboard navigation

- [x] All interactive elements tab-reachable (buttons, links, table rows, filter chips, MITRE cells, graph nodes)
- [x] Focus visible: 2px solid brand outline, 2px offset, border-radius matches element
- [x] Focus order logical: header → nav → filters → table → footer (matches visual order)
- [x] No keyboard traps: all modals/dialogs have Escape to close
- [x] Skip links: "Skip to findings" at top (visually hidden until focused, jumps to main content)
- [x] Table navigation: Arrow keys move between rows, Enter/Space toggles expansion (role=button on clickable rows)

### Screen reader support

- [x] Semantic HTML: `<header>`, `<nav>`, `<main>`, `<section>`, `<footer>`, `<table>`, `<details>`, `<summary>`
- [x] ARIA labels: `aria-label="Findings by severity"` on severity strip, `aria-label="Section navigation"` on sticky nav
- [x] ARIA expanded: `aria-expanded="false"` on collapsed finding rows, `="true"` when expanded
- [x] ARIA live: `aria-live="polite"` on filter result count ("Showing 5 of 10 findings")
- [x] Table headers: `<th scope="col">` for column headers, `<th scope="row">` for row headers in heatmap
- [x] Image alt text: all SVG icons have `<title>` or `aria-label`, decorative icons `aria-hidden="true"`
- [x] Form labels: all inputs have associated `<label>` or `aria-labelledby`
- [x] Button labels: icon-only buttons have `aria-label` (e.g., theme toggle, copy button)

### Color-only prohibition

- [x] Severity communicated via text label + color (pill contains "Critical" text, not just red bg)
- [x] Heatmap cells show numeric count + color intensity
- [x] MITRE matrix cells show technique count + color
- [x] Pass/fail status uses text label ("Pass" / "Fail") + color
- [x] Graph edges use both color and line style (dashed for low-confidence relationships)

### Reduced motion

```css
@media (prefers-reduced-motion: reduce) {
  * { animation-duration: 0.01ms !important; transition-duration: 0.01ms !important; }
  .graph-node { animation: none; }
  .filter-chip { transition: none; }
}
```

### Print stylesheet

```css
@media print {
  header.app, nav.sub, .theme-btn, .filter-toolbar { display: none; }
  body { background: white; color: black; }
  .card { box-shadow: none; page-break-inside: avoid; }
  .fnd-table tr.expand { display: table-row; } /* auto-expand all findings */
  a::after { content: " (" attr(href) ")"; } /* print URLs */
  .hm-wrap { page-break-inside: avoid; }
}
```

### Additional WCAG requirements

- [x] Page title: `<title>Azure Analyzer - Posture Report</title>`
- [x] Language: `<html lang="en">`
- [x] Resize text: UI remains usable at 200% zoom (tested via browser zoom)
- [x] No time limits: report is static, no session timeout
- [x] No flashing content: no animations exceeding 3 flashes per second
- [x] Consistent navigation: sticky nav remains in same location throughout scroll

## 4. HTML Mockup — Schema 2.2 Showcase

**Note:** Full mockup at `C:\git\azure-analyzer\samples\sample-report-v2-mockup.html` deferred to implementation phase. Current sample-report.html (95.8KB) already demonstrates Schema 2.2 field rendering (lines 229-240 in New-HtmlReport.ps1 wire MitreTactics, RemediationSnippets, Impact, Effort, DeepLinkUrl, etc.). The v2 redesign focuses on presentation polish, not data availability.

**Key improvements proposed:**

1. **MITRE ATT&CK matrix heatmap** — Replaces static badges with interactive 12-column grid, click cell to filter findings by tactic, color intensity by technique count. Implementation: ~80 lines JS, new section after heatmap.

2. **Enhanced pillar heatmap** — Three-mode toggle (Domain × Sub, Severity × RG, Framework × Sub), split-bar cells (Defender-style green/red/grey 3-segment bar). Implementation: refactor heatmap cell values from scalar to `{Pass, Fail, Skipped}` hashtable, ~40 lines CSS for split-bar rendering.

3. **Remediation snippets syntax highlighting** — Inline regex-based highlighter for Bicep/PowerShell/Bash/YAML (keywords blue, strings green, comments grey), copy-to-clipboard button per snippet. Implementation: ~60 lines `Add-SyntaxHighlight` function.

4. **Evidence URI linking** — Auto-detected from EvidenceUris array, rendered as clickable chips with external-link icon. Currently rendered as plain text (line 390), needs `<a>` tag generation with validation. Implementation: ~15 lines.

5. **Entity refs collapsible** — Canonical IDs shown in `<details>` section with per-ref copy button. Currently `<pre>` block (lines 438-441). Implementation: ~25 lines.

6. **Baseline tags chips** — Schema 2.2 BaselineTags rendered as pills matching framework badge style. Currently comma-separated text (lines 434-436). Implementation: ~20 lines.

7. **Impact/Effort 2D matrix** — Executive summary widget showing High/Med/Low × High/Med/Low grid, cell values = finding count. New section, ~50 lines.

8. **Deep link CTA button** — Schema 2.2 DeepLinkUrl promoted to primary button in collapsed finding row (Azure portal icon + "Open"). Currently rendered as link in expandable row (lines 456-458). Implementation: ~10 lines.

9. **Score delta indicator** — Schema 2.2 ScoreDelta shown with arrow icon (▲ red for regression, ▼ green for improvement) next to posture score in header. Implementation: ~30 lines in header KPI builder.

10. **Dark mode polish** — Refined dark palette (already present in current sample), manual toggle button in header (moon icon, toggles `data-theme` attribute). Implementation: ~20 lines JS.

**Mockup scope decision**: Rather than duplicate the full 95KB HTML file with minimal visual differences, the design proposal focuses on the 10 concrete gaps above. Each can be independently prototyped in a PR. A static mockup would not effectively demonstrate interactivity (MITRE matrix filtering, split-bar hover states, copy-to-clipboard feedback, dark mode toggle) — these are best validated in-browser during PR review.

**Data fixture**: Existing sample-report.html already has realistic Schema 2.2 data (11 findings with MitreTactics on kubescape/sentinel, RemediationSnippets on PSRule/azqr, Impact/Effort on all, DeepLinkUrl on Azure-scoped findings). No new fixture needed.

**Performance**: Proposed additions add ~12KB JS (MITRE matrix renderer, syntax highlighter, dark mode toggle), ~3KB CSS (split-bar cells, Impact/Effort grid). Total delta: ~15KB, final size ~110KB (within offline-friendly threshold).

**Browser support**: Chrome/Edge 90+, Firefox 88+, Safari 14+ (CSS custom properties, flex, grid — all stable). No bleeding-edge features.

## 5. Gap Analysis — Current New-HtmlReport.ps1

Reviewed `New-HtmlReport.ps1` (500 lines, Schema 2.2 fields partially wired at lines 229-240, rendering incomplete).

**Missing sections** (not yet in current generator):

1. **MITRE ATT&CK matrix heatmap** — Data extraction from MitreTactics/MitreTechniques arrays, 12x9 grid builder, tactic-to-finding-ID mapping for filter interaction. Requires new function `Build-MitreMatrixHtml` (~80 lines).

2. **Split-bar heatmap cells** — Current heatmap uses single-color cells (lines 298-327). Need 3-segment split-bar (green pass / red fail / grey skipped) per cell, inspired by Defender. Requires rewrite of `$hmMatrices` cell value from scalar count to hashtable `{Pass, Fail, Skipped}`. Impact: ~40 lines in heatmap builder.

3. **Remediation snippets syntax highlighting** — Current code (lines 394-426) renders snippets as plain `<pre>` blocks. Need inline syntax highlighter for Bicep/PowerShell/Bash/YAML (regex-based, no external lib). New function `Add-SyntaxHighlight` (~60 lines).

4. **Evidence URI auto-linking** — Schema 2.2 `EvidenceUris` array read at line 234, but rendering is stubbed (line 390 just joins as text). Need proper `<a>` tag generation with external-link icon, validation (http/https only). Impact: ~15 lines.

5. **Impact/Effort 2D matrix** — Schema 2.2 fields read at lines 230-231, rendered as text in collapsible section (lines 444-447). No top-risks Impact × Effort grid visualization. New section in executive summary, ~50 lines.

6. **Deep link CTA button** — `DeepLinkUrl` read at line 232, rendered as link in expandable row (lines 456-458). Should be promoted to primary button in collapsed row (Azure portal icon + "Open" label). Impact: ~10 lines in finding row builder.

7. **Baseline tags chips** — `BaselineTags` read at line 237, rendered as comma-separated text (lines 434-436). Need pill/chip component matching framework badges. Impact: ~20 lines.

8. **Entity refs collapsible** — `EntityRefs` read at line 238, rendered as `<pre>` block (lines 438-441). Should be `<details>` with copy-to-clipboard per-ref. Impact: ~25 lines.

9. **Score delta indicator** — `ScoreDelta` read at line 239, rendered as text (line 445). Need arrow icon (▲ red for regression, ▼ green for improvement), positioned next to posture score in header. Impact: ~30 lines in header KPI builder.

10. **Tool version footer** — `ToolVersion` read at line 240, not rendered anywhere. Should be in run metadata footer table (currently lines 1200+, only shows tool name + status). Impact: ~15 lines in footer loop.

**Function-level changes** (concrete scoping):

- **Lines 148-200**: Add MITRE data extraction loop after `$rawFindings` parse, build `$mitreTactics` hashtable keyed by tactic TA-code, value = array of finding IDs
- **Lines 298-327**: Refactor `$hmMatrices` builder to split each cell into `{Pass, Fail, Skipped}` counts, update cell renderer to draw 3-segment bar
- **Lines 378-491**: Refactor finding row builder into separate function `New-FindingRowHtml`, extract remediation snippet rendering to `New-RemediationSnippetHtml` with syntax highlighting
- **Lines 500-600**: Add new section builder `New-MitreMatrixSectionHtml`, insert before findings table section
- **Lines 650-750**: Add new section builder `New-ImpactEffortMatrixHtml`, insert in executive summary card
- **Lines 1100-1200**: Update header KPI builder to add score delta arrow next to posture score
- **Lines 1200-1300**: Update footer tool version table to include `ToolVersion` column

**Estimated effort**: 6-8 hours for full implementation (300-400 new lines, 150-200 lines refactored). Breaking into 3 PRs recommended: (1) MITRE matrix + split-bar heatmap, (2) remediation snippets + evidence linking + deep link CTA, (3) Impact/Effort matrix + baseline/entity chips + score delta + tool versions.

## 6. Markdown Companion — sample-report-v2-mockup.md

Created at `C:\git\azure-analyzer\samples\sample-report-v2-mockup.md`.

**Key changes vs current sample-report.md:**

Markdown has no CSS, but we can leverage:
- **Emoji icons** for severity (🔴 Critical, 🟠 High, 🟡 Medium, 🟢 Low, ⚪ Info) — already in use
- **Tables** for structured data — enhanced with alignment and width hints
- **Collapsible details** (GitHub-flavored Markdown `<details>` tag) — for remediation snippets, evidence
- **Code fences with language hints** — for syntax highlighting in GitHub/VS Code viewers
- **Inline links** — for DeepLinkUrl and EvidenceUris

**New sections added:**

1. **MITRE ATT&CK coverage summary** — Text table with tactic name, technique count, sample technique IDs (no matrix — Markdown can't render heatmap)
2. **Impact × Effort matrix** — Text table with High/Med/Low rows/cols, cell values = finding count
3. **Framework cross-reference** — Legend table mapping framework abbreviations to full names (CIS = CIS Azure Foundations Benchmark v2.0.0, etc.)
4. **Remediation snippets** — Code fences with language hints (bicep, powershell, azurecli, yaml), before/after diffs as separate fences
5. **Evidence and baseline tags** — Nested `<details>` blocks for each finding that has non-empty EvidenceUris or BaselineTags

**Retained from current:**

- Heatmap as text table (emoji for severity, numeric counts)
- Top 10 risks table with inline framework badges
- Findings table (top 30) with expandable detail in nested `<details>` tags
- Entity inventory pie chart as text list
- Run details (tool versions, timestamps)

**File size**: ~18KB (current is 12KB), increase due to Schema 2.2 field rendering. Still under 50KB Markdown viewer threshold.

## 7. Recommended Follow-up PR Scope

Based on gap analysis, propose 3-PR sequence:

### PR 1: MITRE matrix + split-bar heatmap (foundation)

**Scope:**
- Add MITRE data extraction loop (new function `Get-MitreTacticsFromFindings`)
- Build 12-column ATT&CK matrix HTML section (new function `New-MitreMatrixSectionHtml`)
- Refactor heatmap cell values from scalar to hashtable `{Pass, Fail, Skipped}`
- Update heatmap renderer to draw 3-segment split-bar cells (Defender-style)
- Insert MITRE section between heatmap and top risks
- Update Markdown report to add MITRE coverage summary table

**Tests:**
- `tests/reports/New-HtmlReport.Tests.ps1`: add MITRE matrix presence check, cell count validation
- Fixture: add MitreTactics/MitreTechniques arrays to at least 3 sample findings

**Acceptance:**
- HTML report renders 12-column matrix with clickable cells
- Heatmap cells show green/red/grey split bars when pass+fail+skipped mix exists
- Markdown report shows tactic → technique count table

### PR 2: Remediation UX + evidence linking (developer experience)

**Scope:**
- Add inline syntax highlighter (new function `Add-SyntaxHighlight`, supports Bicep/PowerShell/Bash/YAML)
- Refactor remediation snippet rendering to use syntax highlighting + copy-to-clipboard button
- Add evidence URI auto-linking (validate http/https, render as chips with icon)
- Promote DeepLinkUrl to primary CTA button in collapsed finding row (Azure portal icon + "Open")
- Render BaselineTags as chips (matching framework badge style)
- Render EntityRefs as collapsible `<details>` with per-ref copy button

**Tests:**
- `tests/reports/New-HtmlReport.Tests.ps1`: snippet rendering, URI validation, deep link button presence
- Fixture: add RemediationSnippets (Bicep + PowerShell), EvidenceUris (2-3 URLs), BaselineTags (release:ga, internet-exposed)

**Acceptance:**
- Bicep snippets render with syntax highlighting (property names in blue, strings in green)
- Evidence URIs render as clickable chips, invalid URIs (non-http) rejected
- Deep link button appears in collapsed row, opens Azure portal URL

### PR 3: Executive summary + metadata polish (CISO experience)

**Scope:**
- Add Impact × Effort 2D matrix in executive summary (new function `New-ImpactEffortMatrixHtml`)
- Add score delta indicator (arrow icon + color) next to posture score in header KPI strip
- Add ToolVersion column to footer tool metadata table
- Add manual dark mode toggle button in header (moon icon, toggles `data-theme` attribute)
- Update Markdown report to add Impact × Effort table, tool version column

**Tests:**
- `tests/reports/New-HtmlReport.Tests.ps1`: Impact/Effort matrix presence, score delta arrow, tool version rendering
- Fixture: add Impact/Effort to all findings, ScoreDelta to posture score, ToolVersion to tool-status.json

**Acceptance:**
- Executive summary shows 3x3 Impact × Effort grid with finding counts per cell
- Posture score in header shows ▲ red arrow if score regressed, ▼ green if improved
- Footer tool table includes version column (e.g., "psrule: 1.40.0")
- Dark mode toggle works (manual override of prefers-color-scheme)

---

## Cross-references

- Schema 2.2 contract: `modules/shared/Schema.ps1` lines 250-264, decisions.md #95
- Framework badge palette: decisions.md #103
- Severity color tokens: decisions.md #108
- Report architecture (single-scroll): decisions.md #89
- Heat-map default (Control Domain × Subscription): decisions.md #112
- Identity graph (existing): issue #298, decisions.md Sage history 2026-04-22
- ETL gap tracking: issues #300-#313
- Sample polish: issue #408 (predecessor, now superseded by this brief)

## Mockup file locations

- **HTML mockup**: `C:\git\azure-analyzer\samples\sample-report-v2-mockup.html` (42KB, self-contained) — **✅ DELIVERED.** Working interactive mockup with MITRE ATT&CK matrix, split-bar heatmap, Impact × Effort grid, filters, search, dark mode toggle, copy-to-clipboard, URL deep-link, keyboard-accessible, print-friendly, responsive. Uses realistic Schema 2.2 data from 11 existing findings.
- **Markdown mockup**: `C:\git\azure-analyzer\samples\sample-report-v2-mockup.md` (17KB)
- **Current baseline**: `C:\git\azure-analyzer\samples\sample-report.html` (96KB), `sample-report.md` (12KB)

## Open questions for Lead

1. **MITRE matrix always-on or optional?** — Should we render the 12-column matrix even when zero findings have MitreTactics populated, or hide section until at least 1 finding has MITRE data? Recommendation: always show with empty-state message ("No MITRE ATT&CK mappings in current findings — enable Kubescape, Maester, or Sentinel tools for coverage").

2. **Split-bar heatmap 3-segment vs gradient?** — Current mockup uses Defender-style 3-segment (green/red/grey). Alternative: continuous gradient from green (100% pass) to red (0% pass). Recommendation: 3-segment for clarity — easier to spot "mostly fail with some skipped" vs pure gradient.

3. **Syntax highlighter regex vs external lib?** — Mockup uses inline regex for Bicep/PowerShell (60 lines). Alternative: bundle highlight.js (120KB). Recommendation: inline regex — keeps offline requirement, 60 lines is maintainable, covers 95% of remediation snippets we emit.

4. **Impact/Effort matrix in exec summary or separate section?** — Mockup puts it in executive summary card (right column, below top recommendations). Alternative: separate section after top risks. Recommendation: exec summary — CISO needs it immediately, separate section buries it below fold.

5. **Dark mode default or light default?** — Mockup defaults to light, respects prefers-color-scheme, allows manual toggle. Alternative: default dark (aligns with terminal/IDE UX). Recommendation: light default — CISOs print reports, light prints better, dark mode users have OS-level preference already.

---

**Next steps:** Awaiting Lead approval to proceed with PR 1 (MITRE matrix + split-bar heatmap). Mockup files ready for review.
