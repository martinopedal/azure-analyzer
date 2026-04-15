# azure-analyzer

Automated Azure assessment that bundles **azqr**, **PSRule for Azure**, **AzGovViz**, **ALZ Resource Graph queries**, and **WARA** into a single orchestrated run with unified Markdown and HTML reports.

## Quick Start

```powershell
# 1. Clone & connect
git clone https://github.com/martinopedal/azure-analyzer.git
cd azure-analyzer
Connect-AzAccount -TenantId "<your-tenant-id>"

# 2. Run
.\Invoke-AzureAnalyzer.ps1 -SubscriptionId "<your-subscription-id>"
```

Results land in `output/` — a JSON file, an HTML dashboard, and a Markdown report. That's it.

## What you get

After a run, `output/` contains:

| File | Description |
|---|---|
| `results.json` | All findings in a unified 10-field schema |
| `report.html` | Offline HTML dashboard — donut chart, stat cards, per-source bars, filterable tables, print-friendly |
| `report.md` | GitHub-flavored Markdown — summary tables, per-category findings, action plan |

**Reports are auto-generated** after the run writes `results.json` — no manual step needed.

### HTML Report features

- **Executive summary** — auto-generated compliance prose (resource count, tool count, compliance %, high-severity callout)
- **Pure-CSS donut chart** — compliance percentage with conic-gradient (no JavaScript)
- **Per-source breakdown** — horizontal bar chart showing finding counts per tool
- **Search & filter** — text input for instant filtering across all finding tables
- **Clickable remediation URLs** — automatically wrapped in anchor tags
- **Tool coverage badges** — shows which tools ran vs were skipped
- **Print-friendly CSS** — hides interactive elements, prevents page breaks in rows

<details>
<summary>📊 Preview: HTML report layout</summary>

The HTML report is a self-contained single-file dashboard. No CDN dependencies — all CSS is inline, works offline.

```
┌─────────────────────────────────────────────────────────────┐
│  Azure Analyzer Report                                      │
│  Generated: 2025-04-15 10:30 UTC                            │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  ┌──────────┐  Scanned 18 resources across 5 tools.         │
│  │          │  33% compliant overall.                        │
│  │   33%    │  5 high-severity findings require              │
│  │  ◉ donut │  immediate action.                            │
│  │          │                                                │
│  └──────────┘                                                │
│                                                             │
│  ┌──────────┐ ┌──────────┐ ┌──────────┐ ┌──────────┐       │
│  │ Total    │ │ High     │ │ Medium   │ │ Compliant│       │
│  │   18     │ │    5     │ │    5     │ │   33%    │       │
│  └──────────┘ └──────────┘ └──────────┘ └──────────┘       │
│                                                             │
│  Findings by source                                         │
│  ├─ Azure Quick Review  ████████████░░░░░  3                │
│  ├─ PSRule              ████████████████░  4                │
│  ├─ AzGovViz            ████████████░░░░░  3                │
│  ├─ ALZ Queries         ████████████████░  4                │
│  └─ WARA                ████████████████░  4                │
│                                                             │
│  Tool coverage                                              │
│  ✅ Azure Quick Review  ✅ PSRule  ✅ AzGovViz               │
│  ✅ ALZ Queries         ✅ WARA                              │
│                                                             │
│  Findings by category                                       │
│  ▸ Compute (2)                                              │
│  ▸ Identity (2)                                             │
│  ▸ Networking (4)     ← click to expand sortable table      │
│  ▸ Reliability (4)                                          │
│  ▸ Security (4)                                             │
│  ▸ Storage (2)                                              │
└─────────────────────────────────────────────────────────────┘
```

Each category expands to a filterable, sortable table with columns: Title, Severity, Source, Compliant, Detail, Remediation, Resource ID, Learn More.

</details>

### Markdown Report features

- **Executive summary** — GitHub-flavored callouts (WARNING/NOTE/TIP) based on severity
- **Mermaid pie chart** — compliance breakdown (rendered natively on GitHub)
- **Severity badges** — per-source emoji indicators (🔴 High, 🟠 Med, 🟡 Low, 🟢 All compliant)
- **Collapsible sections** — per-category finding tables via `<details>` tags
- **Tool coverage matrix** — shows which tools ran vs were skipped

<details>
<summary>📊 Preview: Markdown report output</summary>

The Markdown report renders natively on GitHub with tables, action-plan sections, and per-source breakdowns.

> **Summary**
>
> | Metric | Count |
> |---|---|
> | Total findings | 18 |
> | Non-compliant | 12 |
> | Compliant | 6 |
> | High severity | 5 |
> | Medium severity | 5 |
> | Low severity | 2 |
> | Info | 6 |
>
> **By source**
>
> | Source | Findings | Non-compliant |
> |---|---|---|
> | azqr | 3 | 2 |
> | psrule | 4 | 3 |
> | azgovviz | 3 | 2 |
> | alz-queries | 4 | 2 |
> | wara | 4 | 3 |

The report groups findings by category, then prioritizes action:

> **Fix now (High, non-compliant)**
>
> | Title | Source | Detail |
> |---|---|---|
> | NSG has no inbound rules restricting SSH access | azqr | NSG allows SSH from any source |
> | Key Vault soft delete is disabled | azqr | Risks permanent data loss |
> | Owner role assigned to external guest user | azgovviz | Guest has Owner on subscription |
> | Public IPs without DDoS protection | alz-queries | 3 public IPs unprotected |
> | App Service plan has only 1 instance | wara | Single point of failure |

</details>

> 💡 Full sample reports are available in [`samples/`](samples/) — open `sample-report.html` in a browser or view `sample-report.md` on GitHub.

### Report structure

- **Fix Now** — High + Critical severity findings
- **Plan** — Medium severity
- **Track** — Low + Info severity
- Per-category breakdown with finding counts

## Prerequisites

| Requirement | Version | Install |
|---|---|---|
| PowerShell | 7+ | `pwsh --version` |
| Azure CLI | latest | `az version` |
| Az PowerShell | latest | `Install-Module Az` |
| azqr | latest | `winget install azure-quick-review.azqr` |
| PSRule for Azure | latest | `Install-Module PSRule.Rules.Azure` |
| AzGovViz | latest | [Download](https://github.com/JulianHayward/Azure-MG-Sub-Governance-Reporting) to `tools/AzGovViz/` |
| WARA | latest | `Install-Module WARA` (auto-installed if missing) |

All tools need at minimum **Reader** on subscriptions in scope. See [PERMISSIONS.md](PERMISSIONS.md) for details.

## Usage

```powershell
# Single subscription
.\Invoke-AzureAnalyzer.ps1 -SubscriptionId "00000000-0000-0000-0000-000000000000"

# Management group (scans all child subscriptions)
.\Invoke-AzureAnalyzer.ps1 -ManagementGroup "my-landing-zone"

# Skip tools you don't have installed
.\Invoke-AzureAnalyzer.ps1 -SubscriptionId "..." -SkipAzGovViz -SkipPSRule
```

### What it runs

| Phase | Tool | What it checks |
|---|---|---|
| 1 | azqr | Compliance posture per resource type |
| 2 | PSRule for Azure | Rule-based policy validation |
| 3 | AzGovViz | Tenant / management-group / subscription hierarchy |
| 4 | ALZ queries | 132 custom Azure Resource Graph queries |
| 5 | WARA | Well-Architected Reliability Assessment |

## Schema reference

All findings are merged into `output/results.json` using a unified 10-field schema:

| Field | Type | Description |
|---|---|---|
| `Id` | string | Unique finding identifier |
| `Source` | string | `azqr`, `psrule`, `azgovviz`, `alz-queries`, or `wara` |
| `Category` | string | e.g. Security, Reliability, Networking, Compute, Storage, Identity |
| `Title` | string | Short finding title |
| `Severity` | string | `Critical`, `High`, `Medium`, `Low`, or `Info` |
| `Compliant` | boolean | Whether the resource passes the check |
| `Detail` | string | Detailed description of the finding |
| `Remediation` | string | Steps to fix (may include URLs) |
| `ResourceId` | string | Azure ARM resource ID |
| `LearnMoreUrl` | string | Link to Microsoft Learn documentation |

## Permissions

| Scope | Role |
|---|---|
| Subscriptions / management groups | `Reader` |
| Resource groups | `Reader` (inherited) |

No write permissions are required. All tools operate read-only. See [PERMISSIONS.md](PERMISSIONS.md) for a full per-tool breakdown.

---

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for the full process. Key points:

- Fork → branch → PR against `main`
- Every PR that changes code must include a docs update (README, CHANGELOG, PERMISSIONS.md as applicable)
- ARG queries live in `queries/` as JSON — every query must return a `compliant` column (boolean)
- All GitHub Actions must use SHA-pinned versions

The `.squad/` directory contains AI team infrastructure for automated triage and development workflows. It is **not** part of the tool itself and is excluded from archive downloads.

## CI / Automation

| Workflow | Trigger | Purpose |
|---|---|---|
| `codeql.yml` | Push / PR / weekly | Static analysis for security vulnerabilities (CodeQL, SHA-pinned) |
| `docs-check.yml` | PR | Ensures documentation is updated with code changes |

<details>
<summary>Maintainer workflows (squad infrastructure)</summary>

These workflows support the AI development team and are excluded from archive downloads.

| Workflow | Purpose |
|---|---|
| `squad-heartbeat.yml` | Automated triage and CI gate via Ralph |
| `squad-triage.yml` | Issue routing to squad members |
| `squad-issue-assign.yml` | Auto-assignment of issues to squad agents |
| `sync-squad-labels.yml` | Syncs squad labels across the repo |
| `ci-failure-analysis.yml` | Auto-creates bug issues with log excerpts on workflow failures |
| `auto-label-issues.yml` | Adds the `squad` label to new issues |

</details>

## Data Sources & Attribution

This tool wraps the following open-source projects. See [THIRD_PARTY_NOTICES.md](./THIRD_PARTY_NOTICES.md) for full license details.

| Tool | Source | License |
|------|--------|---------|
| azqr | [Azure/azqr](https://github.com/Azure/azqr) | MIT |
| AzGovViz | [JulianHayward/Azure-MG-Sub-Governance-Reporting](https://github.com/JulianHayward/Azure-MG-Sub-Governance-Reporting) | MIT |
| PSRule for Azure | [Azure/PSRule.Rules.Azure](https://github.com/Azure/PSRule.Rules.Azure) | MIT |
| WARA | [Azure/Azure-Proactive-Resiliency-Library-v2](https://github.com/Azure/Azure-Proactive-Resiliency-Library-v2) | MIT |
| ALZ Query Data | [martinopedal/alz-graph-queries](https://github.com/martinopedal/alz-graph-queries) (derived from [Azure/review-checklists](https://github.com/Azure/review-checklists)) | MIT |

## License

MIT
