# Changelog

All notable changes to azure-analyzer will be documented here.

## [Unreleased]

### Added
- CI: `docs-check.yml` workflow enforces documentation updates on PRs that change code files
- Unified schema: add `ResourceId` and `LearnMoreUrl` fields to every finding
- Orchestrator auto-generates HTML and Markdown reports after writing results.json

### Changed
- `Invoke-PSRule.ps1` — populate `ResourceId` from `TargetName` when it looks like an ARM resource ID
- `Invoke-AlzQueries.ps1` — populate `ResourceId` from first non-compliant ARG row
- `Invoke-WARA.ps1` — populate `ResourceId` from ImpactedResources and `LearnMoreUrl` from LearnMoreLink

### Removed
- Delete dead Python stubs (`src/run.py`, `src/__init__.py`) — orchestrator is PowerShell only

### Fixed
- Remove `python` from CodeQL language matrix; repo is PowerShell-only, no Python extractor needed
- Update branch protection to require `Analyze (actions)` only
- Update codeql.yml to use actions/checkout v6 SHA (was v4)
- Fix copilot-instructions.md SHA-pinning example to reference v6 (was v4.2.2)

### Added
- feat: enhance HTML report with dashboard-quality visuals
  - Executive summary block with auto-generated prose (resource count, tool count, compliance %, high-severity callout)
  - Pure-CSS donut chart using conic-gradient for compliance percentage
  - Per-source horizontal bar chart showing finding counts per tool (azqr, PSRule, AzGovViz, ALZ Queries, WARA)
  - Clickable remediation URLs auto-detected and wrapped in anchor tags
  - Text filter/search input above each findings table with instant keyup filtering
  - Tool coverage summary showing which tools produced results vs were skipped
  - Remediation column added to all findings tables
  - Print-friendly @media print CSS hiding interactive elements, preventing page breaks in rows
- feat: enhance Markdown report with GitHub-native visualization features
  - Executive summary with GitHub-flavored callouts (WARNING/NOTE/TIP) based on severity
  - Mermaid pie chart for compliance breakdown (rendered natively on GitHub)
  - Per-source emoji badges (🔴 High, 🟠 Med, 🟡 Low, 🟢 All compliant)
  - Collapsible per-category finding tables via `<details>` tags
  - Tool coverage section showing which tools ran vs were skipped
- Add .editorconfig for consistent formatting across editors
- feat: add WARA (Well-Architected Reliability Assessment) as 5th assessment source
- Phase 6: full README with prerequisites, quick-start, output and permissions tables
- CI failure analysis workflow: auto-creates issues with bug+squad labels when any workflow fails
- Phase 4: `modules/Invoke-Azqr.ps1` — azqr CLI wrapper (graceful degradation)
- Phase 4: `modules/Invoke-PSRule.ps1` — PSRule for Azure wrapper
- Phase 4: `modules/Invoke-AzGovViz.ps1` — AzGovViz wrapper
- Phase 4: `modules/Invoke-AlzQueries.ps1` — alz-graph-queries ARG wrapper
- Phase 4: `Invoke-AzureAnalyzer.ps1` — orchestrator, merges all findings to output/results.json
- Phase 5: `New-MdReport.ps1` - Markdown report generator from results.json
- Phase 5: `New-HtmlReport.ps1` - offline-capable HTML report with severity cards and sortable tables

## [0.0.1] - Initial scaffold
- Initial scaffold


