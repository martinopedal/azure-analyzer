# azure-analyzer

Automated Azure assessment that bundles **azqr**, **PSRule for Azure**, **AzGovViz**, the **ALZ Resource Graph queries** from [alz-graph-queries](https://github.com/martinopedal/alz-graph-queries), and **WARA** into a single orchestrated run with unified Markdown and HTML reports.

## What it does

| Phase | Script | What it runs |
|---|---|---|
| 1 — azqr | `modules/Invoke-Azqr.ps1` | Azure Quick Review CLI — compliance posture per resource type |
| 2 — PSRule | `modules/Invoke-PSRule.ps1` | PSRule for Azure — rule-based policy validation |
| 3 — AzGovViz | `modules/Invoke-AzGovViz.ps1` | Azure Governance Visualizer — tenant/MG/subscription hierarchy |
| 4 — ALZ queries | `modules/Invoke-AlzQueries.ps1` | 132 custom ARG queries from alz-graph-queries |
| 5 — WARA | `modules/Invoke-WARA.ps1` | Well-Architected Reliability Assessment — reliability findings per resource |
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
| WARA | latest | `Install-Module WARA` (auto-installed if missing) |
| Reader | subscription | All five tools need at minimum `Reader` on subscriptions in scope |

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


## Hybrid Network Queries

`queries/hybrid_network_queries.json` contains 6 ARG queries for on-premises/hybrid connectivity health assessment:

| ID | Check | Severity |
|---|---|---|
| HN-001 | ExpressRoute circuit provisioning state (Enabled + Provisioned) | High |
| HN-002 | ExpressRoute circuit SKU (not Basic) | Medium |
| HN-003 | VPN gateway active-active configuration | Medium |
| HN-004 | VPN gateway SKU (not Basic) | Medium |
| HN-005 | VPN connection BGP enablement | Low |
| HN-006 | VPN connection status (Connected) | High |

**Empty-result semantics**: if no hybrid resources exist in scope (e.g., no VPN gateways), the query returns zero rows and is treated as not applicable -- not non-compliant.

### Extending with custom queries

All `*.json` files in the `queries/` directory are auto-loaded by `Invoke-AlzQueries.ps1`. Add your own file using the azure-analyzer schema:

```json
{
  "metadata": { "version": "1.0", "description": "My custom queries" },
  "queries": [
    {
      "guid": "MY-001",
      "category": "Security",
      "subcategory": "...",
      "severity": "High",
      "text": "Human readable check description",
      "query": "resources | where ... | extend compliant = (...) | project id, name, resourceGroup, compliant",
      "not_queryable_reason": null
    }
  ]
}
```

Every query **must** return a `compliant` boolean column. The `query` field (azure-analyzer format) and `graph` field (alz-graph-queries format) are both supported.

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
