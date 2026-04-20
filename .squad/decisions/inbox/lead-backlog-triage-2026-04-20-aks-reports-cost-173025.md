# Lead backlog triage: Reports + Cost + AKS streams

- **Author:** Lead
- **Date:** 2026-04-20
- **Scope:** 16 open `squad`-labeled issues across three streams (Reports 5, Cost 4, AKS 7)
- **Type:** Read-only triage + decomposition + execution sequencing
- **Status:** Inbox - awaiting Scribe promotion to `decisions.md`

---

## 1. Executive summary

- **Highest leverage:** **AKS K8s-auth stream** (#236 / #240 / #241 / #242). It unblocks the only Kubernetes posture coverage we have (kubescape, falco, kube-bench) on real-world AAD-integrated and private clusters. Today those wrappers only run when the local box can mint a kubeconfig via `az aks get-credentials`. Shipping Phase 1 alone (#240) materially expands the addressable surface.
- **Most ready to ship (lowest risk, smallest size, zero schema work):** Reports `#226` (severity strip) and Cost `#233` (Infracost). Both are research-greenlit, isolated, no schema bump, no orchestrator change.
- **Biggest:** AKS auth umbrella (#236) at L+M+L for the three phases, plus the Performance Efficiency umbrella (#231 = #237 + #238 + #239) which spawns a new shared `KqlQuery.ps1` helper consumed by future cost work.
- **Recommended order:** start a wide parallel-safe batch (#226, #233, #240, #238). Resolve the four schema design questions in Section 5 in parallel, then unlock the second batch (#228, #237, #239, #241, #229). Save #227, #230, #232, #234, #242 for batches 3 and 4 once their preconditions are met.
- **vNEXT alignment:** every schema-touching item (#227, #228, #232b, #234b) must land BEFORE the vNEXT minor bump so the public `FindingRow` shape is locked. Pure additive wrappers and JS-only report tweaks can land either side.

---

## 2. Per-issue triage table

| # | 1-line title | Owner | Stream | Effort | Dependency | Recommendation | Rationale |
|---|---|---|---|---|---|---|---|
| 226 | Severity totals strip on every findings tab | Sentinel | Reports | S | none | **READY** | Pure JS aggregation off existing `FindingRow.Severity`, isolated section of `report-template.html`, zero schema change. |
| 227 | Top recommendations by impact panel | Sentinel | Reports | M | needs `RuleId` design decision (Brady Q2) | **NEEDS-DESIGN** | Sloan flagged: aggregating on `Title` is noisy, but adding `RuleId` to `FindingRow` is a vNEXT-relevant schema bump. Decide before code. |
| 228 | RemediationUrl column with deep-links | Atlas+Sentinel | Reports | S | needs URL-field design decision (Brady Q1) | **NEEDS-DESIGN** | `LearnMoreUrl` already exists on `FindingRow` (Schema.ps1 line 197). Decide reuse vs new field before normalizer churn. |
| 229 | Collapsible Tool/Category/Rule/Finding tree | Atlas | Reports | M | should sequence after #226 to avoid `report-template.html` merge conflict | **READY** | Native `<details>/<summary>`, opt-in toggle, no new deps, no schema change. |
| 230 | Framework x tool coverage matrix | Atlas+Forge | Reports | M | needs heatmap-host design decision (Brady Q3); manifest schema bump for `frameworks[]` per tool | **NEEDS-DESIGN** | `Frameworks` field already exists on `FindingRow` and `EntityStub`. Real new work is the manifest bump and choosing between legacy `New-HtmlReport.ps1` vs `report-template.html` host. |
| 231 | Performance Efficiency umbrella | Atlas | Cost (perf) | XL | umbrella over #237 + #238 + #239 | **CLOSE-AS-UMBRELLA** | Already split. Keep as tracking issue; close once all three children merge. Do NOT execute as a single PR. |
| 232 | CI/CD cost telemetry (GH Actions + ADO) | Atlas | Cost | M | 232b blocked on EntityType decision (Brady Q4) | **SPLIT-INTO-2** | 232a (GH Actions billing) READY now. 232b (ADO consumption) needs `AdoProject` EntityType or alias-to-Pipeline call. |
| 233 | Infracost wrapper (Bicep/TF pre-deploy) | Atlas | Cost | S | none | **READY** | Greenfield wrapper, mirrors `Invoke-Trivy.ps1` pattern, Apache-2.0 license, no schema change, no Azure RBAC required. |
| 234 | AKS runtime cost (Karpenter + node util) | Atlas+Sage | Cost | M | 234b blocked on Karpenter EntityType + elevated RBAC decision (Brady Q5); coordinates with #239 on shared `AksDiscovery.ps1` | **SPLIT-INTO-2** | 234a (node-utilization, Reader + Monitoring Reader) READY. 234b (Karpenter consolidation) needs new `KarpenterProvisioner` EntityType and AKS Cluster User Role approval. |
| 236 | AKS auth surfacing umbrella (kubeconfig + kubelogin + WI) | Atlas | AKS | XL | umbrella over #240 + #241 + #242 | **CLOSE-AS-UMBRELLA** | Drake already decomposed into Phase 1/2/3 children. Execute the three children sequentially; close umbrella when Phase 3 lands. |
| 237 | App Insights perf wrapper (KQL) | Atlas | AKS (perf) | M | introduces NEW shared `modules/shared/KqlQuery.ps1`; #239 consumes it | **READY** | Fresh KQL helper plus 3 query JSONs plus normalizer. Land first in Performance Efficiency batch so #239 can build on it. |
| 238 | Azure Load Testing wrapper | Atlas | AKS (perf) | S | none | **READY** | Pure ARM REST against `Microsoft.LoadTestService`, mirrors `Invoke-SentinelCoverage.ps1`. Smallest perf-pillar item. |
| 239 | AKS HPA/VPA rightsizing (Container Insights) | Atlas | AKS (perf) | M | depends on `KqlQuery.ps1` from #237; should lift `AksDiscovery.ps1` out of `Invoke-Kubescape.ps1`; coordinates with #234 | **READY** (after #237) | Largest perf child. Refactor of Kubescape discovery is in scope and lands in same PR. |
| 240 | Explicit kubeconfig/namespace params for K8s wrappers | Forge | AKS (auth) | M | none. Phase 1 of #236 | **READY** | All-additive params, default behaviour preserved, fixture-mockable. Spawn now. |
| 241 | kubelogin AAD auth modes for AKS wrappers | Atlas | AKS (auth) | M-L | depends on #240 merge. Phase 2 of #236 | **READY** (after #240) | Adds `-KubeAuthMode` enum, kubelogin convert step post `az aks get-credentials`. |
| 242 | In-cluster workload identity auth mode | Atlas | AKS (auth) | L | depends on #241 merge. Phase 3 of #236 | **READY** (after #241) | Extends `-KubeAuthMode` enum with `in-cluster`, branches on `/var/run/secrets` presence. Largest of the three but lowest urgency. |

---

## 3. Identified clusters and shared work

### Cluster A: K8s auth ladder (#236 umbrella, three sequential children)
- `#240 -> #241 -> #242` is **strictly sequential**, not parallel. Each phase extends an enum and branches added by the prior. They share the same param block in `Invoke-AzureAnalyzer.ps1`, the same wrapper bodies (`Invoke-Kubescape.ps1`, `Invoke-Falco.ps1`, `Invoke-KubeBench.ps1`), and the same `PERMISSIONS.md` table rows. Merging them out of order forces three-way rebase pain.
- **Action:** keep #236 open as the tracking umbrella; execute #240, #241, #242 in order. Close #236 when #242 merges.

### Cluster B: Performance Efficiency umbrella (#231 over #237 + #238 + #239)
- `#237` ships a NEW shared module `modules/shared/KqlQuery.ps1`. **`#239` depends on this helper.** Land #237 first so #239 can consume it.
- `#238` is independent of the helper (pure ARM REST). Parallel-safe with #237.
- `#239` also lifts `AksDiscovery.ps1` out of `Invoke-Kubescape.ps1` and refactors Kubescape to call it. **`#234b` should consume the same `AksDiscovery.ps1`.** Sequence: #237 -> (#239 + #234) where #239 introduces `AksDiscovery.ps1` and #234 reuses it.
- **Action:** close #231 as a tracking umbrella once #237, #238, #239 land. Do NOT execute the umbrella as a single PR.

### Cluster C: Reports template surface (#226 + #229 + #228 + #227 + #230)
- All five touch `report-template.html` and/or `New-HtmlReport.ps1`. Concurrent PRs will conflict on the same `<style>` and `renderFindingsTable` regions.
- **Action:** sequence them. Land the smallest first (#226), then #229 (tree toggle), then #228 (column add) once URL field is decided, then #227 once `RuleId` is decided, then #230 last.
- Schema-relevant subset: only #228 and #227 touch `FindingRow`. Both must clear the vNEXT cutoff.

### Cluster D: ADO + Karpenter EntityType expansion (#232b + #234b)
- Both child issues blocked on the same kind of decision: should we add new `EntityType` enum values (`AdoProject`, `KarpenterProvisioner`) or alias to existing types (`Pipeline`, `AzureResource`)?
- **Action:** batch the answers in one Brady decision. If both get added, ship them together in a small Schema.ps1 PR before the dependent wrapper PRs land.

### Cluster E: Manifest schema bump (#230)
- `tools/tool-manifest.json` does not currently carry a `frameworks[]` array per tool. #230 needs that.
- Light pre-work item that also opens the door to a manifest-level `category` / `pillar` field if we want to drive the framework matrix from manifest defaults.

---

## 4. Recommended execution order

### Batch 1 (spawn now, fully parallel-safe, four PRs in flight)

| Slot | Issue | Owner | Why parallel-safe |
|------|-------|-------|-------------------|
| 1 | **#226** severity strip | Sentinel | JS-only, isolated `renderFindingsTable` section, no schema |
| 2 | **#233** Infracost wrapper | Atlas | Greenfield wrapper file + manifest entry, no shared module touch |
| 3 | **#240** K8s kubeconfig/namespace params | Forge | Touches orchestrator + K8s wrappers, owned by Forge (avoids Atlas conflict) |
| 4 | **#238** Load Testing wrapper | Atlas | Greenfield wrapper file, no shared module touch, no overlap with #233 |

Atlas runs #233 and #238 sequentially in their own worktree (or two worktrees) to keep diff scopes clean. Sentinel and Forge run independently.

### Batch 2 (spawn when Batch 1 merges + Brady answers Q1, Q2)

| Slot | Issue | Owner | Why now |
|------|-------|-------|---------|
| 5 | **#237** App Insights perf wrapper + `KqlQuery.ps1` | Atlas | Unlocks #239; isolated new module |
| 6 | **#229** collapsible tree (after #226) | Atlas | Sequenced after #226 to avoid template conflict |
| 7 | **#228** deep-link column (after Brady Q1) | Atlas or Sentinel | Schema-relevant; vNEXT-blocking |
| 8 | **#241** kubelogin auth modes (after #240) | Atlas | Phase 2 of K8s auth ladder |

### Batch 3 (later, after Brady Q3, Q4, Q5)

- **#239** AKS rightsizing (depends on #237 + AksDiscovery refactor)
- **#234a** node utilization (Reader-only, parallel-safe with #239 once `AksDiscovery.ps1` exists)
- **#232a** GH Actions billing (no Brady block; can move earlier if Atlas has bandwidth)
- **#227** top recommendations panel (after RuleId decision)
- **#230** framework matrix (after heatmap-host decision)

### Batch 4 (vNEXT tail)

- **#232b** ADO consumption (after EntityType decision)
- **#234b** Karpenter consolidation (after EntityType + RBAC decision)
- **#242** in-cluster auth mode (after #241)

---

## 5. Risks and open questions for Brady

1. **#228 - URL field strategy.** Reuse existing `LearnMoreUrl` (rename rendered column to "Fix it") OR add a distinct `RemediationUrl` (Learn = docs, Remediate = portal deep-link)? Sloan recommends reuse to avoid normalizer drift. Schema-relevant: vNEXT-blocking.
2. **#227 - RuleId on FindingRow.** Add `[string] $RuleId` (nullable) to `New-FindingRow` so the impact panel aggregates correctly? Or stay on `Title` and accept noise? Recommend adding the field. Schema-relevant: vNEXT-blocking.
3. **#230 - Framework matrix host.** Add the matrix to legacy `New-HtmlReport.ps1` (next to existing severity heatmap from PR #221) or port the heatmap into `report-template.html` first and add the matrix there? Long-term cleaner = port; faster = legacy. No schema impact.
4. **#232b - ADO project EntityType.** Add `EntityType = 'AdoProject'` to `Schema.ps1` line 38 enum, or alias ADO project-level findings to existing `Pipeline`? Schema-relevant: vNEXT-blocking. Recommend adding the new value.
5. **#234b - Karpenter EntityType + elevated RBAC.** (a) Add `EntityType = 'KarpenterProvisioner'`? (b) Approve **Azure Kubernetes Service Cluster User Role** as an opt-in elevated permission tier (today every wrapper is Reader-only)? Without (b) we can ship #234a node-utilization-only as a degraded mode. Schema + permissions relevant: vNEXT-blocking on (a).
6. **vNEXT freeze date.** What is the target merge cutoff for schema-touching PRs? This determines whether we batch #227 + #228 + #232b + #234b into a single Schema.ps1 PR or land them serially.
7. **Manifest schema bump (#230).** Are we comfortable adding a `frameworks[]` (and possibly `category` / `pillar`) array to every tool entry in `tool-manifest.json`? Backwards-compat is fine (additive, optional), but it formalises a new contract.

---

## 6. Reviewer assignments

Reviewer-rejection lockout means no PR may be reviewed by its author. Pool: Lead, Atlas, Iris, Forge, Sentinel, Sage. Suggested pairings (one primary reviewer plus one fallback):

| PR (issue) | Author | Primary reviewer | Fallback reviewer |
|---|---|---|---|
| #226 severity strip | Sentinel | Atlas | Forge |
| #229 tree toggle | Atlas | Sentinel | Forge |
| #228 deep-link col | Atlas or Sentinel | the other of the two | Iris |
| #227 impact panel | Sentinel | Atlas | Sage |
| #230 framework matrix | Atlas + Forge co-author | Sentinel | Lead |
| #233 Infracost | Atlas | Sentinel | Forge |
| #232a GH Actions billing | Atlas | Forge (DevOps domain) | Sentinel |
| #232b ADO consumption | Atlas | Forge | Sentinel |
| #234a node utilization | Atlas | Sage (data-source pairing) | Sentinel |
| #234b Karpenter | Atlas | Sage | Forge |
| #237 App Insights + KqlQuery | Atlas | Sentinel | Iris |
| #238 Load Testing | Atlas | Sentinel | Forge |
| #239 AKS rightsizing | Atlas | Sage | Sentinel |
| #240 K8s params | Forge | Atlas | Sentinel |
| #241 kubelogin | Atlas | Forge | Iris |
| #242 in-cluster | Atlas | Forge | Sage |

Atlas is the highest-load author (10 of 16 issues touch their domain). Sentinel + Forge + Sage split most reviewer duty to keep no-self-review enforced. Iris is light-load and serves as fallback for identity-flavoured items (kubelogin, App Insights workspace ownership).

---

## 7. PSGallery / vNEXT alignment

The recent restructure committed to vNEXT being the next minor bump. The public surface that vNEXT freezes is: `New-FindingRow` shape, `EntityType` enum, `Severity` enum, `tools/tool-manifest.json` schema, and the orchestrator parameter block.

### Must land BEFORE vNEXT (clean public surface)

- **#228** RemediationUrl decision (touches `FindingRow`)
- **#227** RuleId field add (touches `FindingRow`)
- **#232b** AdoProject EntityType (touches enum)
- **#234b** KarpenterProvisioner EntityType (touches enum)
- **#240** kubeconfig/namespace param block (touches orchestrator public params)
- **#241** `-KubeAuthMode` enum (touches orchestrator public params)
- **#242** in-cluster `-KubeAuthMode` extension (touches orchestrator public params)
- **#230** manifest `frameworks[]` schema bump (touches manifest schema)

### Can land AFTER vNEXT (additive, no contract impact)

- **#226** severity strip (JS only)
- **#229** tree toggle (JS only)
- **#233** Infracost wrapper (additive tool)
- **#232a** GH Actions billing wrapper (additive tool)
- **#234a** node utilization (additive tool, no enum change)
- **#237** App Insights perf wrapper (additive tool + new internal shared helper)
- **#238** Load Testing wrapper (additive tool)
- **#239** AKS rightsizing (additive tool, refactor is internal)

This split argues for prioritising the **enum and orchestrator-param** items in the next two batches so the vNEXT tag can be cut without dragging schema work into a patch release.

---

## Appendix: stream effort rollup

- **Reports stream:** 1 S + 1 M + 2 NEEDS-DESIGN + 1 NEEDS-DESIGN/M = roughly 5 PRs, mostly small but two blocked on Brady decisions.
- **Cost stream:** 1 umbrella close + 1 S + 2 SPLIT (so 4 child PRs) = 5 PRs, two blocked on Brady decisions.
- **AKS stream:** 1 umbrella close + 3 sequential auth phases + 3 perf children (one umbrella close) = 6 PRs total, last 4 sequenced.

Total addressable PR count: ~16 distinct PRs (after umbrellas closed and splits applied), executable in 4 batches over the next several iterations of Iterate-Until-Green.
