# Azure Analyzer - Posture Report

**Tenant:** `contoso-prod` &nbsp;|&nbsp; **Scanned:** 22 Apr 2026 07:52 UTC &nbsp;|&nbsp; **Run ID:** `launch-2026-04-22-0800`

![Critical](https://img.shields.io/badge/Critical-3-7f1d1d)
![High](https://img.shields.io/badge/High-11-b91c1c)
![Medium](https://img.shields.io/badge/Medium-8-b45309)
![Low](https://img.shields.io/badge/Low-1-a16207)
![Info](https://img.shields.io/badge/Info-0-475569)
![Posture](https://img.shields.io/badge/Posture-F%20%280%2F100%29-2563eb)
![Tools](https://img.shields.io/badge/Tools-37-0369a1)
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

Tenant `contoso-prod` was scanned across 37 tools covering 3 entities in 2 scope(s). Compliance is 0%. Posture grade is **F (0/100)**.

3 critical, 11 high, 8 medium, 1 low, and 0 info findings are currently non-compliant.

### Pillar breakdown (non-compliant)

| Pillar | Findings |
| --- | ---: |
| Identity | 7 |
| Supply Chain | 4 |
| Reliability | 3 |
| CI/CD Security | 2 |
| Governance | 2 |
| Networking | 2 |
| Security | 2 |
| Secret Detection | 1 |

## Tool coverage

### Azure (subscription / management group / tenant)

| Tool | Scope | Findings | Pass % | Status |
| --- | --- | ---: | ---: | --- |
| aks-karpenter-cost | subscription | 0 | - | _skipped_ |
| aks-rightsizing | subscription | 0 | - | OK |
| alz-queries | managementGroup | 2 | 0% | OK |
| appinsights | subscription | 0 | - | OK |
| azgovviz | managementGroup | 2 | 0% | OK |
| azqr | subscription | 2 | 0% | OK |
| azure-cost | subscription | 0 | - | _skipped_ |
| azure-quota | subscription | 0 | - | _skipped_ |
| defender-for-cloud | subscription | 0 | - | _skipped_ |
| falco | subscription | 0 | - | _skipped_ |
| finops | subscription | 0 | - | _skipped_ |
| kube-bench | subscription | 0 | - | _skipped_ |
| kubescape | subscription | 0 | - | OK |
| loadtesting | subscription | 0 | - | _skipped_ |
| powerpipe | subscription | 0 | - | _skipped_ |
| prowler | subscription | 0 | - | _skipped_ |
| psrule | subscription | 2 | 0% | OK |
| sentinel-coverage | workspace | 0 | - | OK |
| sentinel-incidents | workspace | 0 | - | _skipped_ |
| wara | subscription | 2 | 0% | OK |

### Microsoft 365 / Graph

| Tool | Scope | Findings | Pass % | Status |
| --- | --- | ---: | ---: | --- |
| identity-correlator | tenant | 2 | 0% | OK |
| identity-graph-expansion | tenant | 0 | - | _skipped_ |
| maester | tenant | 2 | 0% | OK |

### GitHub

| Tool | Scope | Findings | Pass % | Status |
| --- | --- | ---: | ---: | --- |
| gh-actions-billing | repository | 0 | - | OK |
| scorecard | repository | 2 | 0% | OK |

### Azure DevOps

| Tool | Scope | Findings | Pass % | Status |
| --- | --- | ---: | ---: | --- |
| ado-connections | ado | 2 | 0% | OK |
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
| trivy | repository | 2 | 0% | OK |
| zizmor | repository | 2 | 0% | OK |

## Heat map

Findings by control domain (rows) and subscription (columns). Cell glyph indicates the highest severity present and includes the finding count.

| Control domain | (tenant) | 00000000-1111-2222-3333-444444444444 | Total |
| --- | :---: | :---: | ---: |
| CI/CD Security | 🔴 2 | ⚪ 0 | 2 |
| Governance | 🟡 1 | 🟢 1 | 2 |
| Identity | 🔴 6 | 🟠 1 | 7 |
| Networking | ⚪ 0 | 🟠 2 | 2 |
| Reliability | ⚪ 0 | 🟠 3 | 3 |
| Secret Detection | 🟠 1 | ⚪ 0 | 1 |
| Security | ⚪ 0 | 🟠 2 | 2 |
| Supply Chain | 🔴 4 | ⚪ 0 | 4 |

Legend: 🔴 Critical, 🟠 High, 🟡 Medium, 🟢 Low, ⚪ Info

## Top 10 risks

| # | Severity | Rule | Domain | Tool | Findings |
| ---: | --- | --- | --- | --- | ---: |
| 1 | 🔴 Critical | CVE-2024-24790 (golang.org/x/net) | Supply Chain | trivy | 1 |
| 2 | 🔴 Critical | MT.1010 | Identity | maester | 1 |
| 3 | 🔴 Critical | template-injection | CI/CD Security | zizmor | 1 |
| 4 | 🟠 High | AWS access key found in commit history | Secret Detection | gitleaks | 1 |
| 5 | 🟠 High | Azure.Storage.SecureTransfer | Security | psrule | 1 |
| 6 | 🟠 High | Branch-Protection score 3/10 | Supply Chain | scorecard | 1 |
| 7 | 🟠 High | Classic (password-based) service connection in use | Identity | ado-connections | 1 |
| 8 | 🟠 High | EIDSCA.AG01 | Identity | maester | 1 |
| 9 | 🟠 High | Key Vault soft delete is disabled | Security | azqr | 1 |
| 10 | 🟠 High | NSG allows SSH from any source | Networking | azqr | 1 |

## Findings (top 30)

Top 30 findings from this run. The [interactive HTML report](sample-report.html) renders the full set.

| # | Sev | Rule ID | Rule | Frameworks | Entity | Sub | Tool | Status |
| ---: | --- | --- | --- | --- | --- | --- | --- | --- |
| 1 | 🔴 | `template-injection` | template-injection: Workflow uses ${{ github.event.issue.title }} in run step | - | `.github/workflows/triage.yml` | (tenant) | zizmor | Open |
| 2 | 🔴 | `MT.1010` | MT.1010: Breakglass accounts without MFA | - | `tenant:11111111-2222-3333-4444-555555555555` | (tenant) | maester | Open |
| 3 | 🔴 | `CVE-2024-24790 (golang.org/x/net)` | CVE-2024-24790 (golang.org/x/net) | - | `go.mod` | (tenant) | trivy | Open |
| 4 | 🟠 | `Classic (password-based) service connection in use` | Classic (password-based) service connection in use | - | `ado://contoso/Platform/serviceEndpoint/prod-deploy` | (tenant) | ado-connections | Open |
| 5 | 🟠 | `EIDSCA.AG01` | EIDSCA.AG01: Security defaults disabled, no Conditional Access | - | `tenant:11111111-2222-3333-4444-555555555555` | (tenant) | maester | Open |
| 6 | 🟠 | `Owner role assigned to non-PIM eligible user` | Owner role assigned to non-PIM eligible user | - | `/subscriptions/00000000-1111-2222-3333-444444444444` | 00000000-1111-2222-3333-444444444444 | azgovviz | Open |
| 7 | 🟠 | `Service principal with Owner role is also an ADO service connection` | Service principal with Owner role is also an ADO service connection | - | `appId:aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee` | (tenant) | identity-correlator | Open |
| 8 | 🟠 | `NSG allows SSH from any source` | NSG allows SSH from any source | - | `/subscriptions/00000000-1111-2222-3333-444444444444/resourceGroups/rg-prod-net/providers/Microsoft.Network/networkSecurityGroups/nsg-frontend` | 00000000-1111-2222-3333-444444444444 | azqr | Open |
| 9 | 🟠 | `Public IP without NSG association` | Public IP without NSG association | - | `/subscriptions/00000000-1111-2222-3333-444444444444/resourceGroups/rg-prod-net/providers/Microsoft.Network/publicIPAddresses/pip-prod-lb` | 00000000-1111-2222-3333-444444444444 | alz-queries | Open |
| 10 | 🟠 | `SQL Database has no active geo-replication` | SQL Database has no active geo-replication | - | `/subscriptions/00000000-1111-2222-3333-444444444444/resourceGroups/rg-prod-data/providers/Microsoft.Sql/servers/sql-prod/databases/sqldb-prod-orders` | 00000000-1111-2222-3333-444444444444 | wara | Open |
| 11 | 🟠 | `AWS access key found in commit history` | AWS access key found in commit history | - | `scripts/legacy-migrate.sh` | (tenant) | gitleaks | Open |
| 12 | 🟠 | `Azure.Storage.SecureTransfer` | Azure.Storage.SecureTransfer: Storage account requires HTTPS | - | `/subscriptions/00000000-1111-2222-3333-444444444444/resourceGroups/rg-prod-data/providers/Microsoft.Storage/storageAccounts/stprodlogs` | 00000000-1111-2222-3333-444444444444 | psrule | Open |
| 13 | 🟠 | `Key Vault soft delete is disabled` | Key Vault soft delete is disabled | - | `/subscriptions/00000000-1111-2222-3333-444444444444/resourceGroups/rg-prod-sec/providers/Microsoft.KeyVault/vaults/kv-prod-secrets` | 00000000-1111-2222-3333-444444444444 | azqr | Open |
| 14 | 🟠 | `Branch-Protection score 3/10` | Branch-Protection score 3/10 | - | `github.com/contoso/azure-landing-zone` | (tenant) | scorecard | Open |
| 15 | 🟡 | `unpinned-uses` | unpinned-uses: action pinned by tag, not SHA | - | `.github/workflows/release.yml` | (tenant) | zizmor | Open |
| 16 | 🟡 | `Built-in policy 'Audit VMs without Azure Monitor agent' not assigned` | Built-in policy 'Audit VMs without Azure Monitor agent' not assigned | - | `/providers/Microsoft.Management/managementGroups/contoso-root` | (tenant) | azgovviz | Open |
| 17 | 🟡 | `Orphaned service principal with active role assignment` | Orphaned service principal with active role assignment | - | `appId:ffffffff-0000-1111-2222-333333333333` | (tenant) | identity-correlator | Open |
| 18 | 🟡 | `Service connection grants Contributor at subscription scope` | Service connection grants Contributor at subscription scope | - | `ado://contoso/Platform/serviceEndpoint/prod-deploy` | (tenant) | ado-connections | Open |
| 19 | 🟡 | `AKS cluster has no SLA tier enabled` | AKS cluster has no SLA tier enabled | - | `/subscriptions/00000000-1111-2222-3333-444444444444/resourceGroups/rg-prod-aks/providers/Microsoft.ContainerService/managedClusters/aks-prod-apps` | 00000000-1111-2222-3333-444444444444 | wara | Open |
| 20 | 🟡 | `Azure.VM.AvailabilityZone` | Azure.VM.AvailabilityZone: VM not deployed to availability zone | - | `/subscriptions/00000000-1111-2222-3333-444444444444/resourceGroups/rg-prod-web/providers/Microsoft.Compute/virtualMachines/vm-prod-web-01` | 00000000-1111-2222-3333-444444444444 | psrule | Open |
| 21 | 🟡 | `CVE-2024-28849 (follow-redirects)` | CVE-2024-28849 (follow-redirects) | - | `package-lock.json` | (tenant) | trivy | Open |
| 22 | 🟡 | `Pinned-Dependencies score 5/10` | Pinned-Dependencies score 5/10 | - | `github.com/contoso/azure-landing-zone` | (tenant) | scorecard | Open |
| 23 | 🟢 | `Resource missing required tag 'owner'` | Resource missing required tag 'owner' | - | `/subscriptions/00000000-1111-2222-3333-444444444444` | 00000000-1111-2222-3333-444444444444 | alz-queries | Open |

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