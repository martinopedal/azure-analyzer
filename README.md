# azure-analyzer

Automated Azure assessment that bundles **azqr**, **PSRule for Azure**, **AzGovViz**, and the **ALZ Resource Graph queries** from [alz-graph-queries](https://github.com/martinopedal/alz-graph-queries) into a single orchestrated run with unified Markdown and HTML reports.

## What it does

| Phase | Script | What it runs |
|---|---|---|
| 1 — azqr | `modules/Invoke-Azqr.ps1` | Azure Quick Review CLI — compliance posture per resource type |
| 2 — PSRule | `modules/Invoke-PSRule.ps1` | PSRule for Azure — rule-based policy validation |
| 3 — AzGovViz | `modules/Invoke-AzGovViz.ps1` | Azure Governance Visualizer — tenant/MG/subscription hierarchy |
| 4 — ALZ queries | `modules/Invoke-AlzQueries.ps1` | 132 custom ARG queries from alz-graph-queries |
| Report | `New-MdReport.ps1` / `New-HtmlReport.ps1` | Unified Markdown + offline HTML report |

All findings are merged into `output/results.json` using a common schema:

```json
{ "source": "azqr", "category": "Security", "severity": "High", "title": "...", "description": "...", "resourceId": "..." }
```

## Prerequisites

| Requirement | Version | Notes |
|---|---|---|
| PowerShell | 7+ | `pwsh --version` |
| Azure CLI | latest | `az version` |
| Az PowerShell | latest | `Install-Module Az` |
| azqr | latest | `winget install azure-quick-review.azqr` |
| PSRule for Azure | latest | `Install-Module PSRule.Rules.Azure` |
| AzGovViz | latest | [Download](https://github.com/JulianHayward/Azure-MG-Sub-Governance-Reporting) to `tools/AzGovViz/` |
| Reader | subscription | All four tools need at minimum `Reader` on subscriptions in scope |

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

### Scope options

```powershell
# Single subscription
.\Invoke-AzureAnalyzer.ps1 -SubscriptionId "00000000-0000-0000-0000-000000000000"

# Management group
.\Invoke-AzureAnalyzer.ps1 -ManagementGroup "my-landing-zone"

# Skip tools you don't have installed
.\Invoke-AzureAnalyzer.ps1 -SubscriptionId "..." -SkipAzGovViz -SkipPSRule
```

## Output

After a run, `output/` contains:

| File | Description |
|---|---|
| `results.json` | All findings in unified schema |
| `report.md` | Markdown report — summary table + Fix Now / Plan / Track sections |
| `report.html` | Offline HTML report — sortable table, severity badges, no CDN dependencies |

### Report structure

- **Fix Now** — High + Critical severity findings
- **Plan** — Medium severity
- **Track** — Low + Info severity
- Per-category breakdown with finding counts

## Required Azure permissions

| Scope | Role |
|---|---|
| Subscriptions / management groups | `Reader` |
| Resource groups | `Reader` (inherited) |

No write permissions are required. All tools operate read-only.

## CI / Automation

| Workflow | Trigger | What it does |
|---|---|---|
| `codeql.yml` | Push / PR / weekly | Static analysis (CodeQL v4, SHA-pinned) |
| `ci-failure-analysis.yml` | Any workflow failure | Auto-creates `bug`+`squad` issue with log excerpt |
| `squad-heartbeat.yml` | PR open/sync + schedule | Squad CI gate |

## License

MIT
