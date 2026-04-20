# Issue #235 Resolution — Tool Count Update

**Date**: 2026-04-20T15:21:22Z  
**Assigned to**: Sage (Research & Discovery Specialist)  
**Issue**: [#235](https://github.com/martinopedal/azure-analyzer/issues/235) "docs: README tool count 26 to 27"

## Summary

Completed documentation update to reflect current tool manifest count. Updated README.md tool count from 26 to 27 to align with `tools/tool-manifest.json` which now includes 27 total tool entries (26 enabled + 1 disabled: `copilot-triage`).

## Verified Tool Count

- **Total entries in manifest**: 27
- **Enabled tools**: 26 (azqr, kubescape, kube-bench, defender-for-cloud, falco, azure-cost, finops, psrule, azgovviz, alz-queries, wara, maester, scorecard, ado-connections, ado-pipelines, ado-repos-secrets, ado-pipeline-correlator, identity-correlator, identity-graph-expansion, zizmor, gitleaks, trivy, bicep-iac, terraform-iac, sentinel-incidents, sentinel-coverage)
- **Disabled tools**: 1 (copilot-triage)
- **Count reason**: README should reflect the authoritative manifest total, not just enabled tools, per project guidance that `tools/tool-manifest.json` is the single source of truth.

## Changes

1. **README.md** — Updated lines 7 and 66 from "26 tools" to "27 tools"
2. **CHANGELOG.md** — Added entry under [Unreleased] → Fixed section
3. **Tool catalogs** — Regenerated (no changes to output, tool count only appears in summary driven by manifest)
4. **PERMISSIONS.md** — Regenerated index (already in sync, no changes)

## PR Details

- **PR**: [#265](https://github.com/martinopedal/azure-analyzer/pull/265)
- **Merge Commit**: `216e84c1da3da7bb42388a1342e752d07ac66b0b`
- **Status**: Merged (squash) to main, issue #235 automatically closed
- **CI Status**: All 15 checks passing
  - Required check `CodeQL/Analyze (actions)`: ✅ PASS
  - `Docs Check/Documentation update check`: ✅ PASS (rerun after transient GitHub Actions download error)
  - All Pester tests: ✅ 1213 PASS / 0 FAIL (improved from baseline 1208+)

## Handoff

Branch `docs/235-tool-count` deleted locally. Worktree cleaned up. Issue #235 resolved and closed via PR merge.

**Next**: Archive this decision record.
