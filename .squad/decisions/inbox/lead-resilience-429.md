# lead-resilience #429 — Track B scaffold

**PR:** https://github.com/martinopedal/azure-analyzer/pull/436 (DRAFT)
**Branch:** `feat/resilience-429`
**Worktree:** `C:\git\worktrees\resilience-429`
**Status:** scaffold only, held on Foundation #435.

## Delivered

1. `docs/design/resilience-map.md`
   - 6 EdgeRelations (DependsOn, RegionPinned, ZonePinned, BackedUpBy, FailsOverTo, ReplicatedTo) with primary (azqr, wara) vs secondary (psrule, defender) source priority and primary-wins conflict resolution.
   - Heatmap rendering: per-region/zone color-coded grid (red -> green by composite score), dashed failover-pair edges, dotted replication edges, fill-density backup coverage, hidden BackedUpBy edges with toggle.
   - RTO/RPO overlay with explicit graceful-absence contract (no badge, no warning, no broken layout when fields missing).
   - Tier-aware rendering parallel to Track A: Tier 1 full, Tier 2 collapsed-with-expand, Tier 3 mgmt-group heatmap cells only.
   - Shared 2500-edge canvas budget across attack + resilience + policy. Resilience yields edges first (priority: attack-path > policy > resilience). Heatmap cells are NEVER suppressed.
   - 60-second auditor blast-radius acceptance at all 3 tiers.

2. `modules/shared/Renderers/ResilienceMapRenderer.ps1`
   - 5 function signatures only; bodies throw `NotImplementedException` so accidental call surfaces immediately.
   - `Invoke-ResilienceMapRender`, `Get-ResilienceHeatmapCells`, `Resolve-ResilienceEdgeStyle`, `Get-RecoveryObjectiveOverlay`, `Resolve-BlastRadius`.

3. `tests/renderers/ResilienceMap.Tests.ps1`
   - 20 `-Skip` placeholders across 5 contexts.
   - Pester result: 20 skipped, 0 failed. Baseline preserved.

## Hot files NOT touched

Schema.ps1, Invoke-AzureAnalyzer.ps1, New-HtmlReport.ps1, tool-manifest.json. No normalizer `-EdgeCollector` adoption (per-tool PRs after #435).

## Next

Unhold after Foundation #435 merges. Implement renderer bodies + flip `-Skip` to live tests in follow-up PR. Per-tool normalizer adoption (azqr / wara / psrule / defender) ships in parallel PRs.
