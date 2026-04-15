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

All findings are merged into `output/results.json` using a unified 10-field schema:

```json
{
  "source": "azqr|psrule|azgovviz|alzqueries|wara",
  "category": "Security|Reliability|Cost",
  "severity": "Critical|High|Medium|Low|Info",
  "title": "Finding title",
  "description": "Detailed description",
  "resourceId": "/subscriptions/.../resourceGroups/.../providers/...",
  "learnMoreUrl": "https://learn.microsoft.com/...",
  "remediation": "Steps to fix",
  "source": "azqr",
  "timestamp": "2024-01-15T10:30:00Z"
}
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
| `results.json` | All findings in unified 10-field schema (see above) |
| `report.md` | GitHub-flavored Markdown with exec summary, Mermaid pie chart, callouts, collapsible sections, and tool coverage |
| `report.html` | Offline HTML dashboard — pure-CSS donut chart, executive summary, per-source bar breakdown, search/filter, clickable remediation URLs, print-friendly, zero JS dependencies |

**Reports are auto-generated** after `Invoke-AzureAnalyzer.ps1` writes `results.json` — no manual step needed.

### HTML Report features

- **Executive summary** — auto-generated compliance prose (resource count, tool count, compliance %, high-severity callout)
- **Pure-CSS donut chart** — compliance percentage with conic-gradient (no JavaScript)
- **Per-source breakdown** — horizontal bar chart showing finding counts per tool
- **Search & filter** — text input for instant filtering across all finding tables
- **Clickable remediation URLs** — automatically wrapped in anchor tags
- **Tool coverage badges** — shows which tools ran vs were skipped
- **Print-friendly CSS** — hides interactive elements, prevents page breaks in rows

### Markdown Report features

- **Executive summary** — GitHub-flavored callouts (WARNING/NOTE/TIP) based on severity
- **Mermaid pie chart** — compliance breakdown (rendered natively on GitHub)
- **Severity badges** — per-source emoji indicators (🔴 High, 🟠 Med, 🟡 Low, 🟢 All compliant)
- **Collapsible sections** — per-category finding tables via `<details>` tags
- **Tool coverage matrix** — shows which tools ran vs were skipped

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

## Data Sources & Attribution

This tool wraps the following open-source projects. See [THIRD_PARTY_NOTICES.md](./THIRD_PARTY_NOTICES.md) for full license details.

| Tool | Source | License |
|------|--------|---------|
| azqr | [Azure/azqr](https://github.com/Azure/azqr) | MIT |
| AzGovViz | [JulianHayward/Azure-MG-Sub-Governance-Reporting](https://github.com/JulianHayward/Azure-MG-Sub-Governance-Reporting) | MIT |
| PSRule for Azure | [Azure/PSRule.Rules.Azure](https://github.com/Azure/PSRule.Rules.Azure) | MIT |
| WARA | [Azure/Azure-Proactive-Resiliency-Library-v2](https://github.com/Azure/Azure-Proactive-Resiliency-Library-v2) | MIT |
| ALZ Query Data | [Azure/review-checklists](https://github.com/Azure/review-checklists) | MIT |

## CI / Automation

| Workflow | Trigger | What it does |
|---|---|---|
| `codeql.yml` | Push / PR / weekly | Static analysis (CodeQL v4, SHA-pinned) |
| `ci-failure-analysis.yml` | Any workflow failure | Auto-creates `bug`+`squad` issue with log excerpt |
| `squad-heartbeat.yml` | PR open/sync + schedule | Squad CI gate |

## License

MIT
