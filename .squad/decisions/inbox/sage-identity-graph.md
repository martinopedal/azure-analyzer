# Decision: Identity blast-radius graph (#298) — vanilla SVG + Verlet, no D3

**Date:** 2026-04-22
**Owner:** Sage
**Status:** Implemented in PR for #298

## Choice

Pure vanilla JS + inline SVG with a tiny Verlet force-layout (~3 KB minified-equivalent
source). **No D3 dependency.**

## Why not D3

- The spec allows D3 if total payload stays under 200 KB inlined. D3-force alone (the only
  D3 sub-module we'd actually use) ships ~18 KB minified, and we'd still need to wire the
  drag/zoom and click handlers ourselves.
- For the expected node count (5–80 identity entities — Users / SPs / Groups / Apps /
  AzureResources) a quadratic O(n²) repulsion + linear spring loop converges in ~240
  iterations with no perceptible delay, all in <100 lines of code.
- Avoiding D3 keeps the report a single self-contained HTML file with zero supply-chain
  surface area — consistent with the "no CDN, inline everything" project rule and with the
  existing report's pattern (no JS deps anywhere else in the report).

## Empty-state threshold

5 nodes (per spec). Fewer than 5 → render a neutral "Identity graph unavailable" panel
explaining the threshold. The legend is hidden in the empty state to avoid visual noise.

## Edge synthesis

The current `entities.json` v3.1 envelope ships nodes but not yet typed edges. For the
generator path we synthesize `HasRoleOn` edges from identity-typed entities (User /
ServicePrincipal / Group / Application) to AzureResource entities sharing the same
`SubscriptionId`. This is a temporary heuristic — it gives a plausible blast-radius
visualisation today and will be replaced when `EntityStore.Edges` ships the real
ownership / role assignment / group membership / federated-credential edges.

The sample mockup uses hand-crafted edges that exercise all four edge kinds called out in
the spec.

## Click-to-filter

- Sample mockup: extends the existing `state.entity` filter and `applyFilters()` chain.
- Generator: hides non-matching `<tr>` in `findings-table` via a `display:none` toggle —
  consistent with how the existing `filterTable()` helper already works. A "clear filter"
  link restores the full table.

## Payload

Sample report `samples/sample-report.html`: 36 KB → ~62 KB (inlined renderer + mock data).
Generator-emitted reports: +~5 KB inline JS + ~50–500 bytes of embedded JSON model.
Both well under the 200 KB budget.
