# azure-analyzer

Automated Azure assessment that bundles **azqr**, **PSRule for Azure**, **AzGovViz**, **ALZ Resource Graph queries**, **WARA**, **Maester**, and **OpenSSF Scorecard** into a single orchestrated run with unified Markdown and HTML reports. Covers resource compliance, identity security, and supply chain security dimensions.

## Quick Start

### Option 1: Install from PSGallery (recommended)

```powershell
# 1. Install the module
Install-Module AzureAnalyzer -Scope CurrentUser

# 2. Connect to Azure
Connect-AzAccount -TenantId "<your-tenant-id>"

# 3. Run
Invoke-AzureAnalyzer -SubscriptionId "<your-subscription-id>"
```

Results land in `output/` — a JSON file, an HTML dashboard, and a Markdown report. That's it.

### Option 2: Clone and run from source

```powershell
# 1. Clone & connect
git clone https://github.com/martinopedal/azure-analyzer.git
cd azure-analyzer
Connect-AzAccount -TenantId "<your-tenant-id>"

# 2. Run
.\Invoke-AzureAnalyzer.ps1 -SubscriptionId "<your-subscription-id>"
```

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

📄 **[View the sample Markdown report →](samples/sample-report.md)** (renders natively on GitHub — tables, categories, action plan)

📊 **[Download the sample HTML report →](samples/sample-report.html)** (open in any browser — donut chart, stat cards, filterable tables, works offline)

### HTML Report features

```
┌─────────────────────────────────────────────────────────────┐
│  Azure Analyzer Report                                      │
│  Generated: 2025-04-15 10:30 UTC                            │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  ┌──────────┐  Scanned 18 resources across 7 tools.         │
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
│  ✅ ALZ Queries         ✅ WARA    ✅ Maester                │
│  ✅ Scorecard                                               │
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

- Executive summary with compliance %, resource count, high-severity callout
- Pure-CSS donut chart (no JavaScript)
- Per-source horizontal bar chart
- Search/filter across all finding tables
- Clickable remediation URLs and Learn More links
- Tool coverage badges (ran vs skipped)
- Print-friendly CSS

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
> | maester | 2 | 1 |
> | scorecard | 1 | 1 |

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
| Maester | latest | `Install-Module Maester -Scope CurrentUser` |
| OpenSSF Scorecard | latest | Download from https://github.com/ossf/scorecard/releases |

**Important notes:**
- Maester requires `Connect-MgGraph` before running (authenticates to Microsoft Graph for Entra ID assessment)
- Scorecard analyzes repository security posture; provide `GITHUB_AUTH_TOKEN` environment variable for authenticated API access (optional but recommended for rate limits)

## Usage

```powershell
# Single subscription
.\Invoke-AzureAnalyzer.ps1 -SubscriptionId "00000000-0000-0000-0000-000000000000"

# Management group (scans all child subscriptions)
.\Invoke-AzureAnalyzer.ps1 -ManagementGroup "my-landing-zone"

# Skip tools you don't have installed
.\Invoke-AzureAnalyzer.ps1 -SubscriptionId "..." -SkipAzGovViz -SkipPSRule
```

### Scoped Runs

Run **only specific tools** or **exclude certain tools** with `-IncludeTools` (allowlist) and `-ExcludeTools` (blocklist). Mix and match for focused assessments:

| Use Case | Command |
|----------|---------|
| **Full assessment** (default) | `.\Invoke-AzureAnalyzer.ps1 -SubscriptionId "..." -ManagementGroupId "..." -Repository "github.com/org/repo"` |
| **Azure resources only** | `.\Invoke-AzureAnalyzer.ps1 -SubscriptionId "..." -ExcludeTools 'maester','scorecard'` |
| **Identity security only** (Entra ID) | `.\Invoke-AzureAnalyzer.ps1 -IncludeTools 'maester'` |
| **Repository security only** | `.\Invoke-AzureAnalyzer.ps1 -IncludeTools 'scorecard' -Repository "github.com/org/repo"` |
| **Everything except governance** | `.\Invoke-AzureAnalyzer.ps1 -SubscriptionId "..." -ExcludeTools 'azgovviz'` |
| **Compliance checks only** | `.\Invoke-AzureAnalyzer.ps1 -SubscriptionId "..." -IncludeTools 'azqr','psrule'` |

**Valid tool names:** `azqr`, `psrule`, `azgovviz`, `alz-queries`, `wara`, `maester`, `scorecard`

You can use `-IncludeTools` and `-ExcludeTools` together (inclusion list is evaluated first, then exclusions are applied). Useful for "all except" patterns or custom combinations.

### What each tool does

| # | Tool | What it assesses | How it works |
|---|------|-----------------|-------------|
| 1 | **[azqr](https://azure.github.io/azqr)** | Azure resource compliance — storage encryption, Key Vault config, App Service HTTPS, SQL auditing, 200+ checks | CLI scans a subscription and emits per-resource recommendations with severity |
| 2 | **[PSRule for Azure](https://azure.github.io/PSRule.Rules.Azure/)** | Infrastructure best practices — managed disks, network isolation, diagnostic settings, WAF alignment | PowerShell module evaluates resources against 400+ rules, returns pass/fail per rule |
| 3 | **[AzGovViz](https://github.com/JulianHayward/Azure-MG-Sub-Governance-Reporting)** | Governance hierarchy — management group structure, RBAC assignments, policy compliance, orphaned resources | PowerShell script crawls the tenant tree and reports governance anomalies |
| 4 | **[ALZ Queries](https://github.com/martinopedal/alz-graph-queries)** | Azure Landing Zone compliance — 132 ARG queries from Azure review checklists covering networking, identity, compute, storage | Runs each query against Azure Resource Graph and checks the `compliant` column |
| 5 | **[WARA](https://github.com/Azure/Azure-Proactive-Resiliency-Library-v2)** | Reliability posture — single points of failure, missing geo-replication, health probe config, zone redundancy | PSGallery module runs the Well-Architected Reliability Assessment collector |
| 6 | **[Maester](https://github.com/maester365/maester)** | Entra ID security configuration — EIDSCA and CISA baseline compliance checks for identity posture | PowerShell module runs Pester tests against Microsoft Graph and tenant configuration |
| 7 | **[OpenSSF Scorecard](https://github.com/ossf/scorecard)** | Repository supply chain security — branch protection, dependency pinning, CI/CD, commit signing practices | CLI scans a GitHub repository and scores security controls (0-10 per category) |

## Schema reference

All findings are merged into `output/results.json` using a unified 10-field schema:

| Field | Type | Description |
|---|---|---|
| `Id` | string | Unique finding identifier |
| `Source` | string | `azqr`, `psrule`, `azgovviz`, `alz-queries`, `wara`, `maester`, or `scorecard` |
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
| Maester | [maester365/maester](https://github.com/maester365/maester) | MIT |
| OpenSSF Scorecard | [ossf/scorecard](https://github.com/ossf/scorecard) | Apache 2.0 |

## License

MIT
