# Azure Analyzer - Posture Report

**Tenant:** `contoso-prod` &nbsp;|&nbsp; **Scanned:** 22 Apr 2026 07:52 UTC &nbsp;|&nbsp; **Run ID:** `launch-2026-04-22-0800`

![Critical](https://img.shields.io/badge/Critical-3-7f1d1d)
![High](https://img.shields.io/badge/High-2-b91c1c)
![Medium](https://img.shields.io/badge/Medium-0-b45309)
![Low](https://img.shields.io/badge/Low-0-a16207)
![Info](https://img.shields.io/badge/Info-0-475569)
![Posture](https://img.shields.io/badge/Posture-F%20%280%2F100%29-2563eb)
![Tools](https://img.shields.io/badge/Tools-36-0369a1)
![Run](https://img.shields.io/badge/Run-22%20Apr%202026%2007%3A52%20UTC-334155)

> Generated report. For full interactive exploration, open [sample-report-v2-mockup.html](sample-report-v2-mockup.html).

## Contents

1. [Executive summary](#executive-summary)
2. [Tool coverage](#tool-coverage)
3. [Heat map](#heat-map)
4. [Top 10 risks](#top-10-risks)
5. [Findings (top 30)](#findings-top-30)
6. [Entity inventory](#entity-inventory)
7. [Run details](#run-details)

## Executive summary

Tenant `contoso-prod` was scanned across 36 tools covering 3 entities in 2 scope(s). Compliance is 0%. Posture grade is **F (0/100)**.

3 critical, 2 high, 0 medium, 0 low, and 0 info findings are currently non-compliant.

### Pillar breakdown (non-compliant)

| Pillar | Findings |
| --- | ---: |
| EntraID | 1 |
| Identity | 1 |
| Secrets | 1 |
| Security | 1 |
| Vulnerabilities | 1 |

## Tool coverage

### Azure (subscription / management group / tenant)

| Tool | Scope | Findings | Pass % | Status |
| --- | --- | ---: | ---: | --- |
| aks-karpenter-cost | subscription | 0 | - | _skipped_ |
| aks-rightsizing | subscription | 0 | - | OK |
| alz-queries | managementGroup | 0 | - | _skipped_ |
| appinsights | subscription | 0 | - | OK |
| azgovviz | managementGroup | 0 | - | _skipped_ |
| azqr | subscription | 1 | 0% | OK |
| azure-cost | subscription | 0 | - | _skipped_ |
| azure-quota | subscription | 0 | - | _skipped_ |
| defender-for-cloud | subscription | 0 | - | _skipped_ |
| falco | subscription | 0 | - | _skipped_ |
| finops | subscription | 0 | - | _skipped_ |
| kube-bench | subscription | 0 | - | _skipped_ |
| kubescape | subscription | 0 | - | OK |
| loadtesting | subscription | 0 | - | _skipped_ |
| powerpipe | subscription | 0 | - | _skipped_ |
| prowler | subscription | 1 | 0% | OK |
| psrule | subscription | 0 | - | OK |
| sentinel-coverage | workspace | 0 | - | OK |
| sentinel-incidents | workspace | 0 | - | _skipped_ |
| wara | subscription | 0 | - | _skipped_ |

### Microsoft 365 / Graph

| Tool | Scope | Findings | Pass % | Status |
| --- | --- | ---: | ---: | --- |
| identity-correlator | tenant | 0 | - | _skipped_ |
| identity-graph-expansion | tenant | 0 | - | _skipped_ |
| maester | tenant | 1 | 0% | OK |

### GitHub

| Tool | Scope | Findings | Pass % | Status |
| --- | --- | ---: | ---: | --- |
| gh-actions-billing | repository | 0 | - | OK |
| scorecard | repository | 0 | - | _skipped_ |

### Azure DevOps

| Tool | Scope | Findings | Pass % | Status |
| --- | --- | ---: | ---: | --- |
| ado-connections | ado | 0 | - | _skipped_ |
| ado-consumption | ado | 0 | - | OK |
| ado-pipeline-correlator | ado | 0 | - | OK |
| ado-pipelines | ado | 0 | - | _skipped_ |
| ado-repos-secrets | ado | 0 | - | _skipped_ |

### Other

| Tool | Scope | Findings | Pass % | Status |
| --- | --- | ---: | ---: | --- |
| bicep-iac | repository | 0 | - | _skipped_ |
| copilot-triage | repository | 0 | - | _skipped_ |
| gitleaks | repository | 1 | 0% | OK |
| infracost | repository | 0 | - | _skipped_ |
| terraform-iac | repository | 0 | - | _skipped_ |
| trivy | repository | 1 | 0% | OK |
| zizmor | repository | 0 | - | _skipped_ |

## Heat map

Findings by control domain (rows) and subscription (columns). Cell glyph indicates the highest severity present and includes the finding count.

| Control domain | (tenant) | 00000000-0000-0000-0000-000000000001 | Total |
| --- | :---: | :---: | ---: |
| EntraID | 🟠 1 | ⚪ 0 | 1 |
| Identity | ⚪ 0 | 🔴 1 | 1 |
| Secrets | 🔴 1 | ⚪ 0 | 1 |
| Security | ⚪ 0 | 🟠 1 | 1 |
| Vulnerabilities | ⚪ 0 | 🔴 1 | 1 |

Legend: 🔴 Critical, 🟠 High, 🟡 Medium, 🟢 Low, ⚪ Info

## Top 10 risks

| # | Severity | Rule | Domain | Tool | Findings |
| ---: | --- | --- | --- | --- | ---: |
| 1 | 🔴 Critical | gitleaks-gh-001 | Secrets | gitleaks | 1 |
| 2 | 🔴 Critical | prowler-iam-001 | Identity | prowler | 1 |
| 3 | 🔴 Critical | trivy-vuln-001 | Vulnerabilities | trivy | 1 |
| 4 | 🟠 High | azqr-net-001 | Security | azqr | 1 |
| 5 | 🟠 High | maester-entra-001 | EntraID | maester | 1 |

## Findings (top 30)

Top 30 findings from this run. The [interactive HTML report](sample-report-v2-mockup.html) renders the full set.

| # | Sev | Rule ID | Rule | Frameworks | Entity | Sub | Tool | Status |
| ---: | --- | --- | --- | --- | --- | --- | --- | --- |
| 1 | 🔴 | `prowler-iam-001` | Service Principal has excessive permissions | - | `/subscriptions/00000000-0000-0000-0000-000000000001` | 00000000-0000-0000-0000-000000000001 | prowler | Open |
| 2 | 🔴 | `gitleaks-gh-001` | AWS Access Key hardcoded in repository | - | `https://github.com/example/payments-api/blob/main/scripts/deploy.sh#L42` | (tenant) | gitleaks | Open |
| 3 | 🔴 | `trivy-vuln-001` | Container image has critical vulnerabilities | - | `/subscriptions/00000000-0000-0000-0000-000000000001/resourcegroups/rg-prod-aks/providers/microsoft.containerservice/managedclusters/aks-prod-01` | 00000000-0000-0000-0000-000000000001 | trivy | Open |
| 4 | 🟠 | `maester-entra-001` | Privileged role assignment without MFA | - | `tenant:00000000-0000-0000-0000-000000000000` | (tenant) | maester | Open |
| 5 | 🟠 | `azqr-net-001` | Internet-exposed management port on NSG | - | `/subscriptions/00000000-0000-0000-0000-000000000001/resourcegroups/rg-prod-net/providers/microsoft.network/networksecuritygroups/nsg-frontend` | 00000000-0000-0000-0000-000000000001 | azqr | Open |

## Schema 2.2 spotlight

| # | Tool | Pillar | Impact | Effort | Frameworks | MITRE | Deep link |
| ---: | --- | --- | --- | --- | --- | --- | --- |
| 1 | gitleaks (Secrets Scanner) |  |  |  | - | - | - |
| 2 | Trivy Vulnerability Scanner |  |  |  | - | - | - |
| 3 | Prowler (Azure security posture) |  |  |  | - | - | - |
| 4 | Azure Quick Review | Security | High | Medium | - | - | - |
| 5 | Maester |  |  |  | - | - | - |

### Evidence and remediation snippets

<details><summary>AWS Access Key hardcoded in repository</summary>


</details>

<details><summary>Container image has critical vulnerabilities</summary>


</details>

<details><summary>Service Principal has excessive permissions</summary>


</details>

<details><summary>Internet-exposed management port on NSG</summary>


</details>

<details><summary>Privileged role assignment without MFA</summary>


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
| ado-connections | - | ado |
| ado-consumption | - | ado |
| ado-pipeline-correlator | azure-devops/1.0.1 | ado |
| ado-pipelines | - | ado |
| ado-repos-secrets | - | ado |
| aks-karpenter-cost | - | azure |
| aks-rightsizing | - | azure |
| alz-queries | - | azure |
| appinsights | - | azure |
| azgovviz | - | azure |
| azqr | 2.7.0 | azure |
| azure-cost | - | azure |
| azure-quota | - | azure |
| bicep-iac | - | cli |
| copilot-triage | - | cli |
| defender-for-cloud | - | azure |
| falco | - | azure |
| finops | - | azure |
| gh-actions-billing | - | github |
| gitleaks | - | cli |
| identity-correlator | - | graph |
| identity-graph-expansion | - | graph |
| infracost | - | cli |
| kube-bench | - | azure |
| kubescape | v3.1.1 | azure |
| loadtesting | - | azure |
| maester | - | microsoft365 |
| powerpipe | - | azure |
| prowler | - | azure |
| psrule | 1.40.0 | azure |
| scorecard | - | github |
| sentinel-coverage | 2024-09-01 | azure |
| sentinel-incidents | - | azure |
| terraform-iac | - | cli |
| trivy | - | cli |
| wara | - | azure |
| zizmor | - | cli |

</details>

Generated by **azure-analyzer**. Schema fields are consumed defensively and optional Schema 2.2 fields render when present.