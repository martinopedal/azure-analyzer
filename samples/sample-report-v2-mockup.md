# Azure Analyzer - Posture Report v2

**Tenant:** `contoso-prod` &nbsp;|&nbsp; **Scanned:** 22 Apr 2026 07:52 UTC &nbsp;|&nbsp; **Run ID:** `launch-2026-04-22-0800`  
**Posture:** F (9/100) ▲ **+3 regression from last scan**

![Critical](https://img.shields.io/badge/Critical-1-7f1d1d)
![High](https://img.shields.io/badge/High-4-b91c1c)
![Medium](https://img.shields.io/badge/Medium-5-b45309)
![Low](https://img.shields.io/badge/Low-0-a16207)
![Info](https://img.shields.io/badge/Info-0-475569)
![Tools](https://img.shields.io/badge/Tools-36-0369a1)

> Generated Markdown report (Schema 2.2). For full interactive exploration with MITRE ATT&CK matrix heatmap and dark mode, open [sample-report.html](sample-report.html).

## Contents

1. [Executive summary](#executive-summary)
2. [MITRE ATT&CK coverage](#mitre-attck-coverage)
3. [Impact × Effort matrix](#impact--effort-matrix)
4. [Tool coverage](#tool-coverage)
5. [Heat map](#heat-map)
6. [Top 10 risks](#top-10-risks)
7. [Findings (top 30)](#findings-top-30)
8. [Framework cross-reference](#framework-cross-reference)
9. [Entity inventory](#entity-inventory)
10. [Run details](#run-details)

## Executive summary

Tenant `contoso-prod` was scanned across 36 tools covering 3 entities in 2 scope(s). Compliance is 9%. Posture grade is **F (9/100)**.

1 critical, 4 high, 5 medium, 0 low, and 0 info findings are currently non-compliant.

### Pillar breakdown (non-compliant)

| Pillar | Findings | Trend |
| --- | ---: | :---: |
| Security | 5 | ▲ +1 |
| Cost Optimization | 4 | ▬ 0 |
| Performance Efficiency | 1 | ▼ -2 |

**Legend:** ▲ increased, ▬ stable, ▼ decreased (vs last scan)

## MITRE ATT&CK coverage

Schema 2.2 surfaces MITRE tactics and techniques from tools that map to ATT&CK (Kubescape, Maester, Sentinel). This report includes 2 findings with ATT&CK mappings.

### Coverage summary

| Tactic | Technique count | Sample techniques |
| --- | ---: | --- |
| Initial Access | 1 | T1190 (Exploit Public-Facing Application) |
| Privilege Escalation | 1 | T1611 (Escape to Host) |

**Note:** Tactics not listed have zero technique coverage. Enable Kubescape for Kubernetes workload threats, Maester for identity threats, and Sentinel for SIEM correlation gaps.

### Technique detail

| Technique | Name | Findings | Severity |
| --- | --- | ---: | --- |
| T1190 | Exploit Public-Facing Application | 1 | 🟡 Medium |
| T1611 | Escape to Host | 1 | 🟠 High |

## Impact × Effort matrix

Finding prioritization by remediation impact (business risk reduction) and effort (implementation cost).

|  | **High Effort** | **Medium Effort** | **Low Effort** |
| ---: | :---: | :---: | :---: |
| **High Impact** | 0 | 3 | 1 |
| **Medium Impact** | 0 | 3 | 1 |
| **Low Impact** | 0 | 0 | 0 |

**Quick wins** (High Impact × Low Effort): 1 finding  
**Strategic** (High Impact × Medium/High Effort): 3 findings  
**Optimization** (Medium Impact × Low Effort): 1 finding

## Tool coverage

### Azure (subscription / management group / tenant)

| Tool | Scope | Findings | Pass % | Status | Version |
| --- | --- | ---: | ---: | --- | --- |
| azqr | subscription | 2 | 50% | OK | 2.7.0 |
| kubescape | subscription | 1 | 0% | OK | v3.1.1 |
| kube-bench | subscription | 0 | - | _skipped_ | - |
| defender-for-cloud | subscription | 0 | - | _skipped_ | - |
| prowler | subscription | 0 | - | _skipped_ | - |
| falco | subscription | 0 | - | _skipped_ | - |
| azure-cost | subscription | 0 | - | _skipped_ | - |
| azure-quota | subscription | 0 | - | _skipped_ | - |
| finops | subscription | 0 | - | _skipped_ | - |
| appinsights | subscription | 1 | 0% | OK | appinsights-api-2024-03-11 |
| loadtesting | subscription | 0 | - | _skipped_ | - |
| aks-rightsizing | subscription | 1 | 0% | OK | aks-rightsizing/0.5.0 |
| aks-karpenter-cost | subscription | 0 | - | _skipped_ | - |
| psrule | subscription | 1 | 0% | OK | 1.40.0 |
| powerpipe | subscription | 0 | - | _skipped_ | - |
| azgovviz | managementGroup | 0 | - | _skipped_ | - |
| alz-queries | managementGroup | 0 | - | _skipped_ | - |
| wara | subscription | 0 | - | _skipped_ | - |
| sentinel-incidents | workspace | 0 | - | _skipped_ | - |
| sentinel-coverage | workspace | 1 | 0% | OK | securityinsights-2024-09-01+loganalytics-2020-08-01 |

### Microsoft 365 / Graph

| Tool | Scope | Findings | Pass % | Status | Version |
| --- | --- | ---: | ---: | --- | --- |
| maester | tenant | 0 | - | _skipped_ | - |
| identity-correlator | tenant | 0 | - | _skipped_ | - |
| identity-graph-expansion | tenant | 0 | - | _skipped_ | - |

### GitHub

| Tool | Scope | Findings | Pass % | Status | Version |
| --- | --- | ---: | ---: | --- | --- |
| scorecard | repository | 0 | - | _skipped_ | - |
| gh-actions-billing | repository | 1 | 0% | OK | gh-actions-billing-api-2024-10-01 |

### Azure DevOps

| Tool | Scope | Findings | Pass % | Status | Version |
| --- | --- | ---: | ---: | --- | --- |
| ado-connections | ado | 0 | - | _skipped_ | - |
| ado-pipelines | ado | 0 | - | _skipped_ | - |
| ado-consumption | ado | 1 | 0% | OK | azure-devops/1.0.1 |
| ado-repos-secrets | ado | 0 | - | _skipped_ | - |
| ado-pipeline-correlator | ado | 1 | 0% | OK | azure-devops/1.0.1 |

### Other

| Tool | Scope | Findings | Pass % | Status | Version |
| --- | --- | ---: | ---: | --- | --- |
| zizmor | repository | 0 | - | _skipped_ | - |
| gitleaks | repository | 0 | - | _skipped_ | - |
| trivy | repository | 0 | - | _skipped_ | - |
| bicep-iac | repository | 0 | - | _skipped_ | - |
| infracost | repository | 0 | - | _skipped_ | - |
| terraform-iac | repository | 0 | - | _skipped_ | - |
| copilot-triage | repository | 0 | - | _skipped_ | - |

## Heat map

Findings by control domain (rows) and subscription (columns). Cell glyph indicates the highest severity present and includes the finding count.

| Control domain | prod-identity | prod-payments | Total |
| --- | :---: | :---: | ---: |
| Cost Optimization | ⚪ 0 | 🟠 4 | 4 |
| Performance Efficiency | ⚪ 0 | 🟡 1 | 1 |
| Security | 🟡 1 | 🔴 4 | 5 |

**Legend:** 🔴 Critical, 🟠 High, 🟡 Medium, 🟢 Low, ⚪ Info

**Note:** Interactive HTML report offers 3 heatmap views: Control domain × Subscription (default), Tool × Severity, Framework × Subscription.

## Top 10 risks

Aggregated by rule, ranked by impact score (severity weight × entity count × impact factor).

| # | Sev | Rule | Domain | Frameworks | Tool | Findings | Impact | Effort |
| ---: | --- | --- | --- | --- | --- | ---: | --- | --- |
| 1 | 🔴 | `Azure.KeyVault.SoftDelete` | Security | [[CIS]] [[MCSB]] | psrule | 1 | High | Low |
| 2 | 🟠 | `ADO.CORR.SECRET` | Security | - | ado-pipeline-correlator | 1 | High | Medium |
| 3 | 🟠 | `AZQR.NET.012` | Security | [[CIS]] [[NIST 800-53]] [[PCI DSS]] | azqr | 1 | High | Medium |
| 4 | 🟠 | `C-0057` | Security | [[CIS]] [[NSA]] [[MITRE ATT&CK]] | kubescape | 1 | High | Medium |
| 5 | 🟠 | `Consumption-DurationRegression` | Cost Optimization | - | ado-consumption | 1 | High | Medium |
| 6 | 🟡 | `AKS.RIGHT.001` | Cost Optimization | [[WAF]] | aks-rightsizing | 1 | Medium | Medium |
| 7 | 🟡 | `APPINSIGHTS.P95.REGRESSION` | Performance Efficiency | [[WAF]] | appinsights | 1 | Medium | Medium |
| 8 | 🟡 | `FINOPS.APPSERVICE.IDLE` | Cost Optimization | [[WAF]] | finops-signals | 1 | Medium | Low |
| 9 | 🟡 | `GHA-BILLING-BUDGET` | Cost Optimization | [[SOC2]] | gh-actions-billing | 1 | Medium | Low |
| 10 | 🟡 | `SENT-COV-T1190` | Security | [[MITRE ATT&CK]] [[NIST 800-53]] | sentinel-coverage | 1 | Medium | Medium |

## Findings (top 30)

Top 30 findings from this run. The [interactive HTML report](sample-report.html) renders the full set with collapsible evidence, remediation snippets, entity refs, and deep links.

### 1. Key Vault soft delete disabled

- **Rule ID:** `Azure.KeyVault.SoftDelete`
- **Severity:** 🔴 Critical
- **Pillar:** Security
- **Frameworks:** [[CIS]] [[MCSB]]
- **Tool:** PSRule for Azure (1.40.0)
- **Entity:** `/subscriptions/11111111-1111-1111-1111-111111111111/resourcegroups/rg-payments-sec/providers/microsoft.keyvault/vaults/kv-payments-prod`
- **Subscription:** prod-payments
- **Status:** Fail
- **Impact:** High | **Effort:** Low

<details>
<summary>Evidence and remediation</summary>

**Description:** Key Vault kv-payments-prod has soft delete disabled and purge protection off.

**Baseline tags:** `release:ga`, `keyvault`

**Entity refs:**
- `/subscriptions/11111111-1111-1111-1111-111111111111`
- `kv:kv-payments-prod`

**Evidence URIs:**
- [Key Vault soft delete overview](https://learn.microsoft.com/azure/key-vault/general/soft-delete-overview)

**Remediation:** Enable soft delete and purge protection on production Key Vaults.

**Remediation snippet (Bicep):**
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

**Deep link:** [Open in Azure Portal](https://learn.microsoft.com/azure/key-vault/general/overview)

</details>

---

### 2. Internet-exposed management port on NSG

- **Rule ID:** `AZQR.NET.012`
- **Severity:** 🟠 High
- **Pillar:** Security
- **Frameworks:** [[CIS]] [[NIST 800-53]] [[PCI DSS]]
- **Tool:** Azure Quick Review (2.7.0)
- **Entity:** `/subscriptions/11111111-1111-1111-1111-111111111111/resourcegroups/rg-payments-net/providers/microsoft.network/networksecuritygroups/nsg-payments-edge`
- **Subscription:** prod-payments
- **Status:** Fail
- **Impact:** High | **Effort:** Medium

<details>
<summary>Evidence and remediation</summary>

**Description:** NSG nsg-payments-edge allows RDP (3389) from 0.0.0.0/0.

**Baseline tags:** `release:ga`, `internet-exposed`

**Entity refs:**
- `/subscriptions/11111111-1111-1111-1111-111111111111`
- `nsg:nsg-payments-edge`

**Evidence URIs:**
- [Network security groups overview](https://learn.microsoft.com/azure/virtual-network/network-security-groups-overview)

**Remediation:** Restrict inbound access to JIT or approved source ranges.

**Remediation snippet (Azure CLI):**
```bash
az network nsg rule update --resource-group rg-payments-net --nsg-name nsg-payments-edge --name Allow-RDP --source-address-prefixes 10.0.0.0/24
```

**Deep link:** [Open in Azure Portal](https://learn.microsoft.com/azure/virtual-network/network-security-groups-overview)

</details>

---

### 3. Pipeline duration regression exceeds budget

- **Rule ID:** `Consumption-DurationRegression`
- **Severity:** 🟠 High
- **Pillar:** Cost Optimization
- **Tool:** ADO Pipeline Consumption (azure-devops/1.0.1)
- **Entity:** `ado://contoso/payments/pipeline/55`
- **Subscription:** prod-payments
- **Status:** Fail
- **Impact:** High | **Effort:** Medium

<details>
<summary>Evidence and remediation</summary>

**Description:** Pipeline payments-ci average duration increased from 8m to 14m in the last 7 days.

**Baseline tags:** `duration-regression`, `minutes`

**Entity refs:**
- `pipeline:ado://contoso/payments/pipeline/55`
- `project:ado://contoso/payments/project/payments`

**Evidence URIs:**
- [Azure DevOps pipeline analytics](https://dev.azure.com/contoso/payments/_analytics)
- [Pipeline best practices](https://learn.microsoft.com/azure/devops/pipelines/process/phases)

**Remediation:** Profile slow steps, parallelize test jobs, cache dependencies.

</details>

---

### 4. Privileged container in payments namespace

- **Rule ID:** `C-0057`
- **Severity:** 🟠 High
- **Pillar:** Security
- **Frameworks:** [[CIS]] [[NSA]] [[MITRE ATT&CK]]
- **MITRE Tactics:** Privilege Escalation
- **MITRE Techniques:** T1611 (Escape to Host)
- **Tool:** Kubescape (v3.1.1)
- **Entity:** `/subscriptions/11111111-1111-1111-1111-111111111111/resourcegroups/rg-aks-prod/providers/microsoft.containerservice/managedclusters/aks-prod-payments`
- **Subscription:** prod-payments
- **Status:** Fail
- **Impact:** High | **Effort:** Medium

<details>
<summary>Evidence and remediation</summary>

**Description:** Deployment payments-api uses privileged=true in one container.

**Baseline tags:** `nsa`, `cis`, `mitreattck`

**Entity refs:**
- `cluster:aks-prod-payments`
- `namespace:payments`
- `workload:payments-api`

**Evidence URIs:**
- [Kubescape control C-0057](https://hub.armosec.io/docs/c-0057)
- [MITRE ATT&CK T1611](https://attack.mitre.org/techniques/T1611/)

**Remediation:** Drop privileged mode and enforce Pod Security Standards.

**Remediation snippet (Kubernetes YAML):**
```yaml
securityContext:
  privileged: false
  allowPrivilegeEscalation: false
```

**Deep link:** [Open in Azure Portal](https://learn.microsoft.com/azure/aks/operator-best-practices-cluster-security)

</details>

---

### 5. Secret-bearing commit executed in pipeline

- **Rule ID:** `ADO.CORR.SECRET`
- **Severity:** 🟠 High
- **Pillar:** Security
- **Tool:** ADO Pipeline Run Correlator (azure-devops/1.0.1)
- **Entity:** `ado://contoso/payments/pipeline/55`
- **Subscription:** prod-payments
- **Status:** Fail
- **Impact:** High | **Effort:** Medium

<details>
<summary>Evidence and remediation</summary>

**Description:** Secret finding secret-9 commit abcdef1234567890 correlated to build 8201 in payments-ci.

**Baseline tags:** `correlated-direct`, `secret-category:github-pat`

**Entity refs:**
- `finding:secret-9`
- `pipeline:ado://contoso/payments/pipeline/55`
- `build:8201`
- `repository:ado://contoso/payments/repository/payments-api`
- `commit:abcdef1234567890`

**Evidence URIs:**
- [Build 8201 results](https://dev.azure.com/contoso/payments/_build/results?buildId=8201)
- [Build 8201 logs](https://dev.azure.com/contoso/payments/_build/results?buildId=8201&view=logs)
- [Commit details](https://dev.azure.com/contoso/payments/_git/payments-api/commit/abcdef1234567890)

**Remediation:** Rotate affected secret, audit variable groups, and inspect downstream artifacts.

**Remediation steps:**
```text
1) Rotate leaked credentials.
2) Inspect pipeline variable groups and service connections.
3) Verify artifact consumers and deployment logs.
```

**Deep link:** [Open build in ADO](https://dev.azure.com/contoso/payments/_build/results?buildId=8201&view=results)

</details>

---

_(Findings 6-10 omitted for brevity — see full report in [sample-report.html](sample-report.html))_

## Framework cross-reference

Schema 2.2 findings may map to multiple compliance frameworks. This legend clarifies abbreviations.

| Framework | Full name | Publisher |
| --- | --- | --- |
| [[CIS]] | CIS Azure Foundations Benchmark v2.0.0 | Center for Internet Security |
| [[MCSB]] | Microsoft Cloud Security Benchmark v1.0 | Microsoft |
| [[MITRE ATT&CK]] | MITRE ATT&CK for Cloud v14 | MITRE Corporation |
| [[NIST 800-53]] | NIST SP 800-53 Rev. 5 | NIST |
| [[NSA]] | NSA/CISA Kubernetes Hardening Guidance | NSA, CISA |
| [[PCI DSS]] | Payment Card Industry Data Security Standard v4.0 | PCI Security Standards Council |
| [[SOC2]] | SOC 2 Type II (Trust Services Criteria) | AICPA |
| [[WAF]] | Azure Well-Architected Framework | Microsoft |

## Entity inventory

3 entities discovered across all scopes.

| Entity type | Count |
| --- | ---: |
| AzureResource | 1 |
| Pipeline | 1 |
| Repository | 1 |

## Run details

<details>
<summary>Tool versions (37 tools registered)</summary>

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

---

**Generated by azure-analyzer.** Schema fields are consumed defensively and optional Schema 2.2 fields render when present.
