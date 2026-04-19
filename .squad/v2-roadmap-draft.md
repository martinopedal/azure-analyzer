# azure-analyzer v2 roadmap — draft issues

**Context:** v1 (issues that became PRs #143–#152) shipped: 21 tools, incremental scans + state layer, Sentinel incidents, ADO pipeline security, management-group rollup, executive dashboard, IaC validation, AzGovViz deepening. v2 picks up the threads the codebase is now ready to support.

**Dependency graph (one line):**
> #4 (LA sink) blocks #7 (continuous control). #5 (multi-tenant) also blocks #7. #2 (drift) builds on the #150 state layer but is independent of the rest. #1, #3, #6, #8 are independent and parallelizable.

---

## 1. `feat: deepen Sentinel coverage — analytic rules, watchlists, hunting queries`

**Problem.** PR #148 added `sentinel-incidents` (active incidents from `SecurityIncident`). That covers detection *output* but not detection *posture*. Customers ask: "Are my analytic rules enabled? Do my watchlists have stale entries? Which hunting queries haven't been run in 90 days?" These are first-class governance gaps for any Sentinel tenant and they live behind the same Log Analytics workspace token we already authenticate against.

**Proposed approach.** Extend the existing Sentinel surface with a sibling collector `sentinel-posture` (provider `azure`, scope `subscription`, type `collector`). One wrapper `modules/Invoke-SentinelPosture.ps1` issues three REST calls against `Microsoft.SecurityInsights`:
- `alertRules` — flag disabled rules, rules with no incidents in 30d, rules without MITRE tactics.
- `watchlists` — flag empty watchlists, watchlists not refreshed in 90d.
- `huntingQueries` (saved searches with `Hunting Queries` category) — flag queries never executed.

Normalizer `Normalize-SentinelPosture` emits `EntityType=AzureResource` rows targeting the workspace ARM ID. New manifest entry mirrors `sentinel-incidents` (color `#3949ab`, phase 2). Schema impact: none — uses existing fields.

**Acceptance criteria.**
- [ ] `sentinel-posture` registered in `tool-manifest.json` (enabled, tier 0).
- [ ] Wrapper + normalizer + Pester tests with realistic JSON fixture under `tests/fixtures/sentinel-posture/`.
- [ ] Graceful skip (PartialSuccess) when `Microsoft.SecurityInsights` provider is not registered.
- [ ] `Remove-Credentials` invariant on all error paths.
- [ ] `README.md` tools table updated to 22 entries; `PERMISSIONS.md` notes the same Reader scope used by `sentinel-incidents`; `CHANGELOG.md` entry under Unreleased.
- [ ] `Invoke-Pester -Path .\tests -CI` stays green.

**Out of scope.** Writing/updating analytic rules, MDR/MXDR ingestion, Defender XDR alert correlation (separate issue).

---

## 2. `feat: drift detection — entities.json delta report between runs`

**Problem.** PR #150 shipped incremental scans + a shared scan-state layer, so we now have multiple `entities.json` snapshots per repo. There is no first-class way to ask "what changed between Monday and today?" — new findings, regressed entities, newly-compliant resources, or newly-discovered identities. Drift is the single most-requested CISO question and we already have the substrate.

**Proposed approach.** Add `modules/shared/Drift.ps1` exporting `Compare-EntityStores -Baseline <path> -Current <path>` returning `{ Added, Removed, SeverityIncreased, SeverityDecreased, NewlyCompliant, NewlyNonCompliant }` per entity. Add a report module `modules/reports/New-DriftReport.ps1` producing `drift.html` + `drift.md` consuming the comparison object. Wire `-DriftBaseline <path>` into `Invoke-AzureAnalyzer.ps1`; when omitted, auto-discover the most recent prior run via the existing baseline-discovery path used by PR #146.

**Acceptance criteria.**
- [ ] `Compare-EntityStores` with Pester tests covering the 6 delta categories using two-snapshot fixtures under `tests/fixtures/drift/`.
- [ ] `drift.html` + `drift.md` generated only when a baseline resolves; otherwise emit a `drift-skipped.json` marker.
- [ ] HTML report uses the existing color palette from `tool-manifest.json`.
- [ ] `README.md` "Report structure" section updated; `CHANGELOG.md` entry; new `docs/drift.md` (1-page) explaining the delta semantics.
- [ ] No new permissions; `PERMISSIONS.md` unchanged but explicitly mentions "no extra scope required."

**Out of scope.** Time-series storage, multi-run trending beyond 2 runs (covered by #146's sparkline trends), notification routing.

---

## 3. `feat: FinOps signals — surface unused/idle Azure resources from cost + ARG data`

**Problem.** `azure-cost` already folds `MonthlyCost` onto every entity, but we don't act on it. Customers want a simple "what am I paying for that I'm not using?" — orphaned disks, unattached public IPs, idle App Service plans, empty resource groups burning reservations, classic VMs. This is a high-signal, low-effort win because ARG already returns the data.

**Proposed approach.** Add `finops-signals` (provider `azure`, scope `subscription`, type `correlator`) under `modules/Invoke-FinopsSignals.ps1`. Use Resource Graph queries (JSON, in `queries/finops/`) for the 6 canonical waste patterns: orphaned managed disks, unattached PIPs, idle ASP (CPU < 5% / 30d via Monitor metrics), empty RGs, deallocated VMs > 30d, ungoverned snapshots > 90d. Each query returns a `compliant` column per repo convention. Normalizer attaches findings to the existing `AzureResource` entity so cost rolls up automatically — no new entity type.

**Acceptance criteria.**
- [ ] 6 query JSON files under `queries/finops/` each returning `compliant`.
- [ ] Wrapper + normalizer + Pester tests with ARG response fixtures.
- [ ] `Severity = Info` for waste signals; `Category = Cost`.
- [ ] Findings include `MonthlyCost` enrichment in `Detail` ("$X/mo wasted") when cost data is present in the run.
- [ ] `README.md` tools table updated; `PERMISSIONS.md` confirms Reader-only; `CHANGELOG.md` entry.
- [ ] Test fixture covers a non-compliant + compliant case per query.

**Out of scope.** Reservation/savings-plan recommendations (Advisor territory), automated remediation, cross-subscription rightsizing.

---

## 4. `feat: output sink — push findings to Log Analytics / Sentinel custom table`

**Problem.** Today azure-analyzer writes JSON/HTML/MD to disk. To become a continuous control (issue #7), findings must land somewhere queryable: Log Analytics, then optionally Sentinel as a custom table for cross-correlation with incidents. This is the single biggest unlock for the "azure-analyzer as a Sentinel data source" story.

**Proposed approach.** Add `modules/shared/Sinks.ps1` with a sink interface `Send-FindingsToSink -Findings <FindingRow[]> -SinkConfig <hashtable>`. First implementation: `LogAnalyticsSink` using the **Logs Ingestion API** (DCR/DCE-based, the supported v2 path — not the deprecated HTTP Data Collector API). New manifest field `sinks: [{ kind: "logAnalytics", dceUri, dcrImmutableId, streamName }]` per-run via `-SinkConfig <path>`. Auth: Managed Identity preferred, Azure CLI token fallback. Each finding is sent with the v2 FindingRow shape; batch size 500; retry via `Invoke-WithRetry`.

**Acceptance criteria.**
- [ ] `Sinks.ps1` with Pester tests using mocked Invoke-RestMethod (DCE endpoint fixture).
- [ ] Allow-list enforcement: sink endpoints must match `*.ingest.monitor.azure.com` (HTTPS-only).
- [ ] Sample DCR JSON committed under `docs/samples/sentinel-dcr.json` with the exact schema mapping the FindingRow.
- [ ] `Remove-Credentials` on all sink-error paths; sink failures are PartialSuccess (do not fail the run).
- [ ] `README.md` new section "Output sinks"; `PERMISSIONS.md` adds the `Monitoring Metrics Publisher` role on the DCR; `CHANGELOG.md` entry.
- [ ] KQL example in `docs/samples/sentinel-kql.md` showing how to join custom-table rows with `SecurityIncident`.

**Out of scope.** Splunk/Elastic/Datadog sinks (later), bidirectional sync, alert-rule autodeployment.

---

## 5. `feat: multi-tenant fan-out orchestration`

**Problem.** Today `-TenantId` is single-valued. MSPs and large enterprises run azure-analyzer against 5–50 tenants in sequence with bash loops. We have parallel scope dispatch for subscriptions inside a tenant, but no first-class multi-tenant story. This is the biggest enterprise gap.

**Proposed approach.** Add `-Tenants <string[]>` (or `-TenantsFile <path>` pointing at JSON `[{ tenantId, displayName, credentialRef }]`). Extend `Invoke-AzureAnalyzer.ps1` to fan out one isolated runspace per tenant via `ForEach-Object -Parallel` (throttle default 4). Each tenant gets its own output directory (`out/{runId}/{tenantId}/`); a top-level `tenants.json` indexes them. Per-tenant credential isolation via `Connect-AzAccount -Tenant` in each runspace (dot-source `Sanitize.ps1` per the established Falco pattern).

**Acceptance criteria.**
- [ ] `-Tenants` and `-TenantsFile` parameters; mutually exclusive validation.
- [ ] Per-tenant output isolation (no cross-tenant data in any single file).
- [ ] Aggregate `tenants.html` index with per-tenant compliance score sparkline.
- [ ] Pester tests for the dispatcher using mocked tenant authentication; coverage of partial-failure (one tenant fails, others succeed → exit 0 with PartialSuccess).
- [ ] Token scrubbing verified across runspace boundary (use the PR #116 dot-source pattern).
- [ ] `README.md` "Multi-tenant" section; `PERMISSIONS.md` clarifies per-tenant Reader requirement; `CHANGELOG.md` entry.

**Out of scope.** Cross-tenant entity correlation (separate issue #6), credential vaulting (use `az login --tenant` chain or env vars), web UI.

---

## 6. `feat: identity graph expansion — cross-tenant B2B + SPN-to-resource edges`

**Problem.** `identity-correlator` resolves SPNs/MIs/apps within one tenant but has two structural gaps: (1) **B2B guests** appear as opaque GUIDs with no home-tenant attribution; (2) the SPN-to-AzureResource edge — "which managed identity owns which resource and what does it have rights on?" — is only partially materialized. Both are blast-radius questions that auditors ask first.

**Proposed approach.** Extend `IdentityCorrelator.ps1` with two new edge builders:
- `Build-B2BGuestEdges` — for every `User` entity where `userType = Guest`, resolve `externalUserState` and parse `mail` / `userPrincipalName` to derive the home-tenant domain; emit a `Correlation` of kind `B2BHomeTenant` with `Confidence = Likely` (since we can't always resolve the home tenant ID without cross-tenant Graph access).
- `Build-SpnResourceEdges` — for every `ServicePrincipal` / `ManagedIdentity`, query ARG `authorizationresources` for role assignments where `principalId` matches; emit a `Correlation` per assignment scope with `Severity` derived from role builtin classification (Owner/Contributor/User Access Administrator → High).

New `Correlation.kind` values: `B2BHomeTenant`, `SpnHasRoleAt`. No new entity types.

**Acceptance criteria.**
- [ ] Two new edge builders with Pester tests using fixtures (`tests/fixtures/identity-correlator/b2b-guests.json`, `…/spn-roles.json`).
- [ ] Risk findings emitted: `B2B guest with no MFA enforcement`, `SPN has Owner at subscription scope`.
- [ ] Candidate-reduction discipline preserved (no bulk SPN enumeration).
- [ ] `Remove-Credentials` on all error paths.
- [ ] `README.md` Identity Correlator section updated; `PERMISSIONS.md` notes that Owner-edge resolution needs `Microsoft.Authorization/roleAssignments/read` (already part of Reader); `CHANGELOG.md` entry.

**Out of scope.** Live cross-tenant Graph queries (we don't have that token), Privileged Identity Management eligibility expansion (PIM-specific issue), graph-database export.

---

## 7. `feat: continuous control mode — scheduled GHA + Azure Function entrypoint`

**Problem.** azure-analyzer runs interactively today. To become a *control* rather than a *tool*, it needs to run on a schedule, push findings to a sink, and alert on regressions — all without a human. This is the natural endpoint of #2 (drift) + #4 (sink) + #5 (multi-tenant).

**Proposed approach.** Two delivery vectors, same orchestrator:
1. **Scheduled GitHub Actions workflow** (`.github/workflows/scheduled-scan.yml`) — runs nightly via cron, uses OIDC federation to authenticate to Azure, scans a configured subscription list, pushes to the Log Analytics sink (#4), opens a GitHub issue if drift (#2) shows new High/Critical findings.
2. **Azure Function PowerShell entrypoint** (`functions/Run-ContinuousScan/run.ps1`) — Timer-triggered, reads tenant list from App Configuration, uses System-Assigned MI, writes results to Log Analytics. Bicep template under `infra/continuous-control.bicep`.

**Acceptance criteria.**
- [ ] Scheduled workflow with OIDC federation (no PATs); workflow file SHA-pinned per repo policy.
- [ ] Function entrypoint + Bicep template + smoke test.
- [ ] `docs/continuous-control.md` deployment guide (10-minute walkthrough).
- [ ] Failure-mode docs: what happens if a scan exceeds the function timeout (10 min hard cap → recommend Premium plan or Container Apps).
- [ ] `README.md` "Continuous control" section; `PERMISSIONS.md` documents the Function MI role assignments; `CHANGELOG.md` entry.
- [ ] Smoke test in CI that validates the Bicep template (`bicep build`, no deploy).

**Out of scope.** Multi-cloud (GCP/AWS) scanning, web UI, paid alert delivery channels (Teams/Slack — separate small issue).

---

## 8. `feat: ADO Repos secret scanning + pipeline run-log correlation`

**Problem.** PR #151 shipped pipeline security (definitions, variable groups, environments). The roadmap line in README explicitly calls out "optional run-log correlation" as the next step. Two gaps remain: (1) ADO Repos are invisible to gitleaks because today gitleaks only targets GitHub URLs via `RemoteClone.ps1`; (2) we inspect pipeline *definitions* but never the actual *run logs* where leaked tokens, failed task patterns, and deprecated images surface.

**Proposed approach.**
- **Repos:** extend `RemoteClone.ps1` allow-list (already supports `dev.azure.com`/`*.visualstudio.com`) and wire `gitleaks`/`trivy` to accept an `-AdoOrg` + `-AdoRepo` parameter pair that resolves to the canonical clone URL. No new tool — reuse existing wrappers.
- **Run logs:** add `ado-runlogs` collector (provider `ado`, scope `ado`). For the most recent N runs per pipeline, fetch the run timeline + log artifacts via REST, scan log text with the existing gitleaks regex set (in-memory, not on disk), and emit findings on the `Pipeline` entity. Default N=10, configurable via `-AdoRunLogDepth`.

**Acceptance criteria.**
- [ ] gitleaks/trivy accept ADO repo targets; integration test with a fixture clone URL.
- [ ] `ado-runlogs` registered in manifest with `report.color = #00838f, phase = 2`.
- [ ] Wrapper streams logs through `Remove-Credentials` before any disk write.
- [ ] Pester tests with fixture run-log payloads (timeline JSON + sample log text).
- [ ] PartialSuccess when a run's logs are gone (retention expired).
- [ ] `README.md` ADO section updated; `PERMISSIONS.md` confirms read-only PAT scopes (`Build (read)`, `Code (read)`); `CHANGELOG.md` entry; the README roadmap line about "run-log correlation" is removed.

**Out of scope.** Real-time streaming of in-flight runs, ADO Artifacts feed scanning, classic-release log scraping (deprecated), rewriting gitleaks regex catalog.

---

# Recommended sprint order

1. **#2 Drift detection** — small, high-impact, isolated, unblocks the CISO narrative immediately.
2. **#3 FinOps signals** — small, leverages existing cost data, demo-friendly.
3. **#1 Sentinel posture** — small/medium, sibling of a freshly-shipped tool, low integration risk.
4. **#8 ADO Repos + run-logs** — medium, completes the ADO story the README still calls out.
5. **#6 Identity graph expansion** — medium, raises the strategic value of the correlator.
6. **#4 Log Analytics sink** — medium/large, prerequisite for #7.
7. **#5 Multi-tenant fan-out** — large, prerequisite for #7 at enterprise scale.
8. **#7 Continuous control mode** — large, the capstone — only meaningful once #4 and #5 land.

Cadence suggestion: ship 1–3 in week 1, 4–6 in weeks 2–3, 7–8 as a coordinated v2.0 milestone in week 4.
