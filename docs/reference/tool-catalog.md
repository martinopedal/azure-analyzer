# Tool catalog (consumer view)

> GENERATED FROM tools/tool-manifest.json - do not edit by hand.
> Regenerate with `pwsh -File scripts/Generate-ToolCatalog.ps1`.
> Stale catalogs are blocked by the `tool-catalog-fresh` CI check.

Manifest schema version: `2.2`

This page lists every analyzer tool azure-analyzer can run, what it covers, what scope it targets, and where to find consumer-focused setup notes when one exists. For the full manifest fields (normalizer, install kind, upstream pin, report color/phase) see [docs/contributor/tool-catalog.md](../contributor/tool-catalog.md).

**Total enabled:** 40. **Disabled / opt-in:** 1.

## Enabled by default

| Name | Display name | Scope | Provider | Frameworks | What it does | Docs |
|---|---|---|---|---|---|---|
| `ado-connections` | ADO Service Connections | ado | ado | NIST 800-53, SOC2, PCI-DSS | Azure DevOps service-connection security: identity, scope, federation. | - |
| `ado-consumption` | ADO Pipeline Consumption | ado | ado | Azure CAF, SOC2 | Azure DevOps pipeline consumption telemetry: runner share, duration regression, and failure waste. | [docs](./permissions/ado-consumption.md) |
| `ado-consumption` | ADO Pipeline Consumption | ado | ado | Azure CAF, SOC2 | Azure DevOps pipeline consumption telemetry: runner share, duration regression, and failure waste. | [docs](./permissions/ado-consumption.md) |
| `ado-pipeline-correlator` | ADO Pipeline Run Correlator | ado | ado | NIST 800-53, SOC2 | Correlates ADO pipeline runs with downstream Azure resource changes. | - |
| `ado-pipeline-correlator` | ADO Pipeline Run Correlator | ado | ado | NIST 800-53, SOC2 | Correlates ADO pipeline runs with downstream Azure resource changes. | - |
| `ado-pipelines` | ADO Pipeline Security | ado | ado | NIST 800-53, SOC2, PCI-DSS | Azure DevOps pipeline-security posture (variable groups, environments, approvals). | - |
| `ado-pipelines` | ADO Pipeline Security | ado | ado | NIST 800-53, SOC2, PCI-DSS | Azure DevOps pipeline-security posture (variable groups, environments, approvals). | - |
| `ado-repos-secrets` | ADO Repos Secret Scanning | ado | ado | NIST 800-53, SOC2, PCI-DSS | Secret scanning across Azure DevOps repositories via gitleaks. | [docs](./gitleaks-pattern-tuning.md) |
| `ado-repos-secrets` | ADO Repos Secret Scanning | ado | ado | NIST 800-53, SOC2, PCI-DSS | Secret scanning across Azure DevOps repositories via gitleaks. | [docs](./gitleaks-pattern-tuning.md) |
| `aks-karpenter-cost` | AKS Karpenter Cost (consolidation + node utilization) | subscription | azure | Azure WAF, Azure CAF | AKS Karpenter Cost (consolidation + node utilization) | - |
| `aks-rightsizing` | AKS Rightsizing (Container Insights utilization) | subscription | azure | Azure WAF, Azure CAF | AKS Rightsizing (Container Insights utilization) | - |
| `alz-queries` | ALZ Resource Graph Queries | managementGroup | azure | CIS Azure, NIST 800-53, Azure WAF, Azure CAF | ALZ Resource Graph queries: landing-zone compliance and drift detection. | - |
| `appinsights` | Application Insights Performance Signals | subscription | azure | Azure WAF | Application Insights telemetry signals: slow requests, dependency failures, and exception clusters via KQL. | - |
| `azgovviz` | AzGovViz | managementGroup | azure | Azure WAF, Azure CAF | Azure Governance Visualizer: management-group / subscription / RBAC / policy posture. | - |
| `azqr` | Azure Quick Review | subscription | azure | Azure WAF, Azure CAF | Azure best-practice review across reliability, security, cost, performance and operational excellence. | - |
| `azure-cost` | Azure Cost (Consumption API) | subscription | azure | Azure CAF | Per-subscription monthly Azure spend pulled from the Consumption API. | - |
| `azure-quota` | Azure Quota Reports | subscription | azure | Azure WAF, Azure CAF | Azure Quota Reports | - |
| `bicep-iac` | Bicep IaC Validation | repository | cli | CIS Azure, NIST 800-53, Azure WAF, Azure CAF | Bicep IaC validation: lint, build, and best-practice checks. | - |
| `defender-for-cloud` | Microsoft Defender for Cloud | subscription | azure | CIS Azure, NIST 800-53, Azure WAF, Azure CAF, SOC2, PCI-DSS | Pulls Microsoft Defender for Cloud Secure Score and active recommendations per subscription. | - |
| `falco` | Falco (AKS runtime anomaly detection) | subscription | azure | CIS Azure, NIST 800-53 | AKS runtime anomaly detection (syscall-level threat detection). | - |
| `finops` | FinOps Signals (Idle Resource Detection) | subscription | azure | Azure WAF, Azure CAF | FinOps signals: idle / orphaned resources that drive avoidable spend. | - |
| `gh-actions-billing` | GitHub Actions Billing | repository | github | Azure CAF, SOC2 | GitHub Actions billing and runner-minute telemetry for CI/CD cost optimization. | [docs](./permissions/gh-actions-billing.md) |
| `gitleaks` | gitleaks (Secrets Scanner) | repository | cli | NIST 800-53, SOC2, PCI-DSS | Secret scanning across local or remote git repositories. | [docs](./gitleaks-pattern-tuning.md) |
| `identity-correlator` | Identity Correlator | tenant | graph | NIST 800-53, SOC2, PCI-DSS | Correlates Entra identities, role assignments, and resource ownership. | - |
| `identity-graph-expansion` | Identity Graph Expansion | tenant | graph | NIST 800-53, SOC2 | Expands the identity graph: cross-tenant B2B + service-principal-to-resource edges. | - |
| `infracost` | Infracost IaC Cost Estimation | repository | cli | Azure CAF | Pre-deploy cost estimate for Terraform and Bicep resources. | - |
| `kube-bench` | kube-bench (AKS node-level CIS compliance) | subscription | azure | CIS Azure | CIS Kubernetes benchmark for AKS node hardening. | - |
| `kubescape` | Kubescape (AKS runtime posture) | subscription | azure | CIS Azure, NIST 800-53 | Runtime posture for AKS clusters: misconfigurations, RBAC, network policies, vulnerabilities. | - |
| `loadtesting` | Azure Load Testing (Failed and Regressed Runs) | subscription | azure | Azure WAF | Azure Load Testing reliability signals: failed runs, cancelled runs, and metric regressions. | - |
| `maester` | Maester | tenant | microsoft365 | NIST 800-53, SOC2, PCI-DSS | Microsoft Entra (Identity) security baseline: conditional access, MFA, privileged roles. | [docs](./ai-triage.md) |
| `powerpipe` | Powerpipe Compliance Benchmarks | subscription | azure | CIS Azure, NIST 800-53, PCI-DSS, SOC2 | Powerpipe control-pack benchmark results with framework-aware compliance metadata. | - |
| `prowler` | Prowler (Azure security posture) | subscription | azure | CIS Azure, NIST 800-53, ISO27001, PCI-DSS, HIPAA, SOC2, MITRE, GDPR, FedRAMP | Prowler (Azure security posture) | - |
| `psrule` | PSRule for Azure | subscription | azure | CIS Azure, NIST 800-53, Azure WAF, Azure CAF | Microsoft PSRule for Azure: Well-Architected and best-practice rule baseline. | - |
| `scorecard` | OpenSSF Scorecard | repository | github | NIST 800-53, SOC2 | OpenSSF Scorecard for repository supply-chain hygiene. | - |
| `sentinel-coverage` | Microsoft Sentinel (Coverage / Posture) | workspace | azure | NIST 800-53, SOC2, PCI-DSS, Azure WAF | Sentinel detection posture: analytic rules, watchlists, data connectors, hunting queries. | - |
| `sentinel-incidents` | Microsoft Sentinel (Active Incidents) | workspace | azure | NIST 800-53, SOC2 | Pulls active Microsoft Sentinel incidents from a Log Analytics workspace. | - |
| `terraform-iac` | Terraform IaC Validation | repository | cli | CIS Azure, NIST 800-53, Azure WAF, Azure CAF | Terraform IaC validation: tflint / tfsec / checkov-style checks. | - |
| `trivy` | Trivy Vulnerability Scanner | repository | cli | CIS Azure, NIST 800-53, PCI-DSS | Vulnerability and IaC misconfiguration scanner for repos and container images. | - |
| `wara` | Well-Architected Reliability Assessment | subscription | azure | Azure WAF, Azure CAF | Well-Architected Reliability Assessment workflow for production workloads. | - |
| `zizmor` | zizmor (Actions YAML Scanner) | repository | cli | NIST 800-53, SOC2 | Static analysis for GitHub Actions workflow security risks. | - |

## Disabled / opt-in

These tools are wired but turned off in the manifest. Enable them by setting `enabled: true` in `tools/tool-manifest.json` or via `tools/install-config.json`.

| Name | Display name | Scope | Provider | Frameworks | What it does |
|---|---|---|---|---|---|
| `copilot-triage` | Copilot AI Triage | repository | cli | - | Optional Copilot-powered AI triage for finding prioritization (disabled by default). |

## Scope reference

| Scope | Targets |
|---|---|
| `subscription` | Single Azure subscription (`-SubscriptionId`). |
| `managementGroup` | Azure Management Group (`-ManagementGroupId`). |
| `tenant` | Entra ID tenant (`-TenantId`, requires `Connect-MgGraph`). |
| `repository` | GitHub or ADO repo (`-Repository` or `-RepoPath`). |
| `ado` | Azure DevOps organization (`-AdoOrg`). |
| `workspace` | Log Analytics / Sentinel workspace (`-SentinelWorkspaceId`). |

