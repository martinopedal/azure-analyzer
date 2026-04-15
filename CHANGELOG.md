# Changelog

All notable changes to azure-analyzer will be documented here.

## [Unreleased]

### Added
- **Bundled ALZ queries**: ALZ Resource Graph queries are now automatically bundled from [alz-graph-queries](https://github.com/martinopedal/alz-graph-queries) — no manual copy-step required. Queries originate from [Azure/review-checklists](https://github.com/Azure/review-checklists).

### Changed
- README: Rewrite CI/Automation section — separate user-facing CI from maintainer-only squad workflows behind a collapsed `<details>` block
- README: Add "For Contributors" section explaining that `.squad/` is maintainer infrastructure, not part of the tool
- `.gitattributes`: Add `export-ignore` rules so squad files (`.squad/`, squad workflows, `.github/agents/`) are excluded from archive downloads
- README & THIRD_PARTY_NOTICES.md: Update ALZ queries attribution to reflect derivation chain (alz-graph-queries ← Azure/review-checklists)

### Fixed
- **Report field rendering**: HTML and Markdown reports now render `ResourceId` and `LearnMoreUrl` columns in all findings tables (previously only stored in JSON but not displayed)

### Added
- CI: `docs-check.yml` workflow enforces documentation updates on PRs that change code files
- **Schema enrichment**: Unified findings now include `ResourceId` (Azure ARM resource ID) and `LearnMoreUrl` (Microsoft Learn link) fields
- **Auto-report generation**: `Invoke-AzureAnalyzer.ps1` now automatically calls `New-HtmlReport.ps1` and `New-MdReport.ps1` after writing `results.json` — no manual step needed
- **HTML report enhancements**:
  - Executive summary with auto-generated compliance prose (resource count, tool count, compliance %, high-severity callout)
  - Pure-CSS donut chart using conic-gradient for compliance percentage (zero JS dependencies)
  - Per-source horizontal bar chart showing finding counts per tool (azqr, PSRule, AzGovViz, ALZ Queries, WARA)
  - Text filter/search input above each findings table with instant keyup filtering
  - Clickable remediation URLs auto-detected and wrapped in anchor tags
  - Tool coverage badges showing which tools ran vs were skipped
  - Remediation column added to all findings tables
  - Print-friendly @media print CSS hiding interactive elements, preventing page breaks in rows
- **Markdown report enhancements**:
  - Executive summary with GitHub-flavored callouts (WARNING/NOTE/TIP) based on severity
  - Mermaid pie chart for compliance breakdown (rendered natively on GitHub)
  - Per-source emoji badges (🔴 High, 🟠 Med, 🟡 Low, 🟢 All compliant)
  - Collapsible per-category finding tables via `<details>` tags
  - Tool coverage section showing which tools ran vs were skipped

### Changed
- `Invoke-PSRule.ps1` — populate `ResourceId` from `TargetName` when it looks like an ARM resource ID
- `Invoke-AlzQueries.ps1` — populate `ResourceId` from first non-compliant ARG row
- `Invoke-WARA.ps1` — populate `ResourceId` from ImpactedResources and `LearnMoreUrl` from LearnMoreLink
- Updated README.md to document unified 10-field schema and auto-generated reports

### Removed
- Delete dead Python stubs (`src/run.py`, `src/__init__.py`) — orchestrator is PowerShell only

### Fixed
- Remove `python` from CodeQL language matrix; repo is PowerShell-only, no Python extractor needed
- Update branch protection to require `Analyze (actions)` only
- Update codeql.yml to use actions/checkout v6 SHA (was v4)
- Fix copilot-instructions.md SHA-pinning example to reference v6 (was v4.2.2)

## [0.0.1] - Initial scaffold
- Initial scaffold


