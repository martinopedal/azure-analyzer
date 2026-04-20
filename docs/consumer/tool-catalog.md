# Tool catalog (consumer view)

> GENERATED FROM tools/tool-manifest.json - do not edit by hand.
> Regenerate with `pwsh -File scripts/Generate-ToolCatalog.ps1`.
> Stale catalogs are blocked by the `tool-catalog-fresh` CI check.

Manifest schema version: `2.2`

This page lists every analyzer tool azure-analyzer can run, what it covers, what scope it targets, and where to find consumer-focused setup notes when one exists. For the full manifest fields (normalizer, install kind, upstream pin, report color/phase) see [docs/contributor/tool-catalog.md](../contributor/tool-catalog.md).

**Total enabled:** 30. **Disabled / opt-in:** 1.

## Enabled by default

| Name | Display name | Scope | Provider | What it does | Docs |
|---|---|---|---|---|---|
| `ado-connections` | ADO Service Connections | ado | ado | Azure DevOps service-connection security: identity, scope, federation. | - |
| `ado-pipeline-correlator` | ADO Pipeline Run Correlator | ado | ado | Correlates ADO pipeline runs with downstream Azure resource changes. | - |
| `ado-pipelines` | ADO Pipeline Security | ado | ado | Azure DevOps pipeline-security posture (variable groups, environments, approvals). | - |
| `ado-repos-secrets` | ADO Repos Secret Scanning | ado | ado | Secret scanning across Azure DevOps repositories via gitleaks. | [docs](./gitleaks-pattern-tuning.md) |
| `aks-rightsizing` | AKS Rightsizing (Container Insights utilization) | subscription | azure | AKS Rightsizing (Container Insights utilization) | - |
| `alz-queries` | ALZ Resource Graph Queries | managementGroup | azure | ALZ Resource Graph queries: landing-zone compliance and drift detection. | - |
| `appinsights` | Application Insights Performance Signals | subscription | azure | Application Insights telemetry signals: slow requests, dependency failures, and exception clusters via KQL. | - |
| `azgovviz` | AzGovViz | managementGroup | azure | Azure Governance Visualizer: management-group / subscription / RBAC / policy posture. | - |
| `azqr` | Azure Quick Review | subscription | azure | Azure best-practice review across reliability, security, cost, performance and operational excellence. | - |
| `azure-cost` | Azure Cost (Consumption API) | subscription | azure | Per-subscription monthly Azure spend pulled from the Consumption API. | - |
| `bicep-iac` | Bicep IaC Validation | repository | cli | Bicep IaC validation: lint, build, and best-practice checks. | - |
| `defender-for-cloud` | Microsoft Defender for Cloud | subscription | azure | Pulls Microsoft Defender for Cloud Secure Score and active recommendations per subscription. | - |
| `falco` | Falco (AKS runtime anomaly detection) | subscription | azure | AKS runtime anomaly detection (syscall-level threat detection). | - |
| `finops` | FinOps Signals (Idle Resource Detection) | subscription | azure | FinOps signals: idle / orphaned resources that drive avoidable spend. | - |
| `gitleaks` | gitleaks (Secrets Scanner) | repository | cli | Secret scanning across local or remote git repositories. | [docs](./gitleaks-pattern-tuning.md) |
| `identity-correlator` | Identity Correlator | tenant | graph | Correlates Entra identities, role assignments, and resource ownership. | - |
| `identity-graph-expansion` | Identity Graph Expansion | tenant | graph | Expands the identity graph: cross-tenant B2B + service-principal-to-resource edges. | - |
| `infracost` | Infracost IaC Cost Estimation | repository | cli | Pre-deploy cost estimate for Terraform and Bicep resources. | - |
| `kube-bench` | kube-bench (AKS node-level CIS compliance) | subscription | azure | CIS Kubernetes benchmark for AKS node hardening. | - |
| `kubescape` | Kubescape (AKS runtime posture) | subscription | azure | Runtime posture for AKS clusters: misconfigurations, RBAC, network policies, vulnerabilities. | - |
| `loadtesting` | Azure Load Testing (Failed and Regressed Runs) | subscription | azure | Azure Load Testing reliability signals: failed runs, cancelled runs, and metric regressions. | - |
| `maester` | Maester | tenant | microsoft365 | Microsoft Entra (Identity) security baseline: conditional access, MFA, privileged roles. | [docs](./ai-triage.md) |
| `psrule` | PSRule for Azure | subscription | azure | Microsoft PSRule for Azure: Well-Architected and best-practice rule baseline. | - |
| `scorecard` | OpenSSF Scorecard | repository | github | OpenSSF Scorecard for repository supply-chain hygiene. | - |
| `sentinel-coverage` | Microsoft Sentinel (Coverage / Posture) | workspace | azure | Sentinel detection posture: analytic rules, watchlists, data connectors, hunting queries. | - |
| `sentinel-incidents` | Microsoft Sentinel (Active Incidents) | workspace | azure | Pulls active Microsoft Sentinel incidents from a Log Analytics workspace. | - |
| `terraform-iac` | Terraform IaC Validation | repository | cli | Terraform IaC validation: tflint / tfsec / checkov-style checks. | - |
| `trivy` | Trivy Vulnerability Scanner | repository | cli | Vulnerability and IaC misconfiguration scanner for repos and container images. | - |
| `wara` | Well-Architected Reliability Assessment | subscription | azure | Well-Architected Reliability Assessment workflow for production workloads. | - |
| `zizmor` | zizmor (Actions YAML Scanner) | repository | cli | Static analysis for GitHub Actions workflow security risks. | - |

## Disabled / opt-in

These tools are wired but turned off in the manifest. Enable them by setting `enabled: true` in `tools/tool-manifest.json` or via `tools/install-config.json`.

| Name | Display name | Scope | Provider | What it does |
|---|---|---|---|---|
| `copilot-triage` | Copilot AI Triage | repository | cli | Optional Copilot-powered AI triage for finding prioritization (disabled by default). |

## Scope reference

| Scope | Targets |
|---|---|
| `subscription` | Single Azure subscription (`-SubscriptionId`). |
| `managementGroup` | Azure Management Group (`-ManagementGroupId`). |
| `tenant` | Entra ID tenant (`-TenantId`, requires `Connect-MgGraph`). |
| `repository` | GitHub or ADO repo (`-Repository` or `-RepoPath`). |
| `ado` | Azure DevOps organization (`-AdoOrg`). |
| `workspace` | Log Analytics / Sentinel workspace (`-SentinelWorkspaceId`). |

