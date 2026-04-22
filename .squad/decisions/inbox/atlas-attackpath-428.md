# atlas-attackpath-428 — Track A scaffold

**Date:** 2026-04-21
**Owner:** Atlas
**Issue:** #428 (epic #427, foundation dependency #435)
**Branch:** feat/attack-path-428
**Status:** Draft PR (stability hold)

## Summary

Scaffolded Track A (attack-path visualizer) without touching any hot files
(Schema.ps1, Invoke-AzureAnalyzer.ps1, New-HtmlReport.ps1, tool-manifest.json).
The implementation contract is documented end to end so per-normalizer adoption
PRs and the Foundation merge can land independently.

## Deliverables

- `docs/design/attack-path.md` — full design covering the six new EdgeRelations
  (TriggeredBy, AuthenticatesAs, DeploysTo, UsesSecret, HasFederatedCredential,
  Declares), per-normalizer edge emission contract for the 10 adopting tools,
  cytoscape + dagre integration sketch, click-to-pivot via an
  fndModel-derived `Map<entityId, Finding[]>` (NOT DOM traversal), tier-aware
  rendering across all four tiers with the 2500-edge shared canvas budget, and
  shared-canvas coordination with Track B (#430) and Track C (#434). Acceptance
  pinned to the 60-second auditor question at every tier.
- `modules/shared/Renderers/AttackPathRenderer.ps1` — three function signatures
  (`New-AttackPathModel`, `ConvertTo-AttackPathDataIsland`,
  `Get-AttackPathBudgetReport`) with empty bodies that throw
  `NotImplementedException` referencing Foundation #435.
- `tests/renderers/AttackPath.Tests.ps1` — seven `-Skip` placeholders covering
  Tier 1-4 rendering plus the cross-track shared-budget contract. Pester run on
  the new file: 0 failed, 7 skipped.
- `CHANGELOG.md` — entry added under [1.2.0 - Unreleased] / Added.

## Decisions taken

1. **Click-to-pivot uses the in-memory finding map**, not DOM traversal.
   Builds `Map<entityId, Finding[]>` once at boot from the existing `fndModel`
   JSON island; node-tap calls `applyFilter()` directly. Keeps lookup O(1) and
   decouples from finding-row markup.
2. **Per-canvas budget, not per-graph.** The 2500-edge cap is shared with
   Tracks B and C. Each layer exports `getRequestedElements(budget)` and the
   canvas controller (Foundation #435) merges + down-samples lowest-severity
   edges proportionally.
3. **Per-normalizer adoption PRs.** Track A does not bundle the 10 adopting
   normalizers into one PR — each tool ships independently after Foundation
   merges, keeping reviewability tight.
4. **Stub functions throw `NotImplementedException`.** Better than silent
   no-ops because anything that wires the renderer in early will fail loudly.

## Open items (deferred)

- Schema enum additions (16 EdgeRelations total) and `-EdgeCollector`
  plumbing — Foundation #435.
- Cytoscape / cytoscape-dagre vendor files — Foundation #435.
- Pode `/api/graph/attack-paths` server endpoint — separate PR after Tier 1
  lands.
- Per-normalizer edge emission — one PR per tool after Foundation merges.
- **FindingRow field extensions** beyond current Schema 2.2 (richer per-edge
  remediation, edge-level docs links, MITRE on edges, etc.) — deferred to
  **#432b** per Round 3 reconciliation on epic #427. Renderer is contractually
  required to degrade gracefully when those fields are absent (see design
  doc § 3a).

## Round 3 contract update (2026-04-21)

After Round 3 reconciliation on epic #427:

- Confirmed: #435 lands the 16 EdgeRelations in Phase 0 (not just the 6 Track A
  consumes). Design doc updated to state this explicitly.
- Added: § 3a "FindingRow field dependency (Round 3 contract)" calling out
  graceful absence semantics for any `(depends on #432b)` field. Renderer must
  never throw, never emit empty strings, never JOIN on a deferred column.
- Added: Pester context "FindingRow field dependency (Round 3 contract)" with
  two `-Skip` cases (current-schema render + deferred-field graceful absence).
- CHANGELOG entry updated to reflect the 16/6 split and the #432b dependency.

PR remains scaffold-only; no hot-file edits.
