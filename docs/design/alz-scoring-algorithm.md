# ALZ MG-Hierarchy Fuzzy-Match Scoring Algorithm

Status: DESIGN (locked Round 2, reconfirmed by Round 3 reconciliation on epic #427, 2026-04-21).
Issue: #431
Companion: `policy-enforcement.md`
Authoritative source: "Round 3 reconciliation" appendix on epic #427 (3-of-3 rubberduck consensus: rd-opus47 + rd-gpt53codex + rd-goldeneye, APPROVE_WITH_FIXES). The weights, thresholds, manifest audit shape, and `-AlzReferenceMode` flag below are locked by that appendix.

## Purpose

Decide, deterministically, whether a tenant's management-group hierarchy is "ALZ-shaped" enough to activate scope-aware ALZ policy suggestions.

The output is a single `score` in [0.0, 1.0] plus four component scores, written to `report-manifest.json` for auditability. The user can override with `-AlzReferenceMode`.

## ALZ reference hierarchy

```
Root (Tenant Root Group)
|-- Platform
|   |-- Management
|   |-- Connectivity
|   |-- Identity
|-- Landing Zones
|   |-- Corp
|   |-- Online
|   |-- Confidential Corp
|   |-- Confidential Online
|-- Decommissioned
|-- Sandbox
```

Source: github.com/Azure/Enterprise-Scale, ALZ canonical hierarchy. Vendored SHA-pinned in the implementation PR.

## Weighted formula

```
score =   0.40 * exactNameComponent
        + 0.30 * structuralComponent
        + 0.20 * renamesComponent
        + 0.10 * levenshteinComponent
```

Each component is in [0.0, 1.0]. The total is in [0.0, 1.0].

### Component 1: exact name (weight 0.40)

Fraction of the ALZ canonical node names found verbatim (case-insensitive, whitespace-trimmed) anywhere in the tenant hierarchy at the expected depth.

Canonical name set (10 nodes): `Root`, `Platform`, `Management`, `Connectivity`, `Identity`, `Landing Zones`, `Corp`, `Online`, `Decommissioned`, `Sandbox`.

`exactNameComponent = (matchedCanonicalNodes / 10)`

### Component 2: structural (weight 0.30)

Two structural checks averaged:

1. Depth-correct: the matched node sits at the same depth (distance from Root) as in the ALZ reference. Fraction of matched nodes that are depth-correct.
2. Child-count within +/- 1 of the reference for each matched non-leaf node.

`structuralComponent = mean(depthCorrectFraction, childCountFraction)`

### Component 3: common renames (weight 0.20)

Curated rename table (case-insensitive). A tenant node that does not match a canonical name verbatim still counts under this component if it appears in the rename map at the correct depth.

| Canonical            | Common renames                                              |
|----------------------|-------------------------------------------------------------|
| Platform             | Core, Shared Services, SharedServices, Shared, Hub          |
| Landing Zones        | Workloads, Application, Applications, LZ, LandingZones      |
| Corp                 | Internal, Private, Enterprise                               |
| Online               | External, Public, Internet                                  |
| Decommissioned       | Decom, Retired, Archive                                     |
| Sandbox              | Dev, Development, NonProd, Playground                       |
| Connectivity         | Network, Networking, Hub-Network, HubNetwork                |
| Identity             | IAM, AAD, Entra                                             |
| Management           | Mgmt, Operations, Ops, Monitoring                           |

`renamesComponent = (renameMatchedNodes / renameCandidateNodes)` where `renameCandidateNodes` is the count of canonical nodes not already counted by Component 1.

### Component 4: Levenshtein remainder (weight 0.10)

For tenant nodes still unmatched after Components 1 and 3, compute Levenshtein distance to each canonical name. A distance of <= 2 counts as a match.

`levenshteinComponent = (lev<=2 matches / remaining canonical nodes)`

If `remaining canonical nodes == 0`, the component is 1.0 (degenerate; everything already matched).

## Threshold semantics

| Score range  | Action                                                                               |
|--------------|--------------------------------------------------------------------------------------|
| >= 0.80      | Full activation. ALZ suggestions render with the standard `ALZ` pill.                |
| 0.50 to 0.79 | Partial activation. ALZ suggestions render with a `partial-match` badge alongside.   |
| < 0.50       | Fallback. ALZ suggestions suppressed; AzAdvertizer-only path.                        |

## CLI flag behavior

`-AlzReferenceMode {Auto|Force|Off}` (default: `Auto`)

- `Auto`: compute score, apply threshold semantics above.
- `Force`: compute score for the manifest, but always activate ALZ suggestions at full strength. A `force-overridden` badge renders next to ALZ pills if score < 0.80.
- `Off`: do not load the ALZ catalog or compute the score. `report-manifest.json` records `{"mode": "Off"}` only.

## Auditability

Every run writes the following block to `report-manifest.json`:

```json
{
  "policy": {
    "alz": {
      "mode": "Auto",
      "score": 0.82,
      "components": {
        "exactName": 0.40,
        "structural": 0.24,
        "renames": 0.18,
        "levenshtein": 0.00
      },
      "matchedHierarchy": [
        { "tenantNode": "TenantRoot",   "canonical": "Root",          "matchType": "exact" },
        { "tenantNode": "Platform",     "canonical": "Platform",      "matchType": "exact" },
        { "tenantNode": "Workloads",    "canonical": "Landing Zones", "matchType": "rename" }
      ],
      "catalogVintage": "2025-10-02",
      "catalogSha": "def56789abcdef..."
    }
  }
}
```

## Worked examples

### Example A: Canonical ALZ tenant (expected score ~1.00)

Tenant hierarchy:

```
Root
|-- Platform
|   |-- Management
|   |-- Connectivity
|   |-- Identity
|-- Landing Zones
|   |-- Corp
|   |-- Online
|-- Decommissioned
|-- Sandbox
```

- exactName: 9 of 10 canonical nodes (missing only `Confidential Corp`/`Confidential Online`, which are not in the canonical set of 10) -> 9/10 = 0.90 -> contribution 0.36.
- structural: depth-correct 1.00, child-count 1.00 -> 1.00 -> contribution 0.30.
- renames: no remaining canonical nodes; degenerate 1.00 -> contribution 0.20.
- levenshtein: degenerate 1.00 -> contribution 0.10.

`score = 0.36 + 0.30 + 0.20 + 0.10 = 0.96` -> full activation.

### Example B: Renamed ALZ tenant (expected score ~0.80)

Tenant hierarchy:

```
TenantRoot
|-- Core
|   |-- Mgmt
|   |-- Network
|   |-- IAM
|-- Workloads
|   |-- Internal
|   |-- External
|-- Decom
|-- Dev
```

- exactName: only `Root` (assuming `TenantRoot` is mapped to `Root` by alias rule) -> 1/10 = 0.10 -> contribution 0.04.
- structural: depth-correct on all 9 mappable nodes, child-counts within +/-1 -> 1.00 -> contribution 0.30.
- renames: 8 of remaining 9 nodes match the rename table (Core/Mgmt/Network/IAM/Workloads/Internal/External/Decom/Dev all present) -> 9/9 = 1.00 -> contribution 0.20.
- levenshtein: degenerate 1.00 -> contribution 0.10.

Note: `TenantRoot` -> `Root` is handled as an exact alias in the implementation.

`score = 0.04 + 0.30 + 0.20 + 0.10 = 0.64` if `TenantRoot` not aliased; `0.10 + 0.30 + 0.20 + 0.10 = 0.70` if treated as exact. Either way, partial activation (0.50 to 0.79).

### Example C: Non-ALZ flat tenant (expected score < 0.50)

Tenant hierarchy:

```
Root
|-- ProductionSubs
|-- DevSubs
|-- DataSubs
|-- LegacySubs
```

- exactName: only `Root` -> 1/10 = 0.10 -> contribution 0.04.
- structural: depth correct only for `Root`; child count diverges (4 vs reference 4 at root - actually matches) -> mean(0.25, 1.0) = 0.625 -> contribution 0.19.
- renames: `DevSubs` plausibly matches `Sandbox` rename `Dev` (substring not allowed; whole-word match required) -> 0/9 = 0.00 -> contribution 0.00.
- levenshtein: `ProductionSubs`, `DevSubs`, `DataSubs`, `LegacySubs` all distance > 2 from canonical names -> 0.00 -> contribution 0.00.

`score = 0.04 + 0.19 + 0.00 + 0.00 = 0.23` -> fallback, ALZ suppressed.

## Implementation notes

- Matching is whole-name and case-insensitive; substring matches are explicitly disallowed to keep scoring deterministic.
- Tied matches resolve by depth-then-alphabetical ordering of canonical names.
- The matcher is a pure function. No I/O. Catalog SHA + vintage are passed in by the caller.

## References

- Issue #431 Round 2 Rubberduck Resolutions (locked 2026-04-21).
- ALZ reference hierarchy: github.com/Azure/Enterprise-Scale.
