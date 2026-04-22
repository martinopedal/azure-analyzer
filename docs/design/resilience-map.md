# Resilience Map (Track B)

Status: DRAFT (scaffold only). Implementation held until Foundation #435 lands.

Tracks:
- Epic: #427 (large-scale tenant support, Phase 1). Per the Round 3 reconciliation appendix on #427 (AUTHORITATIVE), Phase 1 (#426 + #428 + #429 + #430) opens in parallel only after #435 merges alone.
- Foundation: #435 (Schema HOOKS + EdgeRelations enum: 16 relations total land there, of which this track consumes 6).
- FindingRow fields: #432b (post-#432a audit). #435 does NOT add named FindingRow fields. Anything this design needs beyond the v2 baseline (e.g. RTO/RPO, Remediation, DocsUrl) must degrade gracefully when absent and is gated on #432b.
- Parallel: #428 (Track A, attack-path), #430 (Track V, viewer/canvas), #434 (Track F, parity).
- Hot-file ownership in Phase 0 belongs entirely to #435 (Schema.ps1, Invoke-AzureAnalyzer.ps1, New-HtmlReport.ps1, tools/tool-manifest.json). This track does not edit them.

## 1. Goal

Answer the 60-second auditor question at every viewer tier:

> "What is the blast radius of resource R if its region, zone, vault, or replica peer fails?"

The resilience map is the visual layer that aggregates region pinning, zone redundancy,
backup coverage, failover pairing, and replication targets across a tenant. It consumes
the existing tool output (azqr / wara primary, psrule / defender secondary) and renders
on the same canvas budget as attack-path (#428) and policy-map (#434).

## 2. EdgeRelations (foundation #435)

Foundation #435 lands 16 new EdgeRelations enum values total. This track consumes 6 of
them (the resilience subset); the remaining 10 are consumed by Tracks A / V / F per
their own designs. This track does not add or modify the enum; it only emits and
renders the 6 relations below.

| Relation | Direction | Primary source | Secondary source | Notes |
|---|---|---|---|---|
| `DependsOn` | resource -> resource | azqr (deps), wara (deps) | psrule (rule-derived) | ARM/Bicep/Terraform or runtime-detected dependency. Drives blast-radius traversal. |
| `RegionPinned` | resource -> region | azqr | wara | Single-region with no failover peer. Edge weight = criticality tier. |
| `ZonePinned` | resource -> zone | azqr | wara | Pinned to a single AZ within region. |
| `BackedUpBy` | resource -> RecoveryServicesVault | azqr | defender | Vault + policy linkage. Absence = uncovered. |
| `FailsOverTo` | resource -> resource | wara | azqr | ASR pair, SQL failover group, Traffic Manager priority pair. |
| `ReplicatedTo` | resource -> resource_or_region | wara | azqr | Geo-replication target (Storage GRS, SQL geo-replica, Cosmos region). |

Source priority: azqr / wara are PRIMARY (well-known resilience scanners). psrule / defender
contribute SECONDARY signals when primary sources are silent. Conflicts resolved by
primary-wins; secondary annotates with `Provenance` only.

This track does NOT add the enum values; that is Foundation #435's job. This track only
emits and renders them.

## 3. Rendering

### 3.1 Heatmap layout

- Per-region grid: regions on X axis, scope (mgmt-group / sub / RG) on Y axis.
- Cells colored by composite resilience score:
  - red: unpinned + no backup + no replica
  - orange: 1 of 3 controls present
  - yellow: 2 of 3
  - green: 3 of 3 + zone-redundant
- Cell fill DENSITY encodes backup coverage fraction (0-100%).
- Per-zone sub-grid expands inline on cell click (Tier 1 / Tier 2 only).

### 3.2 Edge styling

- `DependsOn` edges: solid, weight by tier.
- `FailsOverTo` edges: dashed, double-headed, color-matched to source region.
- `ReplicatedTo` edges: dotted, single-headed, color-matched to target region.
- `BackedUpBy` edges: hidden by default; toggle reveals fanned edges to each vault.

### 3.3 Recovery objective overlay

- If tool output exposes `RecoveryTimeObjective` / `RecoveryPointObjective`, render as
  a tooltip badge on the resource node.
- ABSENCE IS GRACEFUL: no badge, no warning, no broken layout. The map MUST render
  identically when RTO/RPO fields are missing.
- **Depends on #432b** for any named FindingRow field carrying RTO/RPO/Remediation/
  DocsUrl. #435 (Phase 0) ships schema HOOKS only and does NOT add these field names.
  Until #432b lands, the renderer reads RTO/RPO opportunistically from raw tool output
  via the entity `RawProperties` bag, treats every absence as the empty case, and never
  hard-codes a field name from the v2 envelope. When #432b adds canonical fields, the
  renderer prefers the canonical field, then falls back to `RawProperties`, then to
  silent absence. No throw, no warn, no layout shift in any of the three states.

### 3.4 Tier-aware rendering (parity with #428, #430)

| Tier | Edge cap (shared) | Resilience behavior |
|---|---|---|
| 1 | 2500 edges total across attack + resilience + policy | Full per-resource rendering, all edges visible. |
| 2 | 2500 (shared) | Collapse children at subscription node; expand-on-click via SQLite query-on-demand. |
| 3 | 2500 (shared) | Aggregate to mgmt-group; resilience reduces to per-region heatmap cells only, no edges. |

The 2500 cap is SHARED across all three graph layers. Resilience yields edges first when
the budget is exceeded (priority: attack-path > policy > resilience), but heatmap cells
are NEVER suppressed.

## 4. Data flow

```
Tool output (azqr / wara / psrule / defender)
  -> Wrapper (v1 envelope, unchanged)
  -> Normalizer (-EdgeCollector adoption, per-tool PRs after Foundation)
  -> EntityStore (entities.json + edges)
  -> ResilienceMapRenderer (this track)
  -> HTML report (read-only consumer of entities.json)
```

Per-tool normalizer adoption ships in separate PRs after #435 merges. This PR adds the
renderer skeleton only.

## 5. Acceptance criteria

- [ ] Auditor can answer "blast radius of resource R" within 60 seconds at Tier 1, 2, and 3.
- [ ] All 6 edge relations render with the styling above when present in entities.json.
- [ ] RTO/RPO overlay renders when present, absent gracefully when not.
- [ ] Heatmap cell color and density match the composite-score table in 3.1.
- [ ] Shared canvas budget honored: resilience yields edges (not cells) when over cap.
- [ ] Pester baseline (842/842) preserved. New renderer tests added under `tests/renderers/`.
- [ ] No edits to Schema.ps1, Invoke-AzureAnalyzer.ps1, New-HtmlReport.ps1, or tool-manifest.json
      in this PR (those land via Foundation #435 and per-tool follow-ups).

## 6. Out of scope (this PR)

- Normalizer `-EdgeCollector` adoption (per-tool PRs after Foundation).
- Schema enum additions (Foundation #435; 16 relations land there, this track consumes 6).
- Named FindingRow field additions for RTO/RPO/Remediation/DocsUrl (deferred to #432b
  post-#432a audit; this track reads opportunistically with graceful absence).
- HTML report wiring (after renderer ships; New-HtmlReport.ps1 owned by #435 in Phase 0).
- Cross-tenant resilience comparison (later phase).
