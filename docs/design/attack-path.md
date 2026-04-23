# Attack-path visualizer (Track A) — design

Status: scaffold. Implementation paused until Foundation PR #435 lands the new
EdgeRelations (16 total, of which Track A consumes 6) and the optional
`-EdgeCollector` normalizer parameter contract.

Issue: #428. Epic: #427. Foundation: #435. Sibling tracks: #430 (resilience), #434 (policy).

> **Round 3 reconciliation (epic #427) is AUTHORITATIVE.** Phase 0 (#435) lands
> schema hooks + the 16 EdgeRelations only. Specific FindingRow field-name
> extensions (e.g. additional remediation / docs / metadata fields beyond the
> current Schema.ps1) are deferred to **#432b** (post-#432a audit) and **must
> not** be assumed by this design. Anything in this doc that names a FindingRow
> field outside the current schema is tagged **(depends on #432b)** and the
> renderer is required to degrade gracefully when those fields are absent.

## 1. Goal

Answer the 60-second auditor question at every tier:

> "What is the attack path to privileged identity Z?"

Today the data exists in `entities.json` and `results.json` but reviewers stitch
paths together by hand across Entra, Azure Resource Graph, GitHub Actions, ADO,
and IaC. Track A renders a navigable graph directly from the v3 entity store.

## 2. New edge relations

Foundation #435 adds **16 new EdgeRelations** to `modules/shared/Schema.ps1`
`EdgeRelations` enum in Phase 0. Track A consumes the **6** listed below; the
other 10 are claimed by Tracks B (#430), C (#434), and adjacent work. This
track does not touch Schema.ps1 — that file is owned by #435 in Phase 0.

| EdgeRelation             | Emitted by (primary normalizer)              | Raw data source                                           |
|--------------------------|----------------------------------------------|-----------------------------------------------------------|
| `TriggeredBy`            | actionlint, gh-actions, ado-pipelines        | workflow `on:` triggers, pipeline `trigger:` blocks       |
| `AuthenticatesAs`        | maester, entra-export, ado-pipelines         | federated cred binding, MI assignment, SPN auth context   |
| `DeploysTo`              | gh-actions, ado-pipelines, bicep, terraform  | deployment job target, `azureSubscription`, provider cfg  |
| `UsesSecret`             | gh-actions, ado-pipelines, kvscanner         | `${{ secrets.* }}`, `$(var)`, key vault refs              |
| `HasFederatedCredential` | maester, entra-export                        | App registration federatedIdentityCredentials             |
| `Declares`               | bicep, terraform, arm, checkov               | IaC resource declarations -> AzureResource entity         |

## 3. Edge emission contract per normalizer

Foundation #435 introduces the optional `-EdgeCollector` parameter. The
orchestrator introspects each normalizer's param block; normalizers that
declare it receive a collector instance, the other 30+ continue unchanged.

Per-normalizer adoption (independently mergeable PRs after Foundation):

| Normalizer       | Edges emitted                                                  | Notes                                                                 |
|------------------|----------------------------------------------------------------|-----------------------------------------------------------------------|
| actionlint       | `TriggeredBy`, `UsesSecret`                                    | Workflow -> trigger source; Workflow -> Secret reference              |
| gh-actions       | `TriggeredBy`, `DeploysTo`, `UsesSecret`, `AuthenticatesAs`    | Job -> Subscription via OIDC login; Workflow -> Secret                |
| ado-pipelines    | `TriggeredBy`, `DeploysTo`, `UsesSecret`, `AuthenticatesAs`    | Service connection -> SPN; pipeline -> environment                    |
| maester          | `HasFederatedCredential`, `AuthenticatesAs`                    | App -> FederatedCred -> Workflow/Repo issuer-subject                  |
| entra-export     | `HasFederatedCredential`, `AuthenticatesAs`                    | App -> FederatedCred; SPN -> Role/Group                               |
| bicep            | `Declares`, `DeploysTo`, `UsesSecret`                          | IaCFile -> AzureResource; resource -> KV secretReference              |
| terraform        | `Declares`, `DeploysTo`, `UsesSecret`                          | Same shape as bicep                                                   |
| arm              | `Declares`, `DeploysTo`, `UsesSecret`                          | Same shape as bicep                                                   |
| checkov          | `Declares`                                                     | Re-affirms IaC declarations with policy outcome attached              |
| kvscanner        | `UsesSecret`                                                   | Resource -> KV secret access policy or RBAC binding                   |

Edges from non-adopting normalizers continue to be inferred by
`IdentityCorrelator.ps1` heuristics (existing v2 behaviour). Adoption PRs only
upgrade precision; they never break the baseline.

## 3a. FindingRow field dependency (Round 3 contract)

Track A relies only on FindingRow fields that exist in the **current** Schema
(`Entity`, `EntityType`, `Severity`, `RuleKey`, `Title`, `Tool`, `Subscription`,
`Status`, `Remediation`, `LearnMoreUrl`, `DeepLinkUrl`, `EntityRefs`). These
are stable in Schema 2.2 and do not depend on #432b.

Any future enhancement — for example richer per-edge remediation snippets, an
attack-path-specific `DocsUrl`, MITRE-tagged edge tooltips, or per-edge
`Impact`/`Effort` — is **(depends on #432b)** and is not in scope for this PR.
The renderer **must degrade gracefully** when those fields are absent:

* Missing optional field on a node -> render the node, omit the corresponding
  tooltip row. Never throw, never empty-string in the JSON.
* Missing optional field on an edge -> render the edge with relation label only.
* `New-AttackPathModel` reads with `?? $null` semantics and `ConvertTo-Json`
  with `-Compress` so absent properties are simply not emitted into the data
  island. The browser renderer treats `undefined` as "section not present".
* No tier-2/3/4 SQL query joins on a deferred field. SQL projections list
  current-schema columns only; deferred fields will be added in a #432b
  follow-up PR alongside their SQL migration.

This contract is enforced by the Pester scaffold: the
`graceful absence of deferred FindingRow fields` case (added below to the
`-Skip` set) will become live once #432b lands.

## 4. Renderer integration sketch

### Data island

The HTML report ships a single JSON data island per canvas:

```html
<script type="application/json" id="atkPathModel">
{
  "schemaVersion": "3.0",
  "tier": 1,
  "truncated": false,
  "budget": { "edgeCap": 2500, "edgesUsed": 1840 },
  "nodes": [ { "data": { "id": "...", "type": "ServicePrincipal", "label": "...", "severity": "high" } } ],
  "edges": [ { "data": { "id": "e1", "source": "...", "target": "...", "relation": "AuthenticatesAs" } } ]
}
</script>
```

Node and edge shapes follow Cytoscape's `elements` schema directly. No
transformation in the browser beyond colour/size mapping.

### Library choice

* `cytoscape.js` for the canvas (BSD/MIT, ~340 KB minified).
* `cytoscape-dagre` layout for ranked DAG flow (severity sink at the right).
* Both vendored under `assets/vendor/` by Foundation #435. Track A does not
  add vendor files.

Layout: `dagre` with `rankDir: LR`, ranker `tight-tree`. Falls back to `cose`
when `dagre` reports a cycle (resilience track may introduce cycles).

### Click-to-pivot mechanism

A `Map<entityId, Finding[]>` is built once at boot from the existing `fndModel`
JSON island (already shipped). On node click the renderer reads the map and
filters the findings table via the existing `applyFilter()` path. The renderer
never walks the DOM to discover findings, which keeps lookup O(1) and avoids
coupling to row markup.

```js
const fndByEntity = new Map();
for (const f of fndModel.findings) {
  if (!fndByEntity.has(f.entity)) fndByEntity.set(f.entity, []);
  fndByEntity.get(f.entity).push(f);
}
cy.on('tap', 'node', e => pivotToFindings(fndByEntity.get(e.target.id()) ?? []));
```

## 5. Tier-aware rendering

| Tier | Source                   | Strategy                                                                            |
|------|--------------------------|-------------------------------------------------------------------------------------|
| 1    | inline `atkPathModel`    | Full canvas render, dagre layout, capped at 2500 edges shared canvas budget.        |
| 2    | SQLite-WASM hydrate      | Top-N severity-ranked seed (200 nodes); on node click expand 1 hop via SQL query.   |
| 3    | Web worker fetch         | Worker streams viewport-aware tiles; main thread only paints visible bbox.          |
| 4    | Pode `/api/graph/attack-paths` | Server runs recursive CTE in SQLite, returns capped subgraph + `truncated=true`. |

Cap is **per canvas, not per graph**. The same 2500-edge budget is shared with
Track B (resilience #430) and Track C (policy #434). When all three layers are
toggled on, each layer reports its requested edge count; the renderer
proportionally down-samples the lowest-severity edges from each layer so the
combined draw stays within budget. Tier 4 enforces the cap server-side.

## 6. Interaction with Track B and Track C

* **Shared canvas, shared budget.** One `cytoscape` instance, three element
  collections keyed by `data.layer` (`attack` / `resilience` / `policy`).
* **Layer toggle UI** lives in the canvas header. Default: attack on, others off.
* **Edge precedence:** when an edge appears in multiple layers (e.g. policy
  `Declares` + attack `Declares`), the severity-max wins for colour, but layer
  badges stack on the edge label.
* **Coordination contract:** each layer module exports
  `getRequestedElements(budget)`, the canvas controller (Foundation) merges
  responses, applies the shared cap, and hands a single elements array to dagre.

## 7. Acceptance

The visualizer is acceptable when an auditor can answer the 60-second question
at every tier:

* **Tier 1:** open the report, type the identity name in the canvas search,
  read the highlighted path end-to-end without leaving the page.
* **Tier 2:** same flow, with the renderer issuing one SQLite-WASM expand on
  click and returning within 250 ms.
* **Tier 3:** same flow, viewport-aware tiling never blocks the main thread for
  more than one frame (16 ms budget).
* **Tier 4:** Pode endpoint returns the subgraph in <1 s for a 100k-edge tenant
  and surfaces `truncated=true` when the cap is hit.

Pester baseline must remain green (≥1637 total, ≥1602 passed) + new renderer tests.

## 8. Out of scope for this PR

* Schema enum additions — all 16 new EdgeRelations land in Foundation #435.
* `-EdgeCollector` plumbing in the orchestrator (Foundation #435).
* Per-normalizer adoption PRs (one PR per tool, after Foundation merges).
* Cytoscape / dagre vendor files (Foundation #435).
* Server-side recursive CTE endpoint (separate Pode PR after Tier 1 lands).
* **FindingRow field extensions** (e.g. richer remediation, edge-level docs
  links, MITRE tagging on edges) — deferred to **#432b** per Round 3
  reconciliation on epic #427. The design above lists the few hypothetical
  enhancements that would benefit from those fields and tags each with
  **(depends on #432b)**. Implementation here is restricted to the current
  Schema 2.2 FindingRow surface.
