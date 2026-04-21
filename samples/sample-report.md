# Azure Analyzer - Posture Report

**Tenant:** `contoso-prod` &nbsp;|&nbsp; **Scanned:** 22 Apr 2026 09:14 UTC &nbsp;|&nbsp; **Run ID:** `aa-20260422-091413`

![Critical](https://img.shields.io/badge/Critical-7-7f1d1d)
![High](https://img.shields.io/badge/High-34-b91c1c)
![Medium](https://img.shields.io/badge/Medium-81-b45309)
![Low](https://img.shields.io/badge/Low-62-a16207)
![Info](https://img.shields.io/badge/Info-38-475569)
![Posture](https://img.shields.io/badge/Posture-B%20(78%2F100)-2563eb)
![Compliance](https://img.shields.io/badge/Compliance-81%25-16a34a)

> Sample report for documentation purposes. Numbers are illustrative; the matching [interactive HTML report](sample-report.html) renders the same scan with sortable findings, a heat map, a coverage grid, and dark mode.

## Contents

1. [Executive summary](#executive-summary)
2. [Tool coverage](#tool-coverage)
3. [Heat map](#heat-map)
4. [Top 10 risks](#top-10-risks)
5. [Findings (top 30)](#findings-top-30)
6. [Entity inventory](#entity-inventory)
7. [Run details](#run-details)

## Executive summary

Tenant `contoso-prod` was scanned across 17 tools covering 412 entities in 3 subscriptions (`prod-payments`, `prod-identity`, `dev-shared`). 81% of evaluated controls passed, up 2.3 points versus the previous run on 8 Apr. Posture grade is **B (78/100)**.

Seven Critical issues require attention this week, mostly clustered in `prod-identity` (5 of 7). Two new high-severity workflow-injection findings landed in `contoso/payments-api` from the latest `zizmor` sweep. Net delta from the previous run: Critical down 2, High down 5, Medium up 6, Low flat, Info up 1.

**Top recommendations**

1. Enable PIM activation for the 4 standing Owner role assignments in `prod-identity` (Critical, identity).
2. Resolve the 2 hard-coded secrets in `contoso/payments-api` flagged by `gitleaks` (Critical, secrets).
3. Pin the 8 unpinned third-party actions in `contoso/payments-api` and `contoso/identity-edge` (High, supply chain).
4. Right-size the 3 over-provisioned AKS node pools in `prod-payments` (Medium, cost; ~ $1.4k/mo).
5. Enable Defender for Containers on the remaining 2 AKS clusters in `dev-shared` (High, runtime).

## Tool coverage

17 active tools across 6 providers. One tool (`copilot-triage`) is registered but disabled in this scan.

### Azure (subscription / management group / tenant)

| Tool | Scope | Findings | Pass % | Status |
| --- | --- | ---: | ---: | --- |
| azqr | subscription | 38 | 79% | OK |
| psrule | subscription | 47 | 74% | OK |
| defender-for-cloud | subscription | 22 | 81% | OK |
| azgovviz | tenant | 11 | 90% | OK |
| alz-queries | managementGroup | 18 | 86% | OK |
| wara | subscription | 9 | 88% | OK |
| azure-cost | subscription | 6 | 92% | OK |
| finops | subscription | 4 | 95% | OK |
| aks-rightsize | subscription | 7 | 84% | OK |

### Microsoft 365 / Graph

| Tool | Scope | Findings | Pass % | Status |
| --- | --- | ---: | ---: | --- |
| maester | tenant | 14 | 82% | OK |
| identity-correlator | tenant | 8 | 89% | OK |

### GitHub

| Tool | Scope | Findings | Pass % | Status |
| --- | --- | ---: | ---: | --- |
| scorecard | repository | 9 | 78% | OK |
| gh-actions-billing | repository | 3 | 96% | OK |
| gitleaks | repository | 4 | 91% | OK |
| trivy | repository | 11 | 80% | OK |
| zizmor | repository | 6 | 85% | OK |

### Azure DevOps

| Tool | Scope | Findings | Pass % | Status |
| --- | --- | ---: | ---: | --- |
| ado-pipelines | ado | 5 | 89% | OK |

## Heat map

Findings by control domain (rows) and subscription (columns). Cell glyph indicates the highest severity present; the number is the finding count for that intersection.

| Control domain | prod-payments | prod-identity | dev-shared | Total |
| --- | :---: | :---: | :---: | ---: |
| Identity & access | 🟡 12 | 🔴 28 | 🟢 4 | 44 |
| Network security | 🟠 14 | 🟡 9 | 🟡 7 | 30 |
| Data protection | 🟠 11 | 🟠 8 | 🟢 3 | 22 |
| Logging & monitoring | 🟡 9 | 🟡 6 | 🟡 5 | 20 |
| Cost & efficiency | 🟡 7 | 🟢 2 | 🟡 6 | 15 |
| Supply chain (CI/CD) | 🟠 18 | 🟠 9 | 🟡 4 | 31 |
| Secrets hygiene | 🔴 3 | 🟠 2 | ⚪ 1 | 6 |
| Workload runtime | 🟠 13 | 🟡 7 | 🟡 4 | 24 |
| Resilience & DR | 🟡 10 | 🟢 4 | 🟢 2 | 16 |
| Governance | 🟡 6 | 🟡 5 | 🟢 3 | 14 |

Legend: 🔴 Critical &nbsp; 🟠 High &nbsp; 🟡 Medium &nbsp; 🟢 Low &nbsp; ⚪ Info

## Top 10 risks

| # | Severity | Rule | Domain | Tool | Findings |
| ---: | --- | --- | --- | --- | ---: |
| 1 | 🔴 Critical | Owner role assigned without PIM | Identity & access | psrule | 4 |
| 2 | 🔴 Critical | Hard-coded secret in source | Secrets hygiene | gitleaks | 2 |
| 3 | 🔴 Critical | Storage account public network access enabled | Data protection | azqr | 1 |
| 4 | 🟠 High | Workflow-injection in pull_request_target handler | Supply chain (CI/CD) | zizmor | 2 |
| 5 | 🟠 High | Unpinned third-party GitHub Action | Supply chain (CI/CD) | scorecard | 8 |
| 6 | 🟠 High | Defender for Containers not enabled | Workload runtime | defender-for-cloud | 2 |
| 7 | 🟠 High | NSG allows 0.0.0.0/0 on management ports | Network security | azqr | 5 |
| 8 | 🟠 High | Key Vault soft-delete disabled | Data protection | psrule | 3 |
| 9 | 🟠 High | Guest user in privileged role group | Identity & access | maester | 4 |
| 10 | 🟠 High | Container image with critical CVE in deployed digest | Workload runtime | trivy | 6 |

## Findings (top 30)

Top 30 of 222 findings, sorted by severity then domain. The [interactive HTML report](sample-report.html) renders the full set with search, severity pills, tool/subscription filters, sortable columns, and click-to-expand evidence and remediation.

### How to read a row

Each finding carries a tool-native rule ID and a colored badge for every compliance framework it satisfies, so an auditor can scan for the framework they care about without reading every row:

![CIS](https://img.shields.io/badge/CIS-amber?color=d97706)
![NIST](https://img.shields.io/badge/NIST-slate?color=374151)
![MITRE](https://img.shields.io/badge/MITRE-red?color=b91c1c)
![EIDSCA](https://img.shields.io/badge/EIDSCA-blue?color=1f6feb)
![eIDAS2](https://img.shields.io/badge/eIDAS2-violet?color=7c3aed)
![SOC 2](https://img.shields.io/badge/SOC%202-teal?color=0e7490)
![ISO 27001](https://img.shields.io/badge/ISO%2027001-teal?color=0f766e)
![MCSB](https://img.shields.io/badge/MCSB-azure-color=005a9e)
![CAF](https://img.shields.io/badge/CAF-navy?color=1e3a8a)
![WAF](https://img.shields.io/badge/WAF-green?color=3a7d0a)

The rule-ID column below uses each tool's native identifier (`AZQR.NET.001`, `EIDSCA.AF01`, `OSSF.001`, etc.) so you can paste it directly into the upstream tool's docs.

| # | Sev | Rule ID | Rule | Frameworks | Entity | Sub | Tool | Status |
| ---: | --- | --- | --- | --- | --- | --- | --- | --- |
| 1 | 🔴 | `EIDSCA.AF01` | Legacy authentication not blocked tenant-wide | CIS · MCSB | `tenant/contoso` | (tenant) | maester | Open |
| 2 | 🔴 | `MCSB.IM-1` | Owner role assigned without PIM | CIS · MCSB | `user/alice@contoso.com` | prod-identity | psrule | Open |
| 3 | 🔴 | `MCSB.IM-1` | Owner role assigned without PIM | CIS · MCSB | `sp/payments-deploy` | prod-identity | psrule | Open |
| 4 | 🔴 | `MCSB.IM-1` | Owner role assigned without PIM | CIS · MCSB | `user/bob@contoso.com` | prod-identity | psrule | Open |
| 5 | 🔴 | `GLK.AWS-001` | Hard-coded AWS key in repo | CIS · SOC 2 | `repo/contoso/payments-api` | prod-payments | gitleaks | Open |
| 6 | 🔴 | `GLK.AZ-002` | Hard-coded SAS token in repo | CIS · SOC 2 | `repo/contoso/payments-api` | prod-payments | gitleaks | Open |
| 7 | 🔴 | `AZQR.STG.001` | Storage account public network access enabled | CAF · WAF · MCSB | `sa/contosoprodlogs01` | prod-payments | azqr | Open |
| 8 | 🟠 | `ZZM.PR-INJ` | Workflow-injection in pull_request_target handler | SOC 2 | `wf/contoso/payments-api/.github/workflows/pr-bot.yml` | prod-payments | zizmor | Open |
| 9 | 🟠 | `ZZM.PR-INJ` | Workflow-injection in pull_request_target handler | SOC 2 | `wf/contoso/identity-edge/.github/workflows/triage.yml` | prod-identity | zizmor | Open |
| 10 | 🟠 | `OSSF.PIN` | Unpinned third-party GitHub Action | SOC 2 | `wf/contoso/payments-api/.github/workflows/release.yml` | prod-payments | scorecard | Open |
| 11 | 🟠 | `OSSF.PIN` | Unpinned third-party GitHub Action | SOC 2 | `wf/contoso/payments-api/.github/workflows/build.yml` | prod-payments | scorecard | Open |
| 12 | 🟠 | `OSSF.PIN` | Unpinned third-party GitHub Action | SOC 2 | `wf/contoso/identity-edge/.github/workflows/build.yml` | prod-identity | scorecard | Open |
| 13 | 🟠 | `MCSB.PV-1` | Defender for Containers not enabled | MCSB · NIST 800-53 | `aks/dev-aks-east` | dev-shared | defender-for-cloud | Open |
| 14 | 🟠 | `MCSB.PV-1` | Defender for Containers not enabled | MCSB · NIST 800-53 | `aks/dev-aks-west` | dev-shared | defender-for-cloud | Open |
| 15 | 🟠 | `AZQR.NET.012` | NSG allows 0.0.0.0/0 on RDP (3389) | CIS · MCSB | `nsg/rg-payments-api/edge-nsg` | prod-payments | azqr | Open |
| 16 | 🟠 | `AZQR.NET.012` | NSG allows 0.0.0.0/0 on SSH (22) | CIS · MCSB | `nsg/rg-payments-data/jump-nsg` | prod-payments | azqr | Open |
| 17 | 🟠 | `AZQR.NET.012` | NSG allows 0.0.0.0/0 on RDP (3389) | CIS · MCSB | `nsg/rg-identity-core/dc-nsg` | prod-identity | azqr | Open |
| 18 | 🟠 | `Azure.KV.SoftDelete` | Key Vault soft-delete disabled | CIS · MCSB | `kv/kv-payments-prod` | prod-payments | psrule | Open |
| 19 | 🟠 | `Azure.KV.SoftDelete` | Key Vault soft-delete disabled | CIS · MCSB | `kv/kv-identity-core` | prod-identity | psrule | Open |
| 20 | 🟠 | `EIDSCA.PRA01` | Guest user in Privileged Role Administrators | CIS · EIDSCA · MITRE.T1078 | `user/contractor1@partner.com` | (tenant) | maester | Open |
| 21 | 🟠 | `TRV.CVE` | Container image with critical CVE | MCSB · NIST 800-53 | `acr/contosoprod/payments-api:1.42.0` | prod-payments | trivy | Open |
| 22 | 🟠 | `TRV.CVE` | Container image with critical CVE | MCSB · NIST 800-53 | `acr/contosoprod/identity-edge:2.7.1` | prod-identity | trivy | Open |
| 23 | 🟠 | `AZQR.APP.005` | App Service TLS minimum below 1.2 | CIS · MCSB | `app/payments-api-prod` | prod-payments | azqr | Open |
| 24 | 🟠 | `AZQR.SQL.003` | SQL DB no transparent data encryption | CIS · ISO 27001 · SOC 2 | `sqldb/identity-store` | prod-identity | azqr | Open |
| 25 | 🟡 | `AZQR.KV.LOG` | Diagnostic settings missing on Key Vault | MCSB · CIS | `kv/kv-payments-prod` | prod-payments | azqr | Open |
| 26 | 🟡 | `AKS.RIGHT.001` | AKS node pool over-provisioned (CPU < 12%) | WAF | `aks/prod-aks-payments/sysnp` | prod-payments | aks-rightsize | Open |
| 27 | 🟡 | `AKS.RIGHT.001` | AKS node pool over-provisioned (CPU < 18%) | WAF | `aks/prod-aks-payments/usernp` | prod-payments | aks-rightsize | Open |
| 28 | 🟡 | `Azure.Storage.SharedKey` | Storage account allows shared key access | CIS · MCSB | `sa/contosoprodassets` | prod-payments | psrule | Open |
| 29 | 🟡 | `COST.AI.SAMPLE` | App Insights sampling above target | WAF | `ai/payments-api-ai` | prod-payments | azure-cost | Open |
| 30 | 🟡 | `ADO.PAR.001` | Pipeline parallel-job ratio above budget | SOC 2 | `ado/contoso-eng/payments-ci` | (ado) | ado-pipelines | Open |

## Entity inventory

412 entities discovered across all scopes.

| Entity type | Count |
| --- | ---: |
| AzureResource | 246 |
| Subscription | 3 |
| Tenant | 1 |
| User | 58 |
| ServicePrincipal | 31 |
| Repository | 14 |
| Workflow | 39 |
| AdoProject | 4 |
| Other | 16 |

<details>
<summary>Identity blast-radius highlights</summary>

- 3 guest accounts hold Owner on at least one production resource group.
- 4 service principals have standing Owner without PIM activation.
- 2 user accounts in `prod-identity` have not signed in for 90+ days but retain Contributor.

The HTML report renders these as an interactive blast-radius graph.

</details>

## Run details

<details>
<summary>Tool versions</summary>

| Tool | Version | Provider |
| --- | --- | --- |
| azqr | 2.6.1 | azure |
| psrule | 1.39.4 | azure |
| defender-for-cloud | api 2024-08-01 | azure |
| azgovviz | 6.5.7 | azure |
| alz-queries | 2026.04 | azure |
| wara | 1.4.0 | azure |
| azure-cost | api 2024-09-01 | azure |
| finops | 0.6.2 | azure |
| aks-rightsize | 0.4.1 | azure |
| maester | 1.1.0 | microsoft365 |
| identity-correlator | 0.3.0 | graph |
| scorecard | 4.13.1 | github |
| gh-actions-billing | api 2024-10-01 | github |
| gitleaks | 8.18.4 | github |
| trivy | 0.50.1 | github |
| zizmor | 0.6.0 | github |
| ado-pipelines | api 7.1 | ado |

</details>

Generated by **azure-analyzer** v3.0 (mockup) · Schema 2.2 · Report v3. See the [interactive HTML version](sample-report.html), the [tool catalog](../docs/consumer/tool-catalog.md), and [PERMISSIONS.md](../PERMISSIONS.md).
