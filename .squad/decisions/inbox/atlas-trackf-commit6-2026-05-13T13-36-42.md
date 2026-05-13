# Track F Commit 6 - Tier-Aware Rendering and Citation Helper

**Agent:** Atlas (Squad Core Dev)  
**Date:** 2026-05-13  
**Issue:** #506 (Track F: auditor-driven report builder)  
**Commit:** feat(report): implement tier-aware rendering and citation helper

## Context

Implements Commit 6 of the Track F sequence: Write-AuditorRenderTier (renders HTML/MD reports with tier-aware layouts) and New-AuditorCitation (workpaper-ready single-line citation strings with credential scrubbing).

Both functions were skeleton stubs throwing NotImplementedException. This commit implements them per the Track F design doc (docs/design/track-f-auditor-redesign.md) and issue #506 spec.

## Implementation Decisions

### Write-AuditorRenderTier

**Tier mapping:**
- PureJson (Tier 1) → Tier1Full: full HTML table with all findings
- EmbeddedSqlite (Tier 2) → Tier2Full: full HTML table with all findings
- SidecarSqlite (Tier 3) → Tier3Headline: collapsible sections with deep links
- PodeViewer (Tier 4) → Tier4KPIs: KPI tile grid with minimal content

**HTML content by tier:**
- Tier 1/2: `<table>` with all findings (FindingId, Severity, Title, EntityId columns)
- Tier 3: `<details>` with collapsible finding list, anchor links to full report
- Tier 4: `<div class="kpi-grid">` with tiles (total, critical, high counts), deep link to /viewer/findings

**Print stylesheet:**
- Included `@media print` block with 1cm margin, page-break-inside: avoid on tables, page-break-after: avoid on headings, .no-print class for nav elements
- Ensures tier 1/2 reports are ready for auditor print/PDF export without layout breaks

**Markdown report:**
- Simple title, summary (total findings), bullet list of findings with severity/title
- Consistent structure across all tiers (no tier-specific layout for MD)

**Output:**
- Always writes `audit-report.html` and `audit-report.md` to OutputDirectory
- Returns `@{ HtmlPath, MdPath, RenderingMode }` hashtable

### New-AuditorCitation

**Citation format (workpaper style):**
```
[<Source> <RulePin>] <Id>: <Title>. Resource: <CanonicalId>. Severity: <Severity>. Collected <CollectedAtUtc>. Rule: <RuleUrl>. Docs: <DocsUrl>.
```

**Field handling:**
- All fields optional; omits segments cleanly if field is null/empty/whitespace
- Source/RulePin: combines as `[Source RulePin]` if both present, `[Source]` if only Source, omitted if neither
- Title: embedded newlines replaced with spaces (single-line output requirement)
- CanonicalId: falls back to EntityId if CanonicalId property missing
- CollectedAtUtc: falls back to CollectedAt if CollectedAtUtc missing
- RuleUrl/DocsUrl: included as-is if present

**RulePin field:**
- Checked with PSObject.Properties['RulePin']; if present, included in citation
- No strict enforcement (FindingRow schema may or may not have RulePin; this function degrades gracefully)
- Not currently in fixtures (tests don't require it), but added to support future schema extension

**Credential scrubbing:**
- Dot-sources `modules/shared/Sanitize.ps1` (relative path from PSScriptRoot parent)
- Applies `Remove-Credentials` to final citation string before returning
- Test 24 verifies password redaction in Title field (exposed connection string with password=secret123 → [REDACTED])

### Test coverage

**Test 21:** Produces HTML and MD files (both exist, paths returned, RenderingMode populated)  
**Test 22:** Tier-aware rendering mode (Tier 1 has `<table>`, Tier 4 has KPI grid + deep links; RenderingMode values correct)  
**Test 23:** Produces single-line workpaper-ready string (no embedded newlines, all segments present)  
**Test 24:** Sanitizes credentials via Remove-Credentials (password=secret123 → [REDACTED])

### Fixtures

No new fixtures created. Tests use existing auditor-small/results.json and auditor-small/entities.json fixtures from Commits 2/3, plus ad-hoc PSCustomObject findings for citation tests.

### Repository invariants preserved

- No em-dashes or en-dashes in HTML/MD output (ASCII hyphens only)
- UTF8 encoding with LF line endings (Set-Content -Encoding UTF8 -NoNewline:false)
- Severity enum exactly Critical|High|Medium|Low|Info (case-preserved in output)
- Credential scrubbing via Remove-Credentials (Test 24 confirms)
- Co-authored-by trailer on commit

## Deviations from Plan

None. Implementation matches Commit 6 spec from issue #506.

## Lessons Learned

**Sanitize.ps1 dot-sourcing in New-AuditorCitation:**
- Used relative path from PSScriptRoot parent: `Join-Path (Split-Path $PSScriptRoot -Parent) 'shared' 'Sanitize.ps1'`
- Fallback if Test-Path fails or Remove-Credentials not available (degrades gracefully)
- No global dot-source at module top (AuditorReportBuilder.ps1 is standalone function library, not a module loader)

**HTML print stylesheet:**
- Inline `<style>` with @media print block is simplest pattern for self-contained HTML
- page-break-inside: avoid prevents table row splits across pages
- 1cm margin (smaller than 2em screen margin) maximizes print real estate

**Tier 4 KPI tile grid:**
- CSS grid with `repeat(auto-fit, minmax(200px, 1fr))` responsive layout
- Tiles show KPI value (large font, blue) + label (small font)
- Deep link to /viewer/findings assumes PodeViewer tier serves a web UI at that path

## Related Work

- Track F Commit 2 (PR #1089): control-domain section grouping
- Track F Commit 3 (PR #1090): attack-path, resilience, policy-coverage sections
- Track F Commit 4 (PR #1091): remediation appendix + evidence export
- Track F Commit 5 (PR #1092): LLM triage annotations
- Track V (issue #430): tier picker and report-manifest.json schema (will consume Write-AuditorRenderTier in Commit 9)

## Next Steps

- Track F Commit 7: New-AuditorCitation integration into section renderers (attack-path, resilience, policy-coverage)
- Track F Commit 8: Diff vs previous run (compare two result sets, highlight changes)
- Track F Commit 9: Build-AuditorReport orchestrator (wire up all sections, closes #506)
