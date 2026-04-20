# Tool catalog (contributor view)

> GENERATED FROM tools/tool-manifest.json - do not edit by hand.
> Regenerate with `pwsh -File scripts/Generate-ToolCatalog.ps1`.
> Stale catalogs are blocked by the `tool-catalog-fresh` CI check.

Manifest schema version: `2.2`

Full manifest projection: every wired tool with normalizer, invocation, install, report, and upstream metadata. For the consumer-friendly subset see [docs/consumer/tool-catalog.md](../consumer/tool-catalog.md). To onboard a new tool follow [adding-a-tool.md](./adding-a-tool.md).

**Total tools registered:** 30.

## Registration matrix

| Name | Display name | Type | Provider | Scope | Status | Tier | Platforms |
|---|---|---|---|---|---|---|---|
| `ado-connections` | ADO Service Connections | collector | ado | ado | Enabled | 0 | windows, macos, linux |
| `ado-pipeline-correlator` | ADO Pipeline Run Correlator | correlator | ado | ado | Enabled | 0 | windows, macos, linux |
| `ado-pipelines` | ADO Pipeline Security | collector | ado | ado | Enabled | 0 | windows, macos, linux |
| `ado-repos-secrets` | ADO Repos Secret Scanning | collector | ado | ado | Enabled | 0 | windows, macos, linux |
| `alz-queries` | ALZ Resource Graph Queries | collector | azure | managementGroup | Enabled | 0 | windows, macos, linux |
| `appinsights` | Application Insights Performance Signals | collector | azure | subscription | Enabled | 0 | windows, macos, linux |
| `azgovviz` | AzGovViz | collector | azure | managementGroup | Enabled | 0 | windows, macos, linux |
| `azqr` | Azure Quick Review | collector | azure | subscription | Enabled | 0 | windows, macos, linux |
| `azure-cost` | Azure Cost (Consumption API) | collector | azure | subscription | Enabled | 0 | windows, macos, linux |
| `bicep-iac` | Bicep IaC Validation | collector | cli | repository | Enabled | 0 | windows, macos, linux |
| `copilot-triage` | Copilot AI Triage | enrichment | cli | repository | Disabled | 0 | windows, macos, linux |
| `defender-for-cloud` | Microsoft Defender for Cloud | enrichment | azure | subscription | Enabled | 0 | windows, macos, linux |
| `falco` | Falco (AKS runtime anomaly detection) | scanner | azure | subscription | Enabled | 0 | windows, macos, linux |
| `finops` | FinOps Signals (Idle Resource Detection) | collector | azure | subscription | Enabled | 0 | windows, macos, linux |
| `gitleaks` | gitleaks (Secrets Scanner) | collector | cli | repository | Enabled | 0 | windows, macos, linux |
| `identity-correlator` | Identity Correlator | correlator | graph | tenant | Enabled | 3 | windows, macos, linux |
| `identity-graph-expansion` | Identity Graph Expansion | correlator | graph | tenant | Enabled | 3 | windows, macos, linux |
| `infracost` | Infracost IaC Cost Estimation | collector | cli | repository | Enabled | 0 | windows, macos, linux |
| `kube-bench` | kube-bench (AKS node-level CIS compliance) | scanner | azure | subscription | Enabled | 0 | windows, macos, linux |
| `kubescape` | Kubescape (AKS runtime posture) | scanner | azure | subscription | Enabled | 0 | windows, macos, linux |
| `loadtesting` | Azure Load Testing (Failed and Regressed Runs) | collector | azure | subscription | Enabled | 0 | windows, macos, linux |
| `maester` | Maester | collector | microsoft365 | tenant | Enabled | 0 | windows, macos, linux |
| `psrule` | PSRule for Azure | collector | azure | subscription | Enabled | 0 | windows, macos, linux |
| `scorecard` | OpenSSF Scorecard | collector | github | repository | Enabled | 0 | windows, macos, linux |
| `sentinel-coverage` | Microsoft Sentinel (Coverage / Posture) | collector | azure | workspace | Enabled | 0 | windows, macos, linux |
| `sentinel-incidents` | Microsoft Sentinel (Active Incidents) | enrichment | azure | workspace | Enabled | 0 | windows, macos, linux |
| `terraform-iac` | Terraform IaC Validation | collector | cli | repository | Enabled | 0 | windows, macos, linux |
| `trivy` | Trivy Vulnerability Scanner | collector | cli | repository | Enabled | 0 | windows, macos, linux |
| `wara` | Well-Architected Reliability Assessment | collector | azure | subscription | Enabled | 0 | windows, macos, linux |
| `zizmor` | zizmor (Actions YAML Scanner) | collector | cli | repository | Enabled | 0 | windows, macos, linux |

## Invocation

| Name | Normalizer | Invoke | Script / module | Required params |
|---|---|---|---|---|
| `ado-connections` | `Normalize-ADOConnections` | script | `modules/Invoke-ADOServiceConnections.ps1` | AdoOrg |
| `ado-pipeline-correlator` | `Normalize-ADOPipelineCorrelator` | script | `modules/Invoke-ADOPipelineCorrelator.ps1` | AdoOrg |
| `ado-pipelines` | `Normalize-ADOPipelineSecurity` | script | `modules/Invoke-ADOPipelineSecurity.ps1` | AdoOrg |
| `ado-repos-secrets` | `Normalize-ADORepoSecrets` | script | `modules/Invoke-ADORepoSecrets.ps1` | AdoOrg |
| `alz-queries` | `Normalize-AlzQueries` | script | `modules/Invoke-AlzQueries.ps1` | SubscriptionId, ManagementGroupId |
| `appinsights` | `Normalize-AppInsights` | script | `modules/Invoke-AppInsights.ps1` | SubscriptionId |
| `azgovviz` | `Normalize-AzGovViz` | script | `modules/Invoke-AzGovViz.ps1` | ManagementGroupId |
| `azqr` | `Normalize-Azqr` | script | `modules/Invoke-Azqr.ps1` | SubscriptionId |
| `azure-cost` | `Normalize-AzureCost` | script | `modules/Invoke-AzureCost.ps1` | SubscriptionId |
| `bicep-iac` | `Normalize-IaCBicep` | script | `modules/Invoke-IaCBicep.ps1` | - |
| `copilot-triage` | `` | script | `modules/Invoke-CopilotTriage.ps1` | - |
| `defender-for-cloud` | `Normalize-DefenderForCloud` | script | `modules/Invoke-DefenderForCloud.ps1` | SubscriptionId |
| `falco` | `Normalize-Falco` | script | `modules/Invoke-Falco.ps1` | SubscriptionId |
| `finops` | `Normalize-FinOpsSignals` | script | `modules/Invoke-FinOpsSignals.ps1` | SubscriptionId |
| `gitleaks` | `Normalize-Gitleaks` | script | `modules/Invoke-Gitleaks.ps1` | - |
| `identity-correlator` | `Normalize-IdentityCorrelation` | function | `modules/shared/IdentityCorrelator.ps1` | TenantId |
| `identity-graph-expansion` | `Normalize-IdentityGraphExpansion` | function | `modules/Invoke-IdentityGraphExpansion.ps1` | TenantId |
| `infracost` | `Normalize-Infracost` | script | `modules/Invoke-Infracost.ps1` | - |
| `kube-bench` | `Normalize-KubeBench` | script | `modules/Invoke-KubeBench.ps1` | SubscriptionId |
| `kubescape` | `Normalize-Kubescape` | script | `modules/Invoke-Kubescape.ps1` | SubscriptionId |
| `loadtesting` | `Normalize-AzureLoadTesting` | script | `modules/Invoke-AzureLoadTesting.ps1` | SubscriptionId |
| `maester` | `Normalize-Maester` | script | `modules/Invoke-Maester.ps1` | - |
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
| `ado-pipeline-correlator` | none | n/a | `#00838f` | 2 |
| `ado-pipelines` | none | n/a | `#006064` | 2 |
| `ado-repos-secrets` | none | n/a | `#ad1457` | 2 |
| `alz-queries` | psmodule | Azure/Azure-Landing-Zones-Library @ HEAD | `#e65100` | 1 |
| `appinsights` | psmodule | n/a | `#00838f` | 4 |
| `azgovviz` | gitclone ("https://github.com/JulianHayward/Azure-MG-Sub-Governance-Reporting") | JulianHayward/Azure-MG-Sub-Governance-Reporting @ HEAD | `#00838f` | 1 |
| `azqr` | cli ("azqr") | Azure/azqr @ latest | `#1565c0` | 1 |
| `azure-cost` | psmodule | n/a | `#388e3c` | 4 |
| `bicep-iac` | cli ("bicep") | Azure/bicep @ latest | `#0d47a1` | 7 |
| `copilot-triage` | none | n/a | `#6a1b9a` | 8 |
| `defender-for-cloud` | psmodule | n/a | `#0078d4` | 4 |
| `falco` | psmodule | falcosecurity/falco @ 0.42.0 | `#ef6c00` | 6 |
| `finops` | psmodule | n/a | `#00897b` | 4 |
| `gitleaks` | cli ("gitleaks") | gitleaks/gitleaks @ latest | `#c62828` | 3 |
| `identity-correlator` | psmodule | n/a | `#5e35b1` | 2 |
| `identity-graph-expansion` | psmodule | n/a | `#283593` | 2 |
| `infracost` | cli ("infracost") | infracost/infracost @ latest | `#2e7d32` | 7 |
| `kube-bench` | none | n/a | `#5e35b1` | 6 |
| `kubescape` | cli ("kubescape") | kubescape/kubescape @ v3 | `#7b1fa2` | 6 |
| `loadtesting` | psmodule | n/a | `#00695c` | 4 |
| `maester` | psmodule | maester365/maester @ latest | `#7b1fa2` | 1 |
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

