# azure-analyzer

Unified Azure compliance assessment orchestrator. Bundles **8 assessment tools** into a single orchestrated run and produces unified Markdown and HTML reports.

## Overview

`Invoke-AzureAnalyzer.ps1` calls every assessment module in sequence, merges all findings into `output/results.json`, and generates reports. Tools that are not installed are skipped gracefully — you get output from whatever is available.

## What It Runs

| # | Tool / Module | Source | Checks |
|---|---|---|---|
| 1 | azqr | External CLI | Service-level best practices (~200 rules) |
| 2 | PSRule for Azure | External module | Azure WAF policy rules |
| 3 | AzGovViz | External script | Governance hierarchy visualization |
| 4 | ALZ Queries | [alz-graph-queries](https://github.com/martinopedal/alz-graph-queries) | 132+ ALZ checklist KQL queries |
| 5 | WARA | External module | Well-Architected Reliability Assessment |
| 6 | Cost Management API | Built-in (`modules/Invoke-CostManagementApi.ps1`) | Budget governance (4 checks) |
| 7 | Microsoft Graph API | Built-in (`modules/Invoke-GraphApi.ps1`) | Entra ID security posture (5 checks) |
| 8 | DevOps API | Built-in (`modules/Invoke-DevOpsApi.ps1`) | GitHub / ADO maturity (4 checks) |

## Hybrid Network Queries

`queries/hybrid_network_queries.json` contains 6 ARG queries for on-premises/hybrid connectivity health. They are **auto-loaded** by `modules/Invoke-AlzQueries.ps1` alongside the upstream ALZ queries.

| ID | Check | Severity |
|---|---|---|
| HN-001 | ExpressRoute circuit provisioning state (Enabled + Provisioned) | High |
| HN-002 | ExpressRoute circuit SKU (not Basic) | Medium |
| HN-003 | VPN gateway active-active configuration | Medium |
| HN-004 | VPN gateway SKU (not Basic) | Medium |
| HN-005 | VPN connection BGP enablement | Low |
| HN-006 | VPN connection status (Connected) | High |

Any `*.json` file added to `queries/` is automatically picked up — no code changes required.

## Usage

```powershell
.\Invoke-AzureAnalyzer.ps1 -SubscriptionId "00000000-0000-0000-0000-000000000000"
.\Invoke-AzureAnalyzer.ps1 -SubscriptionId "..." -ManagementGroupId "my-landing-zone"
.\Invoke-AzureAnalyzer.ps1 -SubscriptionId "..." -TenantId "..."
```

| Parameter | Description |
|---|---|
| `-SubscriptionId` | Azure subscription to assess (required unless `-ManagementGroupId` set) |
| `-ManagementGroupId` | Management group scope for AzGovViz and ALZ queries |
| `-TenantId` | Explicit tenant ID for WARA collector |
| `-OutputPath` | Output directory (default: `.\output`) |

## Prerequisites

| Requirement | Version | Notes |
|---|---|---|
| PowerShell | 7+ | `pwsh --version` |
| Azure CLI | latest | `az version` |
| Az PowerShell | latest | `Install-Module Az` |
| azqr | latest | `winget install azure-quick-review.azqr` |
| PSRule for Azure | latest | `Install-Module PSRule.Rules.Azure` |
| AzGovViz | latest | [Download](https://github.com/JulianHayward/Azure-MG-Sub-Governance-Reporting) to `tools/AzGovViz/` |
| WARA | latest | `Install-Module WARA` (auto-installed if missing) |

## Quick Start

```powershell
# 1. Clone
git clone https://github.com/martinopedal/azure-analyzer.git
cd azure-analyzer

# 2. Connect
Connect-AzAccount -TenantId "<your-tenant-id>"

# 3. Run
.\Invoke-AzureAnalyzer.ps1 -SubscriptionId "00000000-0000-0000-0000-000000000000"
```

Skip tools you don't have installed:

```powershell
.\Invoke-AzureAnalyzer.ps1 -SubscriptionId "..." -SkipAzGovViz -SkipPSRule
```

## Output

After a run, `output/` contains:

| File | Description |
|---|---|
| `results.json` | All findings in unified schema |
| `report.md` | Markdown report — summary table + Fix Now / Plan / Track sections |
| `report.html` | Offline HTML report — sortable table, severity badges, no CDN dependencies |

Unified schema for `results.json`:

```json
{
  "Id":          "azqr-001",
  "Source":      "azqr",
  "Category":    "Security",
  "Title":       "Storage account allows public blob access",
  "Severity":    "High",
  "Compliant":   false,
  "Detail":      "storageAccountName in rg-prod",
  "Remediation": "Set allowBlobPublicAccess = false"
}
```

### Report sections

- **Fix Now** — High + Critical severity findings
- **Plan** — Medium severity
- **Track** — Low + Info severity

## Report Generation

Generate reports from an existing `results.json` without re-running all tools:

```powershell
.\New-MdReport.ps1  -ResultsPath .\output\results.json -OutputPath .\output\report.md
.\New-HtmlReport.ps1 -ResultsPath .\output\results.json -OutputPath .\output\report.html
```

## Permissions

See [PERMISSIONS.md](./PERMISSIONS.md) for full role assignments. Summary:

| Tool / Module | Minimum permission |
|---|---|
| azqr, PSRule, ALZ Queries, WARA | `Reader` on subscriptions in scope |
| AzGovViz | `Reader` + `Directory.Read.All` at MG scope |
| Cost Management API | `Cost Management Reader` on subscription/MG |
| Microsoft Graph API | `Policy.Read.All`, `RoleManagement.Read.Directory` (admin consent) |
| DevOps API | `GITHUB_TOKEN` (`contents:read`, `administration:read`); ADO PAT optional |

No write permissions are required anywhere.

## CI / Automation

| Workflow | Trigger | What it does |
|---|---|---|
| `codeql.yml` | Push / PR / weekly | Static analysis (CodeQL v4, SHA-pinned) |
| `ci-failure-analysis.yml` | Any workflow failure | Auto-creates `bug`+`squad` issue with log excerpt |
| `squad-heartbeat.yml` | PR open/sync + schedule | Squad CI gate |

## License

MIT
