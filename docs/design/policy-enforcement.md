# Policy Enforcement Visualization + AzAdvertizer + ALZ (Track C)

Status: DESIGN (scaffold). Implementation held until Phase 1 MVP ships and the Phase 2 validation gate from epic #427 passes (2 auditor walkthroughs + 2 architect workflows + 1 real high-volume tenant dataset run, evidence posted on epic #427).

Issue: #431
Foundation dependency: #435 (4 new edge relations land there, not here)
Epic: #427 (see "Round 3 reconciliation" appendix — AUTHORITATIVE)
Phase: 2 (gated on the validation evidence above; this PR stays DRAFT until the gate passes)

## Goals

1. Render policy enforcement as a first-class graph layer alongside attack-path (#428) and resilience (#429), reusing the same tier-aware Cytoscape renderer.
2. Cross-reference findings against curated policy catalogs (AzAdvertizer + ALZ) so an architect can see which built-in or ALZ policy would prevent a class of finding, with one-click drill-through.
3. Detect when a tenant's MG hierarchy approximates the ALZ reference and activate stronger, scope-aware ALZ suggestions in addition to the generic AzAdvertizer ones.

Out of scope for this PR:

- Vendoring the actual AzAdvertizer or ALZ JSON catalogs (data ingestion lands in a follow-up after the algorithm and renderer skeletons are reviewed).
- Schema.ps1 edits (handled in Foundation PR #435).
- AzGovViz normalizer edits (per-tool PR after Foundation merges).
- Hot-file edits to Invoke-AzureAnalyzer.ps1, New-HtmlReport.ps1, tool-manifest.json.

## Architecture overview

```
AzGovViz wrapper  -->  AzGovViz normalizer  -->  v3 entities + 4 new edges
                                                       |
                                                       v
                       PolicyEnforcementRenderer  --(Cytoscape graph layer)
                                                       |
            +------------------------------------------+
            |                                          |
   AlzMatcher (hierarchy fuzzy-match)        AzAdvertizerLookup (finding-to-policy)
            |                                          |
            +-------------------+----------------------+
                                |
                                v
                  Finding decoration: SuggestedPolicies[]
                                |
                                v
               HTML report pills: ALZ / AzAdvertizer / built-in
                  + report-manifest.json (auditable scores)
```

## New edges (emitted from the AzGovViz normalizer in the per-tool PR)

The four edge relations themselves are added to `Schema.ps1` in Foundation PR #435. This PR only documents how the AzGovViz normalizer will populate them.

| EdgeRelation     | Source entity        | Target entity                 | Meaning                                                    |
|------------------|----------------------|-------------------------------|------------------------------------------------------------|
| PolicyAssignedTo | PolicyAssignment     | Scope (MG, Subscription, RG)  | An assignment is bound to a scope                          |
| PolicyEnforces   | PolicyDefinition     | Control target (resource type)| A definition enforces a control on a target type           |
| ExemptedFrom     | PolicyExemption      | PolicyAssignment              | An exemption removes an assignment from a scope or resource|
| InheritsFrom     | Scope (child)        | Scope (parent)                | A scope inherits assignments from its parent               |

Edges are emitted by the AzGovViz normalizer. Each edge carries provenance (`SourceTool=azgovviz`, `EmittedAt`).

## Compliance heatmap

Rendered at three scopes:

- Management Group: percentage of in-scope subscriptions whose resources are compliant with all assignments inherited at or above the MG.
- Subscription: percentage of in-scope resources compliant with all effective assignments.
- Resource Group: percentage of contained resources compliant.

Color scale (5 buckets, sequential):

- 100 percent compliant: green
- 90 to 99 percent: light green
- 70 to 89 percent: yellow
- 40 to 69 percent: orange
- below 40 percent: red

Inheritance is rendered as dashed edges. Exemptions are rendered with a distinct color and surface the exemption expiry on hover. Click-through on a non-compliant resource reveals the failing assignments and their definitions.

## AzAdvertizer integration

- Catalog vendored from github.com/JulianHayward/AzAdvertizer at a SHA-pinned commit.
- No live fetch, no telemetry to azadvertizer.net.
- Lookup is deterministic: finding-type to candidate policies via `finding-to-policy-map.json`.
- Up to 3 suggestions per finding, ranked by curator-assigned priority.
- UI pill: `AzAdvertizer` (neutral blue).

## ALZ integration

- Catalog vendored from github.com/Azure/Enterprise-Scale at a SHA-pinned commit.
- ALZ suggestions are activated only when the tenant MG hierarchy fuzzy-matches the ALZ reference with score >= 0.50. See `alz-scoring-algorithm.md` for the algorithm.
- ALZ suggestions are scope-aware: a `Corp`-scoped policy is only suggested for findings under the matched `Corp` MG.
- UI pill: `ALZ` (Azure-Scale purple), distinct from AzAdvertizer and from `built-in`.
- Deep link to the Enterprise-Scale repo for the policy definition.

## UI pills

Three distinct pill styles render on each finding:

- `built-in` (gray): policy already assigned somewhere in the tenant.
- `AzAdvertizer` (blue): policy known to AzAdvertizer, not assigned in tenant.
- `ALZ` (purple): policy from the ALZ reference, scope-aware suggestion.

Pills appear on the finding card and on the policy-enforcement graph node tooltip.

## Catalog-vintage banner

Every report renders a banner near the top of the policy section:

```
Catalog vintage: AzAdvertizer 2025-09-14 (SHA abc1234), ALZ 2025-10-02 (SHA def5678).
Suggestions may be stale. Refresh cadence: quarterly, maintainer-driven.
```

Refresh is intentionally manual: the SHA-pin is the security boundary, not automated ingestion.

## CLI flag

`-AlzReferenceMode {Auto|Force|Off}`

- Auto (default): run the matcher; activate ALZ suggestions if score >= 0.50.
- Force: activate ALZ suggestions regardless of score; the matched mapping with the highest individual scores is used.
- Off: skip ALZ entirely; AzAdvertizer suggestions only.

## report-manifest.json additions

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
      "matchedHierarchy": [ ... ],
      "catalogVintage": "2025-10-02",
      "catalogSha": "def56789abcdef..."
    },
    "azAdvertizer": {
      "catalogVintage": "2025-09-14",
      "catalogSha": "abc12345fedcba..."
    }
  }
}
```

## Module layout

```
modules/shared/Policy/
  PolicyEnforcementRenderer.ps1   # Cytoscape JSON emitter for the policy layer
  AlzMatcher.ps1                  # Hierarchy fuzzy-match scorer (see alz-scoring-algorithm.md)
  AzAdvertizerLookup.ps1          # Deterministic finding-type to policy lookup
  finding-to-policy-map.json      # Curated mapping table (schema documented inline)
```

## Testing

- `tests/policy/AlzMatcher.Tests.ps1`: 3 worked-example fixtures from the algorithm doc, currently `-Skip` until catalog ingestion lands.
- Renderer + AzAdvertizer lookup tests follow in the implementation PR.
- Pester baseline (≥1637 total, ≥1602 passed) MUST remain green for this scaffold PR.

## Security invariants

- HTTPS-only catalog fetch, SHA-pinned, host allow-list (github.com).
- No telemetry sent off-box.
- Mapping table lives in the repo, auditable.
- All emitted JSON passes through `Remove-Credentials` before write.

## Acceptance (this PR only)

- [x] Design doc landed at `docs/design/policy-enforcement.md`.
- [x] ALZ scoring algorithm doc landed at `docs/design/alz-scoring-algorithm.md`.
- [x] Stub modules with function signatures only.
- [x] Mapping table skeleton with 5 to 10 sample entries.
- [x] Pester placeholders (`-Skip`).
- [x] Pester baseline still green.

Full acceptance from issue #431 lands in follow-up PRs after Foundation #435.
