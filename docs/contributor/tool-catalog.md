# Tool catalog (contributor view)

> GENERATED FROM tools/tool-manifest.json - do not edit by hand.
> Regenerate with `pwsh -File scripts/Generate-ToolCatalog.ps1`.
> Stale catalogs are blocked by the `tool-catalog-fresh` CI check.

Manifest schema version: `2.2`

Full manifest projection: every wired tool with normalizer, invocation, install, report, and upstream metadata. For the consumer-friendly subset see [docs/consumer/tool-catalog.md](../consumer/tool-catalog.md). To onboard a new tool follow [adding-a-tool.md](./adding-a-tool.md).

**Total tools registered:** 37.

## Registration matrix

| Name | Display name | Type | Provider | Scope | Status | Tier | Platforms | Frameworks |
|---|---|---|---|---|---|---|---|---|
| `ado-connections` | ADO Service Connections | collector | ado | ado | Enabled | 0 | windows, macos, linux | NIST 800-53, SOC2, PCI-DSS |
| `ado-consumption` | ADO Pipeline Consumption | collector | ado | ado | Enabled | 0 | windows, macos, linux | Azure CAF, SOC2 |
| `ado-pipeline-correlator` | ADO Pipeline Run Correlator | correlator | ado | ado | Enabled | 0 | windows, macos, linux | NIST 800-53, SOC2 |
| `ado-pipelines` | ADO Pipeline Security | collector | ado | ado | Enabled | 0 | windows, macos, linux | NIST 800-53, SOC2, PCI-DSS |
| `ado-repos-secrets` | ADO Repos Secret Scanning | collector | ado | ado | Enabled | 0 | windows, macos, linux | NIST 800-53, SOC2, PCI-DSS |
| `aks-karpenter-cost` | AKS Karpenter Cost (consolidation + node utilization) | collector | azure | subscription | Enabled | 0 | windows, macos, linux | Azure WAF, Azure CAF |
| `aks-rightsizing` | AKS Rightsizing (Container Insights utilization) | collector | azure | subscription | Enabled | 0 | windows, macos, linux | Azure WAF, Azure CAF |
| `alz-queries` | ALZ Resource Graph Queries | collector | azure | managementGroup | Enabled | 0 | windows, macos, linux | CIS Azure, NIST 800-53, Azure WAF, Azure CAF |
| `appinsights` | Application Insights Performance Signals | collector | azure | subscription | Enabled | 0 | windows, macos, linux | Azure WAF |
| `azgovviz` | AzGovViz | collector | azure | managementGroup | Enabled | 0 | windows, macos, linux | Azure WAF, Azure CAF |
| `azqr` | Azure Quick Review | collector | azure | subscription | Enabled | 0 | windows, macos, linux | Azure WAF, Azure CAF |
| `azure-cost` | Azure Cost (Consumption API) | collector | azure | subscription | Enabled | 0 | windows, macos, linux | Azure CAF |
| `azure-quota` | Azure Quota Reports | collector | azure | subscription | Enabled | 0 | windows, macos, linux | Azure WAF, Azure CAF |
| `bicep-iac` | Bicep IaC Validation | collector | cli | repository | Enabled | 0 | windows, macos, linux | CIS Azure, NIST 800-53, Azure WAF, Azure CAF |
| `copilot-triage` | Copilot AI Triage | enrichment | cli | repository | Disabled | 0 | windows, macos, linux | - |
| `defender-for-cloud` | Microsoft Defender for Cloud | enrichment | azure | subscription | Enabled | 0 | windows, macos, linux | CIS Azure, NIST 800-53, Azure WAF, Azure CAF, SOC2, PCI-DSS |
| `falco` | Falco (AKS runtime anomaly detection) | scanner | azure | subscription | Enabled | 0 | windows, macos, linux | CIS Azure, NIST 800-53 |
| `finops` | FinOps Signals (Idle Resource Detection) | collector | azure | subscription | Enabled | 0 | windows, macos, linux | Azure WAF, Azure CAF |
| `gh-actions-billing` | GitHub Actions Billing | collector | github | repository | Enabled | 0 | windows, macos, linux | Azure CAF, SOC2 |
| `gitleaks` | gitleaks (Secrets Scanner) | collector | cli | repository | Enabled | 0 | windows, macos, linux | NIST 800-53, SOC2, PCI-DSS |
| `identity-correlator` | Identity Correlator | correlator | graph | tenant | Enabled | 3 | windows, macos, linux | NIST 800-53, SOC2, PCI-DSS |
| `identity-graph-expansion` | Identity Graph Expansion | correlator | graph | tenant | Enabled | 3 | windows, macos, linux | NIST 800-53, SOC2 |
| `infracost` | Infracost IaC Cost Estimation | collector | cli | repository | Enabled | 0 | windows, macos, linux | Azure CAF |
| `kube-bench` | kube-bench (AKS node-level CIS compliance) | scanner | azure | subscription | Enabled | 0 | windows, macos, linux | CIS Azure |
| `kubescape` | Kubescape (AKS runtime posture) | scanner | azure | subscription | Enabled | 0 | windows, macos, linux | CIS Azure, NIST 800-53 |
| `loadtesting` | Azure Load Testing (Failed and Regressed Runs) | collector | azure | subscription | Enabled | 0 | windows, macos, linux | Azure WAF |
| `maester` | Maester | collector | microsoft365 | tenant | Enabled | 0 | windows, macos, linux | NIST 800-53, SOC2, PCI-DSS |
| `powerpipe` | Powerpipe Compliance Benchmarks | collector | azure | subscription | Enabled | 0 | windows, macos, linux | CIS Azure, NIST 800-53, PCI-DSS, SOC2 |
| `prowler` | Prowler (Azure security posture) | scanner | azure | subscription | Enabled | 0 | windows, macos, linux | CIS Azure, NIST 800-53, ISO27001, PCI-DSS, HIPAA, SOC2, MITRE, GDPR, FedRAMP |
| `psrule` | PSRule for Azure | collector | azure | subscription | Enabled | 0 | windows, macos, linux | CIS Azure, NIST 800-53, Azure WAF, Azure CAF |
| `scorecard` | OpenSSF Scorecard | collector | github | repository | Enabled | 0 | windows, macos, linux | NIST 800-53, SOC2 |
| `sentinel-coverage` | Microsoft Sentinel (Coverage / Posture) | collector | azure | workspace | Enabled | 0 | windows, macos, linux | NIST 800-53, SOC2, PCI-DSS, Azure WAF |
| `sentinel-incidents` | Microsoft Sentinel (Active Incidents) | enrichment | azure | workspace | Enabled | 0 | windows, macos, linux | NIST 800-53, SOC2 |
| `terraform-iac` | Terraform IaC Validation | collector | cli | repository | Enabled | 0 | windows, macos, linux | CIS Azure, NIST 800-53, Azure WAF, Azure CAF |
| `trivy` | Trivy Vulnerability Scanner | collector | cli | repository | Enabled | 0 | windows, macos, linux | CIS Azure, NIST 800-53, PCI-DSS |
| `wara` | Well-Architected Reliability Assessment | collector | azure | subscription | Enabled | 0 | windows, macos, linux | Azure WAF, Azure CAF |
| `zizmor` | zizmor (Actions YAML Scanner) | collector | cli | repository | Enabled | 0 | windows, macos, linux | NIST 800-53, SOC2 |

## Invocation

| Name | Normalizer | Invoke | Script / module | Required params |
|---|---|---|---|---|
| `ado-connections` | `Normalize-ADOConnections` | script | `modules/Invoke-ADOServiceConnections.ps1` | AdoOrg |
| `ado-consumption` | `Normalize-AdoConsumption` | script | `modules/Invoke-AdoConsumption.ps1` | Organization |
| `ado-pipeline-correlator` | `Normalize-ADOPipelineCorrelator` | script | `modules/Invoke-ADOPipelineCorrelator.ps1` | AdoOrg |
| `ado-pipelines` | `Normalize-ADOPipelineSecurity` | script | `modules/Invoke-ADOPipelineSecurity.ps1` | AdoOrg |
| `ado-repos-secrets` | `Normalize-ADORepoSecrets` | script | `modules/Invoke-ADORepoSecrets.ps1` | AdoOrg |
| `aks-karpenter-cost` | `Normalize-AksKarpenterCost` | script | `modules/Invoke-AksKarpenterCost.ps1` | SubscriptionId |
| `aks-rightsizing` | `Normalize-AksRightsizing` | script | `modules/Invoke-AksRightsizing.ps1` | SubscriptionId |
| `alz-queries` | `Normalize-AlzQueries` | script | `modules/Invoke-AlzQueries.ps1` | SubscriptionId, ManagementGroupId |
| `appinsights` | `Normalize-AppInsights` | script | `modules/Invoke-AppInsights.ps1` | SubscriptionId |
| `azgovviz` | `Normalize-AzGovViz` | script | `modules/Invoke-AzGovViz.ps1` | ManagementGroupId |
| `azqr` | `Normalize-Azqr` | script | `modules/Invoke-Azqr.ps1` | SubscriptionId |
| `azure-cost` | `Normalize-AzureCost` | script | `modules/Invoke-AzureCost.ps1` | SubscriptionId |
| `azure-quota` | `Normalize-AzureQuotaReports` | script | `modules/Invoke-AzureQuotaReports.ps1` | SubscriptionId |
| `bicep-iac` | `Normalize-IaCBicep` | script | `modules/Invoke-IaCBicep.ps1` | - |
| `copilot-triage` | `` | script | `modules/Invoke-CopilotTriage.ps1` | - |
| `defender-for-cloud` | `Normalize-DefenderForCloud` | script | `modules/Invoke-DefenderForCloud.ps1` | SubscriptionId |
| `falco` | `Normalize-Falco` | script | `modules/Invoke-Falco.ps1` | SubscriptionId |
| `finops` | `Normalize-FinOpsSignals` | script | `modules/Invoke-FinOpsSignals.ps1` | SubscriptionId |
| `gh-actions-billing` | `Normalize-GhActionsBilling` | script | `modules/Invoke-GhActionsBilling.ps1` | Org |
| `gitleaks` | `Normalize-Gitleaks` | script | `modules/Invoke-Gitleaks.ps1` | - |
| `identity-correlator` | `Normalize-IdentityCorrelation` | function | `modules/shared/IdentityCorrelator.ps1` | TenantId |
| `identity-graph-expansion` | `Normalize-IdentityGraphExpansion` | function | `modules/Invoke-IdentityGraphExpansion.ps1` | TenantId |
| `infracost` | `Normalize-Infracost` | script | `modules/Invoke-Infracost.ps1` | - |
| `kube-bench` | `Normalize-KubeBench` | script | `modules/Invoke-KubeBench.ps1` | SubscriptionId |
| `kubescape` | `Normalize-Kubescape` | script | `modules/Invoke-Kubescape.ps1` | SubscriptionId |
| `loadtesting` | `Normalize-AzureLoadTesting` | script | `modules/Invoke-AzureLoadTesting.ps1` | SubscriptionId |
| `maester` | `Normalize-Maester` | script | `modules/Invoke-Maester.ps1` | - |
| `powerpipe` | `Normalize-Powerpipe` | script | `modules/Invoke-Powerpipe.ps1` | SubscriptionId |
| `prowler` | `Normalize-Prowler` | script | `modules/Invoke-Prowler.ps1` | SubscriptionId |
| `psrule` | `Normalize-PSRule` | script | `modules/Invoke-PSRule.ps1` | SubscriptionId |
| `scorecard` | `Normalize-Scorecard` | script | `modules/Invoke-Scorecard.ps1` | Repository |
| `sentinel-coverage` | `Normalize-SentinelCoverage` | script | `modules/Invoke-SentinelCoverage.ps1` | WorkspaceResourceId |
| `sentinel-incidents` | `Normalize-SentinelIncidents` | script | `modules/Invoke-SentinelIncidents.ps1` | WorkspaceResourceId |
| `terraform-iac` | `Normalize-IaCTerraform` | script | `modules/Invoke-IaCTerraform.ps1` | - |
| `trivy` | `Normalize-Trivy` | script | `modules/Invoke-Trivy.ps1` | - |
| `wara` | `Normalize-WARA` | script | `modules/Invoke-WARA.ps1` | SubscriptionId |
| `zizmor` | `Normalize-Zizmor` | script | `modules/Invoke-Zizmor.ps1` | - |

## Install + upstream

| Name | Install kind | Upstream pin | Report color | Phase |
|---|---|---|---|---|
| `ado-connections` | none | n/a | `#0078d4` | 2 |
| `ado-consumption` | none | n/a | `#5e35b1` | 2 |
| `ado-pipeline-correlator` | none | n/a | `#00838f` | 2 |
| `ado-pipelines` | none | n/a | `#006064` | 2 |
| `ado-repos-secrets` | none | n/a | `#ad1457` | 2 |
| `aks-karpenter-cost` | psmodule | n/a | `#00695c` | 4 |
| `aks-rightsizing` | psmodule | n/a | `#2e7d32` | 4 |
| `alz-queries` | psmodule | martinopedal/alz-graph-queries @ HEAD | `#e65100` | 1 |
| `appinsights` | psmodule | n/a | `#00838f` | 4 |
| `azgovviz` | gitclone ("https://github.com/JulianHayward/Azure-MG-Sub-Governance-Reporting") | JulianHayward/Azure-MG-Sub-Governance-Reporting @ HEAD | `#00838f` | 1 |
| `azqr` | cli ("azqr") | Azure/azqr @ latest | `#1565c0` | 1 |
| `azure-cost` | psmodule | n/a | `#388e3c` | 4 |
| `azure-quota` | cli ("az") | martinopedal/azure-quota-reports | `#455a64` | 4 |
| `bicep-iac` | cli ("bicep") | Azure/bicep @ latest | `#0d47a1` | 7 |
| `copilot-triage` | none | n/a | `#6a1b9a` | 8 |
| `defender-for-cloud` | psmodule | n/a | `#0078d4` | 4 |
| `falco` | psmodule | falcosecurity/falco @ 0.42.0 | `#ef6c00` | 6 |
| `finops` | psmodule | n/a | `#00897b` | 4 |
| `gh-actions-billing` | cli ("gh") | n/a | `#8e24aa` | 1 |
| `gitleaks` | cli ("gitleaks") | gitleaks/gitleaks @ latest | `#c62828` | 3 |
| `identity-correlator` | psmodule | n/a | `#5e35b1` | 2 |
| `identity-graph-expansion` | psmodule | n/a | `#283593` | 2 |
| `infracost` | cli ("infracost") | infracost/infracost @ latest | `#2e7d32` | 7 |
| `kube-bench` | none | n/a | `#5e35b1` | 6 |
| `kubescape` | cli ("kubescape") | kubescape/kubescape @ v3 | `#7b1fa2` | 6 |
| `loadtesting` | psmodule | n/a | `#00695c` | 4 |
| `maester` | psmodule | maester365/maester @ latest | `#7b1fa2` | 1 |
| `powerpipe` | cli ("powerpipe") | turbot/powerpipe @ latest | `#455a64` | 1 |
| `prowler` | cli ("prowler") | prowler-cloud/prowler @ latest | `#1f2937` | 4 |
| `psrule` | psmodule | microsoft/PSRule.Rules.Azure @ latest | `#6a1b9a` | 1 |
| `scorecard` | cli ("scorecard") | ossf/scorecard @ latest | `#ff6f00` | 1 |
| `sentinel-coverage` | psmodule | n/a | `#3949ab` | 4 |
| `sentinel-incidents` | psmodule | n/a | `#0078d4` | 4 |
| `terraform-iac` | cli ("terraform") | hashicorp/terraform @ latest | `#5c4ee5` | 7 |
| `trivy` | cli ("trivy") | aquasecurity/trivy @ latest | `#00695c` | 3 |
| `wara` | psmodule | Azure/Azure-Proactive-Resiliency-Library-v2 @ latest | `#2e7d32` | 1 |
| `zizmor` | cli ("zizmor") | woodruffw/zizmor @ latest | `#ad1457` | 3 |

## Notes

- `tier` is `requiredPermissionTier` (0..6, see [docs/contributor/ARCHITECTURE.md](./ARCHITECTURE.md#permission-tiers-tier-06) for the tier breakdown).
- `phase` is the report grouping hint used by `New-HtmlReport.ps1` and `New-MdReport.ps1`.
- `report.color` is consumed by the per-source bar chart in the HTML report.
- `install.kind` is one of `psmodule`, `cli`, `gitclone`, `none` and is enforced by `modules/shared/Installer.ps1`.
- `upstream` drives the weekly auto-update loop; `pinType` and `currentPin` are managed by `tools/Update-ToolPins.ps1`.

