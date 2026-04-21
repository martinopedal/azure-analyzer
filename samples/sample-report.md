# Azure Analyzer - Posture Report

**Tenant:** `contoso-prod` &nbsp;|&nbsp; **Scanned:** 22 Apr 2026 07:52 UTC &nbsp;|&nbsp; **Run ID:** `launch-2026-04-22-0800`

![Critical](https://img.shields.io/badge/Critical-1-7f1d1d)
![High](https://img.shields.io/badge/High-4-b91c1c)
![Medium](https://img.shields.io/badge/Medium-5-b45309)
![Low](https://img.shields.io/badge/Low-0-a16207)
![Info](https://img.shields.io/badge/Info-0-475569)
![Posture](https://img.shields.io/badge/Posture-F%20%289%2F100%29-2563eb)
![Tools](https://img.shields.io/badge/Tools-36-0369a1)
![Run](https://img.shields.io/badge/Run-22%20Apr%202026%2007%3A52%20UTC-334155)

> Generated report. For full interactive exploration, open [sample-report.html](sample-report.html).

## Contents

1. [Executive summary](#executive-summary)
2. [Tool coverage](#tool-coverage)
3. [Heat map](#heat-map)
4. [Top 10 risks](#top-10-risks)
5. [Findings (top 30)](#findings-top-30)
6. [Entity inventory](#entity-inventory)
7. [Run details](#run-details)

## Executive summary

Tenant `contoso-prod` was scanned across 36 tools covering 3 entities in 2 scope(s). Compliance is 9%. Posture grade is **F (9/100)**.

1 critical, 4 high, 5 medium, 0 low, and 0 info findings are currently non-compliant.

### Pillar breakdown (non-compliant)

| Pillar | Findings |
| --- | ---: |
| Security | 5 |
| Cost Optimization | 4 |
| Performance Efficiency | 1 |

## Tool coverage

### Azure (subscription / management group / tenant)

| Tool | Scope | Findings | Pass % | Status |
| --- | --- | ---: | ---: | --- |
| azqr | subscription | 2 | 50% | OK |
| kubescape | subscription | 1 | 0% | OK |
| kube-bench | subscription | 0 | - | _skipped_ |
| defender-for-cloud | subscription | 0 | - | _skipped_ |
| prowler | subscription | 0 | - | _skipped_ |
| falco | subscription | 0 | - | _skipped_ |
| azure-cost | subscription | 0 | - | _skipped_ |
| azure-quota | subscription | 0 | - | _skipped_ |
| finops | subscription | 0 | - | _skipped_ |
| appinsights | subscription | 1 | 0% | OK |
| loadtesting | subscription | 0 | - | _skipped_ |
| aks-rightsizing | subscription | 1 | 0% | OK |
| aks-karpenter-cost | subscription | 0 | - | _skipped_ |
| psrule | subscription | 1 | 0% | OK |
| powerpipe | subscription | 0 | - | _skipped_ |
| azgovviz | managementGroup | 0 | - | _skipped_ |
| alz-queries | managementGroup | 0 | - | _skipped_ |
| wara | subscription | 0 | - | _skipped_ |
| sentinel-incidents | workspace | 0 | - | _skipped_ |
| sentinel-coverage | workspace | 1 | 0% | OK |

### Microsoft 365 / Graph

| Tool | Scope | Findings | Pass % | Status |
| --- | --- | ---: | ---: | --- |
| maester | tenant | 0 | - | _skipped_ |
| identity-correlator | tenant | 0 | - | _skipped_ |
| identity-graph-expansion | tenant | 0 | - | _skipped_ |

### GitHub

| Tool | Scope | Findings | Pass % | Status |
| --- | --- | ---: | ---: | --- |
| scorecard | repository | 0 | - | _skipped_ |
| gh-actions-billing | repository | 1 | 0% | OK |

### Azure DevOps

| Tool | Scope | Findings | Pass % | Status |
| --- | --- | ---: | ---: | --- |
| ado-connections | ado | 0 | - | _skipped_ |
| ado-pipelines | ado | 0 | - | _skipped_ |
| ado-consumption | ado | 1 | 0% | OK |
| ado-repos-secrets | ado | 0 | - | _skipped_ |
| ado-pipeline-correlator | ado | 1 | 0% | OK |

### Other

| Tool | Scope | Findings | Pass % | Status |
| --- | --- | ---: | ---: | --- |
| zizmor | repository | 0 | - | _skipped_ |
| gitleaks | repository | 0 | - | _skipped_ |
| trivy | repository | 0 | - | _skipped_ |
| bicep-iac | repository | 0 | - | _skipped_ |
| infracost | repository | 0 | - | _skipped_ |
| terraform-iac | repository | 0 | - | _skipped_ |
| copilot-triage | repository | 0 | - | _skipped_ |

## Heat map

Findings by control domain (rows) and subscription (columns). Cell glyph indicates the highest severity present and includes the finding count.

| Control domain | prod-identity | prod-payments | Total |
| --- | :---: | :---: | ---: |
| Cost Optimization | ⚪ 0 | 🟠 4 | 4 |
| Performance Efficiency | ⚪ 0 | 🟡 1 | 1 |
| Security | 🟡 1 | 🔴 4 | 5 |

Legend: 🔴 Critical, 🟠 High, 🟡 Medium, 🟢 Low, ⚪ Info

## Top 10 risks

| # | Severity | Rule | Domain | Tool | Findings |
| ---: | --- | --- | --- | --- | ---: |
| 1 | 🔴 Critical | Azure.KeyVault.SoftDelete | Security | psrule | 1 |
| 2 | 🟠 High | ADO.CORR.SECRET | Security | ado-pipeline-correlator | 1 |
| 3 | 🟠 High | AZQR.NET.012 | Security | azqr | 1 |
| 4 | 🟠 High | C-0057 | Security | kubescape | 1 |
| 5 | 🟠 High | Consumption-DurationRegression | Cost Optimization | ado-consumption | 1 |
| 6 | 🟡 Medium | AKS.RIGHT.001 | Cost Optimization | aks-rightsizing | 1 |
| 7 | 🟡 Medium | APPINSIGHTS.P95.REGRESSION | Performance Efficiency | appinsights | 1 |
| 8 | 🟡 Medium | FINOPS.APPSERVICE.IDLE | Cost Optimization | finops-signals | 1 |
| 9 | 🟡 Medium | GHA-BILLING-BUDGET | Cost Optimization | gh-actions-billing | 1 |
| 10 | 🟡 Medium | SENT-COV-T1190 | Security | sentinel-coverage | 1 |

## Findings (top 30)

Top 30 findings from this run. The [interactive HTML report](sample-report.html) renders the full set.

### Framework reference

| Framework | Badge text |
| --- | --- |
| CIS | [[CIS]] |
| MCSB | [[MCSB]] |
| MITRE ATT&CK | [[MITRE ATT&CK]] |
| NIST 800-53 | [[NIST 800-53]] |
| NSA | [[NSA]] |
| PCI DSS | [[PCI DSS]] |
| SOC2 | [[SOC2]] |
| WAF | [[WAF]] |

| # | Sev | Rule ID | Rule | Frameworks | Entity | Sub | Tool | Status |
| ---: | --- | --- | --- | --- | --- | --- | --- | --- |
| 1 | 🔴 | `Azure.KeyVault.SoftDelete` | Key Vault soft delete disabled | CIS · MCSB | `/subscriptions/11111111-1111-1111-1111-111111111111/resourcegroups/rg-payments-sec/providers/microsoft.keyvault/vaults/kv-payments-prod` | prod-payments | psrule | Open |
| 2 | 🟠 | `Consumption-DurationRegression` | Pipeline duration regression exceeds budget | - | `ado://contoso/payments/pipeline/55` | prod-payments | ado-consumption | Open |
| 3 | 🟠 | `AZQR.NET.012` | Internet-exposed management port on NSG | CIS · NIST 800-53 · PCI DSS | `/subscriptions/11111111-1111-1111-1111-111111111111/resourcegroups/rg-payments-net/providers/microsoft.network/networksecuritygroups/nsg-payments-edge` | prod-payments | azqr | Open |
| 4 | 🟠 | `C-0057` | Privileged container in payments namespace | CIS · NSA · MITRE ATT&CK | `/subscriptions/11111111-1111-1111-1111-111111111111/resourcegroups/rg-aks-prod/providers/microsoft.containerservice/managedclusters/aks-prod-payments` | prod-payments | kubescape | Open |
| 5 | 🟠 | `ADO.CORR.SECRET` | Secret-bearing commit executed in pipeline payments-ci [build:8201 secret:secret-9] | - | `ado://contoso/payments/pipeline/55` | prod-payments | ado-pipeline-correlator | Open |
| 6 | 🟡 | `AKS.RIGHT.001` | AKS node pool over-provisioned | WAF | `/subscriptions/11111111-1111-1111-1111-111111111111/resourcegroups/rg-aks-prod/providers/microsoft.containerservice/managedclusters/aks-prod-payments` | prod-payments | aks-rightsizing | Open |
| 7 | 🟡 | `FINOPS.APPSERVICE.IDLE` | Idle App Service Plan spend exceeds threshold | WAF | `/subscriptions/11111111-1111-1111-1111-111111111111/resourcegroups/rg-payments-app/providers/microsoft.web/serverfarms/asp-payments-prod` | prod-payments | finops-signals | Open |
| 8 | 🟡 | `GHA-BILLING-BUDGET` | Runner minute spend trend exceeds weekly budget | SOC2 | `github.com/contoso/payments-api` | prod-payments | gh-actions-billing | Open |
| 9 | 🟡 | `APPINSIGHTS.P95.REGRESSION` | API p95 latency regressed by 38% | WAF | `/subscriptions/11111111-1111-1111-1111-111111111111/resourcegroups/rg-payments-app/providers/microsoft.insights/components/payments-api-ai` | prod-payments | appinsights | Open |
| 10 | 🟡 | `SENT-COV-T1190` | MITRE tactic coverage gap for Initial Access | MITRE ATT&CK · NIST 800-53 | `/subscriptions/22222222-2222-2222-2222-222222222222/resourcegroups/rg-sec/providers/microsoft.operationalinsights/workspaces/law-sec-01` | prod-identity | sentinel-coverage | Open |

## Schema 2.2 spotlight

| # | Tool | Pillar | Impact | Effort | Frameworks | MITRE | Deep link |
| ---: | --- | --- | --- | --- | --- | --- | --- |
| 1 | PSRule for Azure | Security | High | Low | CIS · MCSB | - | [Open](https://portal.azure.com/#view/Microsoft_Azure_KeyVault/VaultMenuBlade/~/properties/resourceId/%2Fsubscriptions%2F11111111-1111-1111-1111-111111111111%2FresourceGroups%2Frg-payments-sec%2Fproviders%2FMicrosoft.KeyVault%2Fvaults%2Fkv-payments-prod) |
| 2 | Azure Quick Review | Security | High | Medium | CIS · NIST 800-53 · PCI DSS | - | [Open](https://portal.azure.com/#view/Microsoft_Azure_Network/NetworkSecurityGroupDetailsBlade/id/%2Fsubscriptions%2F11111111-1111-1111-1111-111111111111%2FresourceGroups%2Frg-payments-net%2Fproviders%2FMicrosoft.Network%2FnetworkSecurityGroups%2Fnsg-payments-edge) |
| 3 | ADO Pipeline Consumption | Cost Optimization | High | Medium | - | - | [Open](https://dev.azure.com/contoso/payments/_build?definitionId=55) |
| 4 | Kubescape (AKS runtime posture) | Security | High | Medium | CIS · NSA · MITRE ATT&CK | Privilege Escalation, T1611 | [Open](https://portal.azure.com/#view/HubsExtension/Resources/resourceType/Microsoft.ContainerService%2FmanagedClusters/resourceId/%2Fsubscriptions%2F11111111-1111-1111-1111-111111111111%2FresourceGroups%2Frg-aks-prod%2Fproviders%2FMicrosoft.ContainerService%2FmanagedClusters%2Faks-prod-payments) |
| 5 | ADO Pipeline Run Correlator | Security | High | Medium | - | - | [Open](https://dev.azure.com/contoso/payments/_build/results?buildId=8201&view=results) |
| 6 | AKS Rightsizing (Container Insights utilization) | Cost Optimization | Medium | Medium | WAF | - | [Open](https://portal.azure.com/#view/Microsoft_Azure_ContainerService/ManagedClusterNodePoolsMenuBlade/id/%2Fsubscriptions%2F11111111-1111-1111-1111-111111111111%2FresourceGroups%2Frg-aks-prod%2Fproviders%2FMicrosoft.ContainerService%2FmanagedClusters%2Faks-prod-payments) |
| 7 | Application Insights Performance Signals | Performance Efficiency | Medium | Medium | WAF | - | [Open](https://portal.azure.com/#view/AppInsightsExtension/BladeRedirect/BladeName/searchV1/ComponentId/%2Fsubscriptions%2F11111111-1111-1111-1111-111111111111%2FresourceGroups%2Frg-payments-app%2Fproviders%2Fmicrosoft.insights%2Fcomponents%2Fpayments-api-ai) |
| 8 | finops-signals | Cost Optimization | Medium | Low | WAF | - | [Open](https://portal.azure.com/#view/Microsoft_Azure_CostManagement/Menu/~/costanalysis) |
| 9 | Microsoft Sentinel (Coverage / Posture) | Security | Medium | Medium | MITRE ATT&CK · NIST 800-53 | Initial Access, T1190 | [Open](https://portal.azure.com/#view/Microsoft_Azure_Security_Insights/MainMenuBlade/~/analytics/resourceId/%2Fsubscriptions%2F22222222-2222-2222-2222-222222222222%2FresourceGroups%2Frg-sec%2Fproviders%2FMicrosoft.OperationalInsights%2Fworkspaces%2Flaw-sec-01) |
| 10 | GitHub Actions Billing | Cost Optimization | Medium | Low | SOC2 | - | [Open](https://docs.github.com/en/billing/managing-billing-for-your-products/managing-billing-for-github-actions) |

### Evidence and remediation snippets

<details><summary>Key Vault soft delete disabled</summary>

- **Baseline tags:** "release:ga", "keyvault"
- **Entity refs:** `/subscriptions/11111111-1111-1111-1111-111111111111`, `kv:kv-payments-prod`
- **Evidence URIs:**
  - [https://learn.microsoft.com/azure/key-vault/general/soft-delete-overview](https://learn.microsoft.com/azure/key-vault/general/soft-delete-overview)
- **Remediation snippets:**
  ```bicep
resource kv 'Microsoft.KeyVault/vaults@2023-07-01' existing = { name: 'kv-payments-prod' }
resource kvPatch 'Microsoft.KeyVault/vaults@2023-07-01' = {
  name: kv.name
  properties: {
    enableSoftDelete: true
    enablePurgeProtection: true
  }
}
  ```

</details>

<details><summary>Internet-exposed management port on NSG</summary>

- **Baseline tags:** "release:ga", "internet-exposed"
- **Entity refs:** `/subscriptions/11111111-1111-1111-1111-111111111111`, `nsg:nsg-payments-edge`
- **Evidence URIs:**
  - [https://portal.azure.com/#resource/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-payments-net/providers/Microsoft.Network/networkSecurityGroups/nsg-payments-edge](https://portal.azure.com/#resource/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-payments-net/providers/Microsoft.Network/networkSecurityGroups/nsg-payments-edge)
  - [https://learn.microsoft.com/azure/virtual-network/network-security-groups-overview](https://learn.microsoft.com/azure/virtual-network/network-security-groups-overview)
- **Remediation snippets:**
  ```azurecli
az network nsg rule update --resource-group rg-payments-net --nsg-name nsg-payments-edge --name Allow-RDP --source-address-prefixes 10.0.0.0/24
  ```

</details>

<details><summary>Pipeline duration regression exceeds budget</summary>

- **Baseline tags:** "duration-regression", "minutes"
- **Entity refs:** `pipeline:ado://contoso/payments/pipeline/55`, `project:ado://contoso/payments/project/payments`
- **Evidence URIs:**
  - [https://dev.azure.com/contoso/payments/_analytics](https://dev.azure.com/contoso/payments/_analytics)
  - [https://learn.microsoft.com/azure/devops/pipelines/process/phases](https://learn.microsoft.com/azure/devops/pipelines/process/phases)

</details>

<details><summary>Privileged container in payments namespace</summary>

- **Baseline tags:** "nsa", "cis", "mitreattck"
- **Entity refs:** `cluster:aks-prod-payments`, `namespace:payments`, `workload:payments-api`
- **Evidence URIs:**
  - [https://hub.armosec.io/docs/c-0057](https://hub.armosec.io/docs/c-0057)
  - [https://attack.mitre.org/techniques/T1611/](https://attack.mitre.org/techniques/T1611/)
- **Remediation snippets:**
  ```yaml
securityContext:
  privileged: false
  allowPrivilegeEscalation: false
  ```

</details>

<details><summary>Secret-bearing commit executed in pipeline payments-ci [build:8201 secret:secret-9]</summary>

- **Baseline tags:** "correlated-direct", "secret-category:github-pat"
- **Entity refs:** `finding:secret-9`, `pipeline:ado://contoso/payments/pipeline/55`, `build:8201`, `repository:ado://contoso/payments/repository/payments-api`, `commit:abcdef1234567890`
- **Evidence URIs:**
  - [https://dev.azure.com/contoso/payments/_build/results?buildId=8201](https://dev.azure.com/contoso/payments/_build/results?buildId=8201)
  - [https://dev.azure.com/contoso/payments/_build/results?buildId=8201&view=logs](https://dev.azure.com/contoso/payments/_build/results?buildId=8201&view=logs)
  - [https://dev.azure.com/contoso/payments/_git/payments-api/commit/abcdef1234567890](https://dev.azure.com/contoso/payments/_git/payments-api/commit/abcdef1234567890)
- **Remediation snippets:**
  ```text
1) Rotate leaked credentials.
2) Inspect pipeline variable groups and service connections.
3) Verify artifact consumers and deployment logs.
  ```

</details>

<details><summary>AKS node pool over-provisioned</summary>

- **Baseline tags:** "rightsizing", "cluster-autoscaler"
- **Entity refs:** `cluster:aks-prod-payments`, `nodepool:usernp`
- **Evidence URIs:**
  - [https://portal.azure.com/#blade/HubsExtension/Resources/resourceType/Microsoft.ContainerService%2FmanagedClusters](https://portal.azure.com/#blade/HubsExtension/Resources/resourceType/Microsoft.ContainerService%2FmanagedClusters)
  - [https://learn.microsoft.com/azure/aks/cluster-autoscaler](https://learn.microsoft.com/azure/aks/cluster-autoscaler)
- **Remediation snippets:**
  ```bash
az aks nodepool update -g rg-aks-prod --cluster-name aks-prod-payments -n usernp --min-count 3 --max-count 10
  ```

</details>

<details><summary>API p95 latency regressed by 38%</summary>

- **Baseline tags:** "release:canary", "latency-regression"
- **Entity refs:** `appinsights:payments-api-ai`, `service:checkout`
- **Evidence URIs:**
  - [https://portal.azure.com/#blade/AppInsightsExtension/BladeRedirect/BladeName/FailuresV2](https://portal.azure.com/#blade/AppInsightsExtension/BladeRedirect/BladeName/FailuresV2)
  - [https://learn.microsoft.com/azure/azure-monitor/app/app-map](https://learn.microsoft.com/azure/azure-monitor/app/app-map)
- **Remediation snippets:**
  ```kusto
requests
| where cloud_RoleName == "payments-api"
| summarize p95=percentile(duration,95) by bin(timestamp, 1h)
  ```

</details>

<details><summary>Idle App Service Plan spend exceeds threshold</summary>

- **Baseline tags:** "cost-hotspot", "release:ga"
- **Entity refs:** `plan:asp-payments-prod`, `subscription:11111111-1111-1111-1111-111111111111`
- **Evidence URIs:**
  - [https://portal.azure.com/#blade/Microsoft_Azure_CostManagement/Menu/overview](https://portal.azure.com/#blade/Microsoft_Azure_CostManagement/Menu/overview)
  - [https://learn.microsoft.com/azure/app-service/overview-hosting-plans](https://learn.microsoft.com/azure/app-service/overview-hosting-plans)
- **Remediation snippets:**
  ```text
Downsize to P1v3 and set autoscale max instances to 2.
  ```

</details>

<details><summary>MITRE tactic coverage gap for Initial Access</summary>

- **Baseline tags:** "correlation-gap", "mitre"
- **Entity refs:** `workspace:law-sec-01`, `mitre:TA0001`, `mitre:T1190`
- **Evidence URIs:**
  - [https://portal.azure.com/#blade/Microsoft_Azure_Security_Insights/WorkspaceMenuBlade/AnalyticsRules/resourceId/%2Fsubscriptions%2F22222222-2222-2222-2222-222222222222%2FresourceGroups%2Frg-sec%2Fproviders%2FMicrosoft.OperationalInsights%2Fworkspaces%2Flaw-sec-01](https://portal.azure.com/#blade/Microsoft_Azure_Security_Insights/WorkspaceMenuBlade/AnalyticsRules/resourceId/%2Fsubscriptions%2F22222222-2222-2222-2222-222222222222%2FresourceGroups%2Frg-sec%2Fproviders%2FMicrosoft.OperationalInsights%2Fworkspaces%2Flaw-sec-01)
  - [https://attack.mitre.org/tactics/TA0001/](https://attack.mitre.org/tactics/TA0001/)

</details>

<details><summary>Runner minute spend trend exceeds weekly budget</summary>

- **Baseline tags:** "runner-minutes", "budget"
- **Entity refs:** `repo:github.com/contoso/payments-api`, `workflow:.github/workflows/ci.yml`
- **Evidence URIs:**
  - [https://github.com/contoso/payments-api/actions](https://github.com/contoso/payments-api/actions)
  - [https://github.com/contoso/payments-api/settings/actions](https://github.com/contoso/payments-api/settings/actions)

</details>

## Entity inventory

3 entities discovered across all scopes.

| Entity type | Count |
| --- | ---: |
| AzureResource | 1 |
| Pipeline | 1 |
| Repository | 1 |

## Run details

<details>
<summary>Tool versions</summary>

| Tool | Version | Provider |
| --- | --- | --- |
| azqr | 2.7.0 | azure |
| kubescape | kubescape version v3.1.1 | azure |
| kube-bench | - | azure |
| defender-for-cloud | - | azure |
| prowler | - | azure |
| falco | - | azure |
| azure-cost | - | azure |
| azure-quota | - | azure |
| finops | - | azure |
| appinsights | appinsights-api-2024-03-11 | azure |
| loadtesting | - | azure |
| aks-rightsizing | aks-rightsizing/0.5.0 | azure |
| aks-karpenter-cost | - | azure |
| psrule | 1.40.0 | azure |
| powerpipe | - | azure |
| azgovviz | - | azure |
| alz-queries | - | azure |
| wara | - | azure |
| maester | - | microsoft365 |
| scorecard | - | github |
| gh-actions-billing | gh-actions-billing-api-2024-10-01 | github |
| ado-connections | - | ado |
| ado-pipelines | - | ado |
| ado-consumption | azure-devops/1.0.1 | ado |
| ado-repos-secrets | - | ado |
| ado-pipeline-correlator | azure-devops/1.0.1 | ado |
| identity-correlator | - | graph |
| identity-graph-expansion | - | graph |
| zizmor | - | cli |
| gitleaks | - | cli |
| trivy | - | cli |
| bicep-iac | - | cli |
| infracost | - | cli |
| terraform-iac | - | cli |
| sentinel-incidents | - | azure |
| sentinel-coverage | securityinsights-2024-09-01+loganalytics-2020-08-01 | azure |
| copilot-triage | - | cli |

</details>

Generated by **azure-analyzer**. Schema fields are consumed defensively and optional Schema 2.2 fields render when present.