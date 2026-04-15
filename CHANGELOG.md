# Changelog

All notable changes to azure-analyzer will be documented here.

## [Unreleased]

### Added
- **Management group recursion**: When `-ManagementGroupId` is provided, the orchestrator auto-discovers all child subscriptions via ARG query and runs subscription-scoped tools (azqr, PSRule, WARA) across each one. MG-scoped tools (AzGovViz, ALZ queries) and tenant-wide tools (Maester) are unaffected. Use `-Recurse:$false` to disable.
- **AI triage (optional, requires GitHub Copilot license)**: `-EnableAiTriage` switch enriches non-compliant findings via GitHub Copilot SDK with priority ranking, risk context, remediation steps, and root cause grouping. Zero footprint when disabled. See `docs/ai-triage.md`.
- **AI triage in reports**: HTML/Markdown reports include AI Triage Summary when `triage.json` exists.
- **Wrapper status contract**: All tool wrappers now return `Status` ('Success', 'Skipped', 'Failed') and `Message` fields alongside `Source` and `Findings`.
- **Tool status summary**: Orchestrator tracks which tools succeeded, were skipped, or failed.
- **Maester integration**: Added `modules/Invoke-Maester.ps1` wrapper for Entra ID / identity security posture assessment (tool #6). Checks Graph connection, maps Pester test results to unified schema. Runs unconditionally (tenant-scoped, not subscription-gated).
- **OpenSSF Scorecard integration**: Added `modules/Invoke-Scorecard.ps1` wrapper for repository supply chain security assessment (tool #7). Evaluates branch protection, dependency pinning, CI/CD configuration, and other security practices. Requires repository context via new `-Repository` parameter.
- **Sample reports and visual previews in README**: Added `samples/` directory with mock findings data and pre-generated HTML + Markdown reports so users can see output before running the tool. README now includes collapsed preview sections for both report formats.
- **Bundled ALZ queries**: ALZ Resource Graph queries are now automatically bundled from [alz-graph-queries](https://github.com/martinopedal/alz-graph-queries) — no manual copy-step required. Queries originate from [Azure/review-checklists](https://github.com/Azure/review-checklists).
- CI: `docs-check.yml` workflow enforces documentation updates on PRs that change code files
- **Schema enrichment**: Unified findings now include `ResourceId` (Azure ARM resource ID) and `LearnMoreUrl` (Microsoft Learn link) fields
- **Auto-report generation**: `Invoke-AzureAnalyzer.ps1` now automatically calls `New-HtmlReport.ps1` and `New-MdReport.ps1` after writing `results.json` — no manual step needed
- **HTML report enhancements**:
  - Executive summary with auto-generated compliance prose (resource count, tool count, compliance %, high-severity callout)
  - Pure-CSS donut chart using conic-gradient for compliance percentage (zero JS dependencies)
  - Per-source horizontal bar chart showing finding counts per tool (azqr, PSRule, AzGovViz, ALZ Queries, WARA, Maester, Scorecard)
  - Clickable stat cards for severity filtering with `aria-pressed` accessibility support
  - Filter banner with clear button when severity filter is active
  - Zebra striping on findings tables for readability
  - Severity left-border on table rows (color-coded by High/Medium/Low/Info)
  - Text filter/search input above each findings table with instant keyup filtering
  - Clickable remediation URLs auto-detected and wrapped in anchor tags
  - Tool coverage badges based on actual tool status (Success/Skipped/Failed/Excluded), not just presence of findings
  - Remediation column added to all findings tables
  - Print-friendly @media print CSS hiding interactive elements, preventing page breaks in rows
- **Markdown report enhancements**:
  - Executive summary with GitHub-flavored callouts (WARNING/NOTE/TIP) based on severity
  - Mermaid pie chart for compliance breakdown (rendered natively on GitHub)
  - Per-source emoji badges (🔴 High, 🟠 Med, 🟡 Low, 🟢 All compliant)
  - Collapsible per-category finding tables via `<details>` tags
  - Tool coverage section showing which tools ran vs were skipped

### Changed
- README: Restructure as consumer-first (Quick Start → What you get → Prerequisites → Usage → Schema → Permissions) with contributor/CI sections below a separator
- README: Rewrite CI/Automation section — separate user-facing CI from maintainer-only squad workflows behind a collapsed `<details>` block
- README: Add "For Contributors" section explaining that `.squad/` is maintainer infrastructure, not part of the tool
- `.gitattributes`: Add `export-ignore` rules so squad files (`.squad/`, squad workflows, `.github/agents/`) are excluded from archive downloads
- README & THIRD_PARTY_NOTICES.md: Update ALZ queries attribution to reflect derivation chain (alz-graph-queries ← Azure/review-checklists)
- `Invoke-PSRule.ps1` — populate `ResourceId` from `TargetName` when it looks like an ARM resource ID
- `Invoke-AlzQueries.ps1` — populate `ResourceId` from first non-compliant ARG row
- `Invoke-WARA.ps1` — populate `ResourceId` from ImpactedResources and `LearnMoreUrl` from LearnMoreLink
- Updated README.md to document unified 10-field schema and auto-generated reports

### Removed
- Delete dead Python stubs (`src/run.py`, `src/__init__.py`) — orchestrator is PowerShell only

### Fixed
- **Invoke-Wrapper fallback status**: Both fallback paths (script-not-found and exception-after-retries) now return `Status='Failed'` and `Message`, preventing `tool-status.json` and reports from falsely showing success after hard failures.
- **Maester API mapping**: Fix `.Tests` → `.Result` to match Pester `TestResultContainer` returned by `Invoke-Maester -PassThru`. Handle `NotRun` status alongside `Passed`/`Skipped`.
- **Graph scopes hint**: Warning message now shows `Connect-MgGraph -Scopes (Get-MtGraphScope)` with correct scope helper.
- **Prereq behavior**: `Install-Prerequisites` now advise-only by default — lists missing modules with install commands. Add `-InstallMissingModules` switch to opt-in to auto-install. Prevents unexpected writes in shared/CI environments.
- **Report field rendering**: HTML and Markdown reports now render `ResourceId` and `LearnMoreUrl` columns in all findings tables (previously only stored in JSON but not displayed)
- **PS 7.6 compatibility**: Fix `New-HtmlReport.ps1` `-join` operator parsing error on PowerShell 7.6 (wrap `ForEach-Object` pipeline in parentheses)
- **Dedup key strengthened**: Use `Source+ResourceId+Category+Title+Compliant` as composite key. Never dedup across tools when ResourceId is empty — prevents unrelated findings from collapsing.
- **PSRule severity mapping**: Fix `Outcome` (Pass/Fail) incorrectly mapping to severity via `Map-Severity` (Fail fell through to Info). Now derives severity from Outcome directly: Fail=Medium, Error=High, Pass=Info.
- **errors.json completeness**: Wrapper `Status='Failed'` returns now recorded in `$toolErrors` and `errors.json`, not just exception-path failures.
- **Tool status tracking**: Orchestrator writes `tool-status.json` alongside `results.json` with per-tool Status/Message/Findings count. Reports use this to distinguish success-with-zero-findings from skipped/failed.
- **HTML stat cards clickable**: Stat cards converted from `<div>` to `<button>` elements with `onclick` severity filter, `aria-pressed` for screen readers, and visible focus styles.
- **HTML zebra striping**: Alternating row backgrounds on findings tables for readability.
- **HTML severity borders**: Left-border color on each finding row matching its severity (High=red, Medium=orange, Low=yellow, Info=gray).
- **HTML tool coverage accuracy**: Coverage badges now reflect actual tool status (Success/Skipped/Failed/Excluded) from `tool-status.json`, not just presence/absence of findings.
- **Markdown source table**: All 7 tools shown in source breakdown table with Status column, even when they have zero findings or were skipped.
- **AzGovViz path discovery**: `Find-AzGovViz` now also searches `tools/AzGovViz/` and `$PSScriptRoot/tools/AzGovViz/`, matching README instructions.
- **ScorecardThreshold param**: Added `-ScorecardThreshold` parameter to orchestrator, passed through to Scorecard wrapper. Default: 7.
- Remove `python` from CodeQL language matrix; repo is PowerShell-only, no Python extractor needed
- Update branch protection to require `Analyze (actions)` only
- Update codeql.yml to use actions/checkout v6 SHA (was v4)
- Fix copilot-instructions.md SHA-pinning example to reference v6 (was v4.2.2)

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

## [0.0.1] - Initial scaffold
- Initial scaffold


