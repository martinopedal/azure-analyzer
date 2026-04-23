# Permissions Index

> This is a quick-reference index of all enabled tools, sorted by name, with required scope and link to detailed permission docs.
> 
> Full permission guidance lives in [PERMISSIONS.md](../PERMISSIONS.md).

## Quick lookup by tool name

| Tool | Display Name | Scope | Permission Tier | Detail |
|---|---|---|---|---|
| `ado-connections` | ADO Service Connections | ADO Org | Service Connection admin | [docs](./consumer/permissions/ado-connections.md) |
| `ado-consumption` | ADO Pipeline Consumption | ADO Org | PAT -- Build:Read, Code:Read | [docs](./consumer/permissions/ado-consumption.md) |
| `ado-pipeline-correlator` | ADO Pipeline Run Correlator | ADO Org | PAT -- Build:Read, Code:Read | [docs](./consumer/permissions/ado-pipeline-correlator.md) |
| `ado-pipelines` | ADO Pipeline Security | ADO Org | PAT -- Build:Read, Code:Read | [docs](./consumer/permissions/ado-pipelines.md) |
| `ado-repos-secrets` | ADO Repos Secret Scanning | ADO Org | PAT -- Code:Read | [docs](./consumer/permissions/ado-repos-secrets.md) |
| `aks-karpenter-cost` | AKS Karpenter Cost | Subscription | Azure Reader | [docs](./consumer/permissions/aks-karpenter-cost.md) |
| `aks-rightsizing` | AKS Rightsizing | Subscription | Azure Reader | [docs](./consumer/permissions/aks-rightsizing.md) |
| `alz-queries` | ALZ Resource Graph Queries | Management Group | Azure Reader | [docs](./consumer/permissions/alz-queries.md) |
| `appinsights` | Application Insights Performance Signals | Subscription | Azure Reader | [docs](./consumer/permissions/appinsights.md) |
| `azgovviz` | AzGovViz | Management Group | Azure Reader | [docs](./consumer/permissions/azgovviz.md) |
| `azqr` | Azure Quick Review | Subscription | Azure Reader | [docs](./consumer/permissions/azqr.md) |
| `azure-cost` | Azure Cost (Consumption API) | Subscription | Azure Reader | [docs](./consumer/permissions/azure-cost.md) |
| `azure-quota` | Azure Quota Reports | Subscription | Azure Reader | [docs](./consumer/permissions/azure-quota.md) |
| `bicep-iac` | Bicep IaC Validation | Repository | Local (no cloud credentials) | [docs](./consumer/permissions/bicep-iac.md) |
| `defender-for-cloud` | Microsoft Defender for Cloud | Subscription | Azure Reader | [docs](./consumer/permissions/defender-for-cloud.md) |
| `falco` | Falco (AKS runtime anomaly detection) | Subscription | Azure Reader | [docs](./consumer/permissions/falco.md) |
| `finops` | FinOps Signals (Idle Resource Detection) | Subscription | Azure Reader | [docs](./consumer/permissions/finops.md) |
| `gh-actions-billing` | GitHub Actions Billing | Repository | GitHub PAT -- actions:read | [docs](./consumer/permissions/gh-actions-billing.md) |
| `gitleaks` | gitleaks (Secrets Scanner) | Repository | Local or GitHub token | [docs](./consumer/permissions/gitleaks.md) |
| `identity-correlator` | Identity Correlator | Tenant | Microsoft Graph -- Directory.Read.All | [docs](./consumer/permissions/identity-correlator.md) |
| `identity-graph-expansion` | Identity Graph Expansion | Tenant | Microsoft Graph -- Directory.Read.All | [docs](./consumer/permissions/identity-graph-expansion.md) |
| `infracost` | Infracost IaC Cost Estimation | Repository | Local (no cloud credentials) | [docs](./consumer/permissions/infracost.md) |
| `kube-bench` | kube-bench (AKS node-level CIS compliance) | Subscription | Azure Reader | [docs](./consumer/permissions/kube-bench.md) |
| `kubescape` | Kubescape (AKS runtime posture) | Subscription | Azure Reader | [docs](./consumer/permissions/kubescape.md) |
| `loadtesting` | Azure Load Testing (Failed and Regressed Runs) | Subscription | Azure Reader | [docs](./consumer/permissions/loadtesting.md) |
| `maester` | Maester | Tenant | Microsoft Graph -- Directory.Read.All | [docs](./consumer/permissions/maester.md) |
| `powerpipe` | Powerpipe Compliance Benchmarks | Subscription | Azure Reader | [docs](./consumer/permissions/powerpipe.md) |
| `prowler` | Prowler (Azure security posture) | Subscription | Azure Reader | [docs](./consumer/permissions/prowler.md) |
| `psrule` | PSRule for Azure | Subscription | Azure Reader | [docs](./consumer/permissions/psrule.md) |
| `scorecard` | OpenSSF Scorecard | Repository | GitHub token (public repos: none) | [docs](./consumer/permissions/scorecard.md) |
| `sentinel-coverage` | Microsoft Sentinel (Coverage / Posture) | Workspace | Azure Reader | [docs](./consumer/permissions/sentinel-coverage.md) |
| `sentinel-incidents` | Microsoft Sentinel (Active Incidents) | Workspace | Azure Reader | [docs](./consumer/permissions/sentinel-incidents.md) |
| `terraform-iac` | Terraform IaC Validation | Repository | Local (no cloud credentials) | [docs](./consumer/permissions/terraform-iac.md) |
| `trivy` | Trivy Vulnerability Scanner | Repository | Local (no cloud credentials) | [docs](./consumer/permissions/trivy.md) |
| `wara` | Well-Architected Reliability Assessment | Subscription | Azure Reader | [docs](./consumer/permissions/wara.md) |
| `zizmor` | zizmor (Actions YAML Scanner) | Repository | Local (no cloud credentials) | [docs](./consumer/permissions/zizmor.md) |

## Permission domains at a glance

| Domain | Baseline role |
|---|---|
| **Azure** | **Reader** at the relevant scope (subscription, management group, or workspace) |
| **Microsoft Graph** | Read-only application or delegated scopes (Directory.Read.All) |
| **GitHub** | Repository **Read** PAT (or unauthenticated for public repos) |
| **Azure DevOps** | PAT with read-only scopes (Build:Read, Code:Read, Service Connections:Read) |
| **Local CLI / IaC** | None (runs locally, no cloud credentials needed) |
| **Optional sink** | **Monitoring Metrics Publisher** on Log Analytics DCR (only write role) |

## Cross-cutting topics

- [Cross-tool matrix, tiers, least-privilege](./consumer/permissions/_summary.md)
- [Continuous Control Function App](./consumer/permissions/_continuous-control.md)
- [Multi-tenant fan-out](./consumer/permissions/_multi-tenant.md)
- [Management-group recursion](./consumer/permissions/_management-group.md)
- [Auth troubleshooting](./consumer/permissions/_troubleshooting.md)

## Optional / disabled-by-default tools

| Tool | Scope | Opt-in flag | Detail |
|---|---|---|---|
| **Copilot AI Triage** | Repository | `--EnableAiTriage` | [docs](./consumer/permissions/copilot-triage.md) |

## See also

- [PERMISSIONS.md](../PERMISSIONS.md) -- Full permission reference with per-tool policy details
- [docs/tool-catalog.md](./tool-catalog.md) -- Tool catalog with what each tool covers
