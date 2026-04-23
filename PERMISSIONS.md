# Permissions Reference - azure-analyzer

## Core principle

Azure-analyzer is **read-first**. Every collector targets the minimum scope it needs and never writes to the cloud surface it scans. The single optional **write** path is the Log Analytics sink (`-SinkLogAnalytics`), which requires `Monitoring Metrics Publisher` on the target Data Collection Rule. Phase 0 v3 core modules (Schema, Canonicalize, EntityStore, tool manifest) introduce no new permissions or scopes. Report UX improvements such as the collapsible findings tree also add no new scopes. AzGovViz remains read-only and uses Reader at the tenant root management-group scope. kube-bench Schema 2.2 ETL enrichment adds benchmark metadata only and does not change required RBAC.
CI watchdog sanitizer unification (SEC-002) routes through shared `Remove-Credentials` only and introduces no new Azure, Graph, GitHub, or Azure DevOps permissions.
Maester Schema 2.2 ETL enrichment adds finding metadata only (framework tags, evidence links, remediation snippets, MITRE references, entity refs, tool version) and does not add new Microsoft Graph scopes.
Identity Correlator Schema 2.2 ETL enrichment adds attack-path metadata only (framework tags, MITRE mappings, Entra deep links, remediation snippets, evidence URIs, entity refs, tool version) and does not add new Microsoft Graph scopes.
Identity Correlator manifest dispatch now routes through a thin `Invoke-IdentityCorrelator.ps1` wrapper (with shared-module logic unchanged), and this introduces no new Graph or Azure permissions.
The ado-connections Schema 2.2 auth posture enrichment adds metadata only and does not require any new Azure DevOps PAT scopes.
The gitleaks Schema 2.2 ETL enrichment adds metadata only (framework mapping, evidence links, remediation snippets, baseline tags, and tool version) and does not introduce any new permissions.
The zizmor Schema 2.2 ETL enrichment only adds metadata fields and does not introduce new GitHub or Azure permissions.
Repo-input parameter convergence (`RepoPath` + `RemoteUrl` with legacy aliases) is naming-only and does not introduce any new Azure, Graph, GitHub, or Azure DevOps permissions.
The falco Schema 2.2 ETL enrichment adds runtime metadata only (CIS framework mapping, MITRE tags, evidence links, and tool version) and does not introduce any new Azure RBAC requirements.
The alz-queries Schema 2.2 ETL enrichment adds ALZ governance metadata only (framework tags, pillar mapping, source deep links, evidence URIs, baseline tags, and tool version) and does not change required Azure Reader scope.
The HTML remediation-snippet null-guard report fix only changes rendering behavior and does not introduce any new permissions.
Phase 0 foundation report architecture metadata, report-manifest output, and vendoring verification stubs add no new Azure, Microsoft Graph, GitHub, or Azure DevOps permission requirements.
Attack-path renderer implementation (`AttackPathRenderer.ps1`) is report-side transformation only and introduces no new Azure, Microsoft Graph, GitHub, or Azure DevOps permission requirements.
Policy-enforcement enrichment (ALZ matcher, AzAdvertizer/ALZ vendored catalogs, AzGovViz policy edge emission, and `-AlzReferenceMode`) is read-only and adds no new Azure, Graph, GitHub, or Azure DevOps scopes.
The findings viewer scaffold (`-Show`, loopback-only Pode host) is local-only and introduces no Azure, Graph, GitHub, or Azure DevOps permissions.
Optional Copilot triage makes GitHub Copilot API calls (including runtime model discovery via `gh copilot status` / `gh copilot models list` and triage generation) only when users explicitly enable AI triage; this does not require Azure/Graph write permissions.
Release automation (release-please, GitHub Releases, and PSGallery publication) introduces repository automation and package feed credentials (`GITHUB_TOKEN`, `PSGALLERY_API_KEY`) only; it does not require any additional Azure, Microsoft Graph, GitHub repository-content write scopes for runtime scanners, or Azure DevOps read scope changes.
Manifest ordering enforcement (`tools/tool-manifest.json` alphabetical-by-name + `tests/manifest/Manifest.Sorted.Tests.ps1`) is test-only hygiene and introduces no new scopes.
Resilience map renderer implementation (Track B #429 follow-up) is report-layer logic over existing EntityStore data and introduces no new Azure, Graph, GitHub, or Azure DevOps permissions.

## Permission domains at a glance

| Domain | What it covers | Baseline role |
|---|---|---|
| **Azure** | Subscription / management-group / workspace collectors (azqr, PSRule, Powerpipe, AzGovViz, ALZ, WARA, FinOps, Defender, Sentinel, Cost, AKS) | **Reader** at the relevant scope |
| **Microsoft Graph** | Entra ID / identity collectors (Maester, Identity Correlator optional, Identity Graph Expansion) | Read-only Graph application or delegated scopes |
| **GitHub** | OpenSSF Scorecard, optional cloning for cloud-first CLI scanners | Repository **Read** PAT (or unauthenticated for public repos with rate-limit penalty) |
| **Azure DevOps** | Service connections, pipeline security, repo secrets, run correlator, pipeline consumption cost governance telemetry | PAT with read-only scopes (`Build:Read`, `Code:Read`, `Service Connections:Read`, etc.). The run correlator emits Schema 2.2 evidence links and entity refs without requiring extra scopes. |
| **Local CLI / IaC** | zizmor, gitleaks, Trivy, bicep-iac, terraform-iac when run against a local checkout | None |
| **Optional sink** | Streaming findings to Log Analytics (`-SinkLogAnalytics`) | **Monitoring Metrics Publisher** on the DCR (the only write role) |

## Per-tool index

<!-- BEGIN INDEX (generated by scripts/Generate-PermissionsIndex.ps1; do not edit by hand) -->

Per-tool permission detail lives under [`docs/consumer/permissions/`](docs/consumer/permissions/README.md). The index below is regenerated from `tools/tool-manifest.json` by `scripts/Generate-PermissionsIndex.ps1` and enforced by the `permissions-pages-fresh` CI check.

### Azure (Reader baseline)

| Tool | Scope | Detail |
|---|---|---|
| **AKS Karpenter Cost (consolidation + node utilization)** | Subscription | [`aks-karpenter-cost.md`](docs/consumer/permissions/aks-karpenter-cost.md) |
| **AKS Rightsizing (Container Insights utilization)** | Subscription | [`aks-rightsizing.md`](docs/consumer/permissions/aks-rightsizing.md) |
| **ALZ Resource Graph Queries** | Management Group | [`alz-queries.md`](docs/consumer/permissions/alz-queries.md) |
| **Application Insights Performance Signals** | Subscription | [`appinsights.md`](docs/consumer/permissions/appinsights.md) |
| **AzGovViz** | Management Group | [`azgovviz.md`](docs/consumer/permissions/azgovviz.md) |
| **Azure Quick Review** | Subscription | [`azqr.md`](docs/consumer/permissions/azqr.md) |
| **Azure Cost (Consumption API)** | Subscription | [`azure-cost.md`](docs/consumer/permissions/azure-cost.md) |
| **Azure Quota Reports** | Subscription | [`azure-quota.md`](docs/consumer/permissions/azure-quota.md) |
| **Microsoft Defender for Cloud** | Subscription | [`defender-for-cloud.md`](docs/consumer/permissions/defender-for-cloud.md) |
| **Falco (AKS runtime anomaly detection)** | Subscription | [`falco.md`](docs/consumer/permissions/falco.md) |
| **FinOps Signals (Idle Resource Detection)** | Subscription | [`finops.md`](docs/consumer/permissions/finops.md) |
| **kube-bench (AKS node-level CIS compliance)** | Subscription | [`kube-bench.md`](docs/consumer/permissions/kube-bench.md) |
| **Kubescape (AKS runtime posture)** | Subscription | [`kubescape.md`](docs/consumer/permissions/kubescape.md) |
| **Azure Load Testing (Failed and Regressed Runs)** | Subscription | [`loadtesting.md`](docs/consumer/permissions/loadtesting.md) |
| **Powerpipe Compliance Benchmarks** | Subscription | [`powerpipe.md`](docs/consumer/permissions/powerpipe.md) |
| **Prowler (Azure security posture)** | Subscription | [`prowler.md`](docs/consumer/permissions/prowler.md) |
| **PSRule for Azure** | Subscription | [`psrule.md`](docs/consumer/permissions/psrule.md) |
| **Microsoft Sentinel (Coverage / Posture)** | Workspace | [`sentinel-coverage.md`](docs/consumer/permissions/sentinel-coverage.md) |
| **Microsoft Sentinel (Active Incidents)** | Workspace | [`sentinel-incidents.md`](docs/consumer/permissions/sentinel-incidents.md) |
| **Well-Architected Reliability Assessment** | Subscription | [`wara.md`](docs/consumer/permissions/wara.md) |

### Microsoft 365 / Entra (Microsoft Graph)

| Tool | Scope | Detail |
|---|---|---|
| **Maester** | Tenant | [`maester.md`](docs/consumer/permissions/maester.md) |

### Identity correlation (optional Microsoft Graph)

| Tool | Scope | Detail |
|---|---|---|
| **Identity Correlator** | Tenant | [`identity-correlator.md`](docs/consumer/permissions/identity-correlator.md) |
| **Identity Graph Expansion** | Tenant | [`identity-graph-expansion.md`](docs/consumer/permissions/identity-graph-expansion.md) |

### GitHub

| Tool | Scope | Detail |
|---|---|---|
| **GitHub Actions Billing** | Repository | [`gh-actions-billing.md`](docs/consumer/permissions/gh-actions-billing.md) |
| **OpenSSF Scorecard** | Repository | [`scorecard.md`](docs/consumer/permissions/scorecard.md) |

### Azure DevOps

| Tool | Scope | Detail |
|---|---|---|
| **ADO Service Connections** | ADO Org | [`ado-connections.md`](docs/consumer/permissions/ado-connections.md) |
| **ADO Pipeline Consumption** | ADO Org | [`ado-consumption.md`](docs/consumer/permissions/ado-consumption.md) |
| **ADO Pipeline Run Correlator** | ADO Org | [`ado-pipeline-correlator.md`](docs/consumer/permissions/ado-pipeline-correlator.md) |
| **ADO Pipeline Security** | ADO Org | [`ado-pipelines.md`](docs/consumer/permissions/ado-pipelines.md) |
| **ADO Repos Secret Scanning** | ADO Org | [`ado-repos-secrets.md`](docs/consumer/permissions/ado-repos-secrets.md) |

### Local CLI / IaC (no cloud permissions)

| Tool | Scope | Detail |
|---|---|---|
| **Bicep IaC Validation** | Repository | [`bicep-iac.md`](docs/consumer/permissions/bicep-iac.md) |
| **gitleaks (Secrets Scanner)** | Repository | [`gitleaks.md`](docs/consumer/permissions/gitleaks.md) |
| **Infracost IaC Cost Estimation** | Repository | [`infracost.md`](docs/consumer/permissions/infracost.md) |
| **Terraform IaC Validation** | Repository | [`terraform-iac.md`](docs/consumer/permissions/terraform-iac.md) |
| **Trivy Vulnerability Scanner** | Repository | [`trivy.md`](docs/consumer/permissions/trivy.md) |
| **zizmor (Actions YAML Scanner)** | Repository | [`zizmor.md`](docs/consumer/permissions/zizmor.md) |

### Cross-cutting topics

| Topic | Detail |
|---|---|
| Cross-tool matrix, tiers, least-privilege | [`docs/consumer/permissions/_summary.md`](docs/consumer/permissions/_summary.md) |
| Continuous Control Function App (#165) | [`docs/consumer/permissions/_continuous-control.md`](docs/consumer/permissions/_continuous-control.md) |
| Multi-tenant fan-out (#163) | [`docs/consumer/permissions/_multi-tenant.md`](docs/consumer/permissions/_multi-tenant.md) |
| Management-group recursion | [`docs/consumer/permissions/_management-group.md`](docs/consumer/permissions/_management-group.md) |
| Auth troubleshooting | [`docs/consumer/permissions/_troubleshooting.md`](docs/consumer/permissions/_troubleshooting.md) |

<!-- END INDEX -->

### Opt-in / disabled-by-default tools

These tools are registered in `tools/tool-manifest.json` with `enabled: false` and only run when the user explicitly opts in. They are documented here for completeness but are intentionally excluded from the auto-generated index above.

| Tool | Scope | Opt-in flag | Required credentials | Detail |
|---|---|---|---|---|
| **Copilot AI Triage** | Repository | `-EnableAiTriage` | GitHub Copilot license + PAT with `copilot` scope (or existing `GITHUB_TOKEN`) via `COPILOT_GITHUB_TOKEN` / `GITHUB_TOKEN` env var. No Azure RBAC required. | [`copilot-triage.md`](docs/consumer/permissions/copilot-triage.md) |

The manifest (`tools/tool-manifest.json`) remains the source of truth for `enabled`, `provider`, and `scope` metadata.

## Least-privilege summary

- Read-only everywhere (the optional Log Analytics sink is the sole exception).
- Scoped to subscriptions / tenants; not broader than necessary.
- Graceful degradation: missing permissions skip the affected tool with a warning instead of failing the run.
- Use `-IncludeTools` / `-ExcludeTools` to run only what you have access to.
- ADO repo secrets Schema 2.2 ETL enrichment (commit and blob evidence links, baseline tags, remediation snippets) adds no new Azure DevOps scopes beyond existing read-only PAT requirements.

Full discussion (matrix, tier model, scenarios, what we do NOT need) lives in [`docs/consumer/permissions/_summary.md`](docs/consumer/permissions/_summary.md).

## Opt-in elevated RBAC tier

> Status: **shipping in v1.2.0** (#234). The opt-in mechanism is implemented as a per-wrapper switch on every wrapper that needs cluster-data-plane reads.

By default every wrapper requires **Reader-only** at the relevant Azure scope (or the per-domain read-only role listed above for Graph / GitHub / ADO). No cloud-side mutation is performed and no elevated role is requested.

A small number of advanced inspections need to read pod-level state from inside an AKS data plane that the standard ARM Reader role does not expose. For these the orchestrator publishes an explicit, off-by-default opt-in:

| Capability | Tool / wrapper | Default | Opt-in flag | Opt-in role required | Scope |
|---|---|---|---|---|---|
| Karpenter NodePool / NodeClaim inspection | `aks-karpenter-cost` (#234) | **Disabled** | `-EnableElevatedRbac` | `Azure Kubernetes Service Cluster User Role` | Per AKS managed cluster |

Rules:

- The opt-in is **OFF by default**. With `-EnableElevatedRbac` omitted the wrapper skips the kubectl branch entirely; no kubeconfig is fetched and no kubectl process is launched.
- The opt-in is **per-wrapper, not orchestrator-wide**. Setting it on one wrapper does NOT change the RBAC tier of any other tool that runs in the same orchestrator session. The state lives in `modules/shared/RbacTier.ps1` and is reset to `Reader` in the wrapper's `finally{}` block.
- The role granted is the read-only `Cluster User Role` (`AKS Cluster User Role`); it does **not** grant cluster-admin nor any Azure resource write permission.
- The opt-in changes neither the manifest's `provider` / `scope` metadata nor the report-side schema. Findings still flow through `New-FindingRow` with `EntityType=KarpenterProvisioner` (added in FindingRow v2.1) and `Platform=Azure`.

Per-tool detail and the full RBAC tier table live in [`docs/consumer/permissions/aks-karpenter-cost.md`](docs/consumer/permissions/aks-karpenter-cost.md). Future tools that need the same tier should follow the same pattern (`-EnableElevatedRbac` switch + `Set-RbacTier` / `Reset-RbacTier` / `Assert-RbacTier`).

Consumers who do not opt in see the same Reader-only behaviour as today.

## Environment variables

azure-analyzer requires no special environment variables to run, but honours a small set of opt-in flags for CI / quiet-mode use:

| Variable | Effect |
|----------|--------|
| `AZURE_ANALYZER_NO_BANNER=1` | Suppress the ASCII banner. Auto-suppressed when `CI=true` or `GITHUB_ACTIONS=true`. |
| `AZURE_ANALYZER_SUPPRESS_TOOL_MISSING_WARNINGS=1` | Silence `<tool> is not installed. Skipping...` notices from every wrapper. Routes through `Write-Verbose` instead. Belt-and-suspenders kill-switch for noisy CI / Pester transcripts (see [#472](https://github.com/martinopedal/azure-analyzer/issues/472)). Truthy values: `1`, `true`, `yes`, `on` (case-insensitive). |
| `AZURE_ANALYZER_ORCHESTRATED=1` | Set automatically by `Invoke-AzureAnalyzer.ps1` for the duration of a run. Wrappers use it to distinguish orchestrated runs from standalone invocation. Do not set manually. |
| `AZURE_ANALYZER_EXPLICIT_TOOLS=<csv>` | Set automatically by `Invoke-AzureAnalyzer.ps1` to the comma-separated list of tools the user named via `-IncludeTools`. Empty when no filter was passed. Do not set manually. |

None of these flags grant additional permissions -- they purely affect launch-surface and log verbosity.

## See also

- [`docs/consumer/permissions/README.md`](docs/consumer/permissions/README.md) - per-tool detail folder.
- [`README.md`](README.md) - quick start and tool overview.
- [`CONTRIBUTING.md`](CONTRIBUTING.md) - development and PR process.
- [`SECURITY.md`](SECURITY.md) - security practices and disclosure.

## Maintaining this file

Per-tool detail belongs in `docs/consumer/permissions/<tool>.md`. The INDEX section above is regenerated from `tools/tool-manifest.json` by `scripts/Generate-PermissionsIndex.ps1`. When a new enabled tool is added to the manifest you MUST add a matching `docs/consumer/permissions/<name>.md` page; the `permissions-pages-fresh` CI check fails the PR otherwise.

Regenerate locally with:

```powershell
pwsh -File scripts/Generate-PermissionsIndex.ps1
```
