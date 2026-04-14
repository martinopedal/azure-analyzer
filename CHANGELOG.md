# Changelog

All notable changes to azure-analyzer will be documented here.

## [Unreleased]

### Added
- CI failure analysis workflow: auto-creates issues with bug+squad labels when any workflow fails
- Phase 4: `modules/Invoke-Azqr.ps1` — azqr CLI wrapper (graceful degradation)
- Phase 4: `modules/Invoke-PSRule.ps1` — PSRule for Azure wrapper
- Phase 4: `modules/Invoke-AzGovViz.ps1` — AzGovViz wrapper
- Phase 4: `modules/Invoke-AlzQueries.ps1` — alz-graph-queries ARG wrapper
- Phase 4: `Invoke-AzureAnalyzer.ps1` — orchestrator, merges all findings to output/results.json

## [0.0.1] - Initial scaffold
- Initial scaffold
