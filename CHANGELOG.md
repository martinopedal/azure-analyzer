# Changelog

All notable changes to azure-analyzer will be documented here.

## [Unreleased]

## [1.1.0] - 2026-04-15

### Added

- `modules/Invoke-CostManagementApi.ps1` — Cost Management API module: budget existence, alert thresholds (>= 80%), anomaly alert rules, and Advisor high-impact cost recommendations. Integrated as orchestrator step 6/8.
- `modules/Invoke-GraphApi.ps1` — Microsoft Graph API module for Entra ID security posture: CA policy coverage, PIM permanent GA assignments, MFA registration campaign, security defaults, and guest access restrictions. Integrated as orchestrator step 7/8.
- `modules/Invoke-DevOpsApi.ps1` — GitHub/ADO DevOps governance module: branch protection, CODEOWNERS, secret scanning, Dependabot, and ADO pipeline approvals. Integrated as orchestrator step 8/8 with `$GitHubRepo`, `$GitHubToken`, `$AdoOrg`, `$AdoProject`, `$AdoToken` parameters.
- `queries/hybrid_network_queries.json` — 6 ARG queries for ExpressRoute circuits (HN-001/002), VPN gateways (HN-003/004), and VPN connections (HN-005/006).
- `modules/Invoke-AlzQueries.ps1` — SkipToken pagination for ARG result sets > 1000 rows; auto-discovery of all `*.json` files in `queries/` (no code change needed to add queries).
- `Invoke-AzureAnalyzer.ps1` — now orchestrates 8 assessment tools (up from 5).

### Fixed

- Removed `python` from CodeQL language matrix — repo is PowerShell-only, no Python extractor needed.
- Updated branch protection to require `Analyze (actions)` check only.

## [1.0.0] - 2026-04-14

### Added

- `Invoke-AzureAnalyzer.ps1` — orchestrator merging all findings to `output/results.json`.
- `modules/Invoke-Azqr.ps1` — azqr CLI wrapper with graceful degradation.
- `modules/Invoke-PSRule.ps1` — PSRule for Azure wrapper.
- `modules/Invoke-AzGovViz.ps1` — AzGovViz wrapper.
- `modules/Invoke-AlzQueries.ps1` — alz-graph-queries ARG wrapper.
- `modules/Invoke-WARA.ps1` — Well-Architected Reliability Assessment wrapper.
- `New-MdReport.ps1` — Markdown report generator from `results.json`.
- `New-HtmlReport.ps1` — offline-capable HTML report with severity cards and sortable tables.
- CI failure analysis workflow: auto-creates issues with `bug`+`squad` labels on workflow failure.

## [0.0.1] - Initial scaffold

- Initial scaffold
