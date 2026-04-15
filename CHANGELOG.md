# Changelog

All notable changes to azure-analyzer will be documented here.

## [Unreleased]

### Added
- **AI triage (optional)**: `-EnableAiTriage` switch enriches non-compliant findings via GitHub Copilot SDK with priority ranking, risk context, remediation steps, and root cause grouping. See `docs/ai-triage.md`.
- **AI triage in reports**: HTML/Markdown reports include AI Triage Summary when `triage.json` exists.

## [1.0.0] - 2025-01-15

### Added
- **Auto-install prerequisites**: `Install-Prerequisites` auto-installs missing PSGallery modules (Az.ResourceGraph, PSRule, PSRule.Rules.Azure, WARA, Maester) on first run. CLI tools (azqr, scorecard) print install instructions. Respects `-IncludeTools` to only install what's needed. Use `-SkipPrereqCheck` to bypass in CI.
- **Local module packaging**: Created `AzureAnalyzer.psd1` manifest and `AzureAnalyzer.psm1` loader. Users can now `Import-Module ./AzureAnalyzer.psd1` after cloning. Simplifies local invocation and development.
- **Public module API**: Three exported functions: `Invoke-AzureAnalyzer`, `New-HtmlReport`, `New-MdReport`. All tool wrappers remain internal.
- **Module auto-loading**: Root script dot-sources all tool wrappers from `modules/` directory and public functions from root scripts.
- **README module instructions**: Quick Start updated to show `Import-Module` workflow after clone.

### Changed
- README: Updated Quick Start to include `Import-Module ./AzureAnalyzer.psd1` step.
- ModuleVersion: 1.0.0 (local module only, no PSGallery).

## [Unreleased]

### Added
- **Wrapper status contract**: All tool wrappers now return `Status` ('Success', 'Skipped', 'Failed') and `Message` fields alongside `Source` and `Findings`.
- **Tool status summary**: Orchestrator tracks which tools succeeded, were skipped, or failed.
- **Maester integration**: Added `modules/Invoke-Maester.ps1` wrapper for Entra ID / identity security posture assessment (tool #6). Auto-installs from PSGallery, checks Graph connection, maps Pester test results to unified schema. Runs unconditionally (tenant-scoped, not subscription-gated).
- **OpenSSF Scorecard integration**: Added `modules/Invoke-Scorecard.ps1` wrapper for repository supply chain security assessment (tool #7). Evaluates branch protection, dependency pinning, CI/CD configuration, and other security practices. Requires repository context via new `-Repository` parameter.
- **Sample reports and visual previews in README**: Added `samples/` directory with mock findings data and pre-generated HTML + Markdown reports so users can see output before running the tool. README now includes collapsed preview sections for both report formats.
- **Bundled ALZ queries**: ALZ Resource Graph queries are now automatically bundled from [alz-graph-queries](https://github.com/martinopedal/alz-graph-queries) — no manual copy-step required. Queries originate from [Azure/review-checklists](https://github.com/Azure/review-checklists).

### Changed
- README: Restructure as consumer-first (Quick Start → What you get → Prerequisites → Usage → Schema → Permissions) with contributor/CI sections below a separator
- README: Rewrite CI/Automation section — separate user-facing CI from maintainer-only squad workflows behind a collapsed `<details>` block
- README: Add "For Contributors" section explaining that `.squad/` is maintainer infrastructure, not part of the tool
- `.gitattributes`: Add `export-ignore` rules so squad files (`.squad/`, squad workflows, `.github/agents/`) are excluded from archive downloads
- README & THIRD_PARTY_NOTICES.md: Update ALZ queries attribution to reflect derivation chain (alz-graph-queries ← Azure/review-checklists)

### Fixed
- **Report field rendering**: HTML and Markdown reports now render `ResourceId` and `LearnMoreUrl` columns in all findings tables (previously only stored in JSON but not displayed)
- **PS 7.6 compatibility**: Fix `New-HtmlReport.ps1` `-join` operator parsing error on PowerShell 7.6 (wrap `ForEach-Object` pipeline in parentheses)

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


