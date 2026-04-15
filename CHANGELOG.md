# Changelog

All notable changes to azure-analyzer will be documented here.

## [Unreleased]

### Added
- feat(hybrid): `queries/hybrid_network_queries.json` -- 6 ARG queries for on-premises/hybrid network health (HN-001 through HN-006): ExpressRoute circuit state and SKU, VPN gateway active-active and SKU, VPN connection BGP and status
- feat(hybrid): `Invoke-AlzQueries.ps1` now auto-discovers all `*.json` files in `queries/` -- add any file to extend checks without code changes
- feat(hybrid): `Invoke-AlzQueries.ps1` supports both `query` (azure-analyzer format) and `graph` (alz-graph-queries format) KQL field names


### Fixed
- Remove `python` from CodeQL language matrix; repo is PowerShell-only, no Python extractor needed
- Update branch protection to require `Analyze (actions)` only

### Added
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


