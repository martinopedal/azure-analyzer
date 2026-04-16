# azure-analyzer

Automated Azure assessment that bundles **azqr**, **PSRule for Azure**, **AzGovViz**, **ALZ Resource Graph queries**, **WARA**, **Maester**, and **OpenSSF Scorecard** into a single orchestrated run with unified Markdown and HTML reports. Covers resource compliance, identity security, and supply chain security dimensions.

## Quick Start

**Scenario 1: Azure resources only**

```powershell
git clone https://github.com/martinopedal/azure-analyzer.git
cd azure-analyzer
Connect-AzAccount -TenantId "<your-tenant-id>"
.\Invoke-AzureAnalyzer.ps1 -SubscriptionId "<your-subscription-id>"
```

**Scenario 2: Azure + Identity security (Entra ID)**

```powershell
Connect-AzAccount -TenantId "<your-tenant-id>"
Connect-MgGraph -Scopes (Get-MtGraphScope)
.\Invoke-AzureAnalyzer.ps1 -SubscriptionId "<your-subscription-id>"
```

**Scenario 3: Full assessment (Azure + Identity + Repository)**

```powershell
Connect-AzAccount -TenantId "<your-tenant-id>"
Connect-MgGraph -Scopes (Get-MtGraphScope)
.\Invoke-AzureAnalyzer.ps1 -SubscriptionId "<your-subscription-id>" -Repository "github.com/org/repo"
```

Steps 2 and 3 are optional -- skip `Connect-MgGraph` if you only need Azure resource checks. See [Scoped Runs](#scoped-runs) for cherry-picking individual tools.

Missing PowerShell modules are detected and reported with install commands. Use `-InstallMissingModules` to auto-install them.

Results land in `output/` -- a JSON file, an HTML dashboard, and a Markdown report. That's it.

## What you get

After a run, `output/` contains:

| File | Description |
|---|---|
| `results.json` | All findings in a unified 10-field schema |
| `report.html` | Offline HTML dashboard -- donut chart, stat cards, per-source bars, filterable tables, print-friendly |
| `report.md` | GitHub-flavored Markdown -- summary tables, per-category findings, action plan |
| `triage.json` | *(optional)* AI-enriched findings -- generated with `-EnableAiTriage` |

**Reports are auto-generated** after the run writes `results.json` -- no manual step needed.

### HTML Report features

- **Executive summary** -- auto-generated compliance prose (resource count, tool count, compliance %, high-severity callout)
- **Pure-CSS donut chart** -- compliance percentage with conic-gradient (no JavaScript)
- **Clickable stat cards** -- filter findings by severity with keyboard-accessible buttons
- **Per-source breakdown** -- horizontal bar chart showing finding counts per tool
- **Severity borders** -- color-coded left border on each finding row (High=red, Medium=orange, Low=yellow)
- **Zebra striping** -- alternating row backgrounds for readability
- **Search and filter** -- text input for instant filtering across all finding tables
- **Clickable remediation URLs** -- automatically wrapped in anchor tags
- **Tool coverage badges** -- shows actual tool status (Success, Skipped, Failed, Excluded)
- **Print-friendly CSS** -- hides interactive elements, prevents page breaks in rows

📄 **[View the sample Markdown report →](samples/sample-report.md)** (renders natively on GitHub -- tables, categories, action plan)

📊 **[Download the sample HTML report →](samples/sample-report.html)** (open in any browser -- donut chart, stat cards, filterable tables, works offline)

### Markdown Report features

- **Executive summary** -- GitHub-flavored callouts (WARNING/NOTE/TIP) based on severity
- **Mermaid pie chart** -- compliance breakdown (rendered natively on GitHub)
- **Severity badges** -- per-source emoji indicators
- **Collapsible sections** -- per-category finding tables via `<details>` tags
- **Tool coverage matrix** -- shows which tools ran, with status column

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

> 💡 Full sample reports are available in [`samples/`](samples/) -- open `sample-report.html` in a browser or view `sample-report.md` on GitHub.

### Report structure

- **Fix Now** -- High + Critical severity findings
- **Plan** -- Medium severity
- **Track** -- Low + Info severity
- Per-category breakdown with finding counts

## Prerequisites

| What | Install | Needed for |
|------|---------|-----------|
| PowerShell 7.2+ | `winget install Microsoft.PowerShell` | Everything |
| Az PowerShell module | `Install-Module Az -Scope CurrentUser` | Azure tools (azqr, PSRule, AzGovViz, ALZ, WARA) |
| Microsoft.Graph module | `Install-Module Microsoft.Graph -Scope CurrentUser` | Maester (identity security) |
| azqr CLI | `winget install azure-quick-review.azqr` | Resource compliance scanning |
| scorecard CLI | [Download](https://github.com/ossf/scorecard/releases) | Repository security (optional) |

**Auto-install**: PSRule, WARA, Maester, and Az.ResourceGraph are auto-installed when you pass `-InstallMissingModules`. CLI tools (azqr, scorecard) must be installed manually.

**AzGovViz** is a standalone script, not a module. Clone it into `tools/AzGovViz/` or `$HOME/AzGovViz/`:
```
git clone https://github.com/JulianHayward/Azure-MG-Sub-Governance-Reporting tools/AzGovViz
```

**Identity security (Maester)** requires a Graph connection: `Connect-MgGraph -Scopes (Get-MtGraphScope)`. Not needed if you exclude Maester.

**Repository security (Scorecard)** works best with `GITHUB_AUTH_TOKEN` set (5,000 req/hr vs 60 without). Not needed if you skip Scorecard.

## Usage

```powershell
# Single subscription (Azure resource tools only)
.\Invoke-AzureAnalyzer.ps1 -SubscriptionId "00000000-0000-0000-0000-000000000000"

# Management group (auto-discovers child subscriptions, scans recursively)
.\Invoke-AzureAnalyzer.ps1 -ManagementGroupId "my-landing-zone"

# Tenant root (scan all subscriptions in tenant)
.\Invoke-AzureAnalyzer.ps1 -ManagementGroupId "tenant-root-group-id"

# MG tools only (no per-subscription recursion)
.\Invoke-AzureAnalyzer.ps1 -ManagementGroupId "my-mg" -Recurse:$false

# Azure + Entra ID identity security
.\Invoke-AzureAnalyzer.ps1 -SubscriptionId "..." # Maester runs automatically if Connect-MgGraph is active

# Azure + repository supply chain security
.\Invoke-AzureAnalyzer.ps1 -SubscriptionId "..." -Repository "github.com/org/repo"

# Full assessment (all 3 dimensions)
.\Invoke-AzureAnalyzer.ps1 -ManagementGroupId "..." -Repository "github.com/org/repo"

# Custom output directory
.\Invoke-AzureAnalyzer.ps1 -SubscriptionId "..." -OutputPath "C:\reports\april"

# CI/automation (skip interactive prereq check)
.\Invoke-AzureAnalyzer.ps1 -SubscriptionId "..." -SkipPrereqCheck
```

### Parameters

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `-SubscriptionId` | string | -- | Azure subscription to scan |
| `-ManagementGroupId` | string | -- | Management group (discovers child subs) |
| `-TenantId` | string | current context | Azure tenant ID (used by WARA) |
| `-OutputPath` | string | `.\output` | Directory for results, reports, and errors |
| `-Repository` | string | -- | GitHub repo for Scorecard (e.g. `github.com/org/repo`) |
| `-IncludeTools` | string[] | -- | Run only these tools (allowlist) |
| `-ExcludeTools` | string[] | -- | Skip these tools (blocklist) |
| `-Recurse` | switch | `$true` when MG set | Discover child subscriptions under MG |
| `-ScorecardThreshold` | int (0-10) | 7 | Minimum score for a Scorecard check to be compliant |
| `-InstallMissingModules` | switch | `$false` | Auto-install missing PowerShell modules |
| `-SkipPrereqCheck` | switch | `$false` | Skip prerequisite detection (for CI pipelines) |
| `-EnableAiTriage` | switch | `$false` | Enrich findings via GitHub Copilot SDK (requires license) |

### Management Group hierarchy

When you provide `-ManagementGroupId`, subscription-scoped tools (azqr, PSRule, WARA) automatically run per discovered child subscription:

| Scope | Behavior |
|-------|----------|
| **Single subscription** | Run tools once for that subscription |
| **Management group with `-Recurse:$true` (default)** | Discover all child subscriptions; run sub-scoped tools per subscription; run MG-scoped tools once at MG level |
| **Management group with `-Recurse:$false`** | Run only MG-scoped tools (AzGovViz, ALZ Queries); skip per-subscription tools |
| **Tenant root group** | Discover all subscriptions in tenant; run sub-scoped tools per subscription |

**Permission requirements:**
- `Reader` on the management group (inherited to child subscriptions) **OR** `Reader` on each individual subscription

### Scoped Runs

Run **only specific tools** or **exclude certain tools** with `-IncludeTools` (allowlist) and `-ExcludeTools` (blocklist). Mix and match for focused assessments:

| Use Case | Command |
|----------|---------|
| **Full assessment** | `.\Invoke-AzureAnalyzer.ps1 -SubscriptionId "..." -ManagementGroupId "..." -Repository "github.com/org/repo"` |
| **Entire MG tree** | `.\Invoke-AzureAnalyzer.ps1 -ManagementGroupId "my-mg"` |
| **MG governance only** (no per-sub scanning) | `.\Invoke-AzureAnalyzer.ps1 -ManagementGroupId "my-mg" -Recurse:$false` |
| **Azure resources only** | `.\Invoke-AzureAnalyzer.ps1 -SubscriptionId "..." -ExcludeTools 'maester','scorecard'` |
| **Identity security only** (Entra ID) | `.\Invoke-AzureAnalyzer.ps1 -IncludeTools 'maester'` |
| **Repository security only** | `.\Invoke-AzureAnalyzer.ps1 -IncludeTools 'scorecard' -Repository "github.com/org/repo"` |
| **MG tree + repo security** | `.\Invoke-AzureAnalyzer.ps1 -ManagementGroupId "..." -IncludeTools 'azgovviz','alz-queries','scorecard' -Repository "..."` |
| **Compliance checks only** | `.\Invoke-AzureAnalyzer.ps1 -SubscriptionId "..." -IncludeTools 'azqr','psrule'` |
| **Everything except governance** | `.\Invoke-AzureAnalyzer.ps1 -ManagementGroupId "..." -ExcludeTools 'azgovviz'` |

**Valid tool names:** `azqr`, `psrule`, `azgovviz`, `alz-queries`, `wara`, `maester`, `scorecard`

Use `-IncludeTools` OR `-ExcludeTools` (not both). The orchestrator throws if you specify both.

### What each tool does

| # | Tool | What it assesses | How it works |
|---|------|-----------------|-------------|
| 1 | **[azqr](https://azure.github.io/azqr)** | Azure resource compliance -- storage encryption, Key Vault config, App Service HTTPS, SQL auditing, 200+ checks | CLI scans a subscription and emits per-resource recommendations with severity |
| 2 | **[PSRule for Azure](https://azure.github.io/PSRule.Rules.Azure/)** | Infrastructure best practices -- managed disks, network isolation, diagnostic settings, WAF alignment | PowerShell module evaluates resources against 400+ rules, returns pass/fail per rule |
| 3 | **[AzGovViz](https://github.com/JulianHayward/Azure-MG-Sub-Governance-Reporting)** | Governance hierarchy -- management group structure, RBAC assignments, policy compliance, orphaned resources | PowerShell script crawls the tenant tree and reports governance anomalies |
| 4 | **[ALZ Queries](https://github.com/martinopedal/alz-graph-queries)** | Azure Landing Zone compliance -- 132 ARG queries from Azure review checklists covering networking, identity, compute, storage | Runs each query against Azure Resource Graph and checks the `compliant` column |
| 5 | **[WARA](https://github.com/Azure/Azure-Proactive-Resiliency-Library-v2)** | Reliability posture -- single points of failure, missing geo-replication, health probe config, zone redundancy | PSGallery module runs the Well-Architected Reliability Assessment collector |
| 6 | **[Maester](https://github.com/maester365/maester)** | Entra ID security configuration -- EIDSCA and CISA baseline compliance checks for identity posture | PowerShell module runs Pester tests against Microsoft Graph and tenant configuration |
| 7 | **[OpenSSF Scorecard](https://github.com/ossf/scorecard)** | Repository supply chain security -- branch protection, dependency pinning, CI/CD, commit signing practices | CLI scans a GitHub repository and scores security controls (0-10 per category) |

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

All tools operate read-only. No write permissions required anywhere.

| Scope | What needs it |
|-------|--------------|
| **Azure Reader** | azqr, PSRule, AzGovViz, ALZ Queries, WARA |
| **Microsoft Graph** (read) | Maester -- Entra ID security |
| **GitHub token** (optional) | Scorecard -- repo security (recommended for rate limits) |
| **Copilot license** (optional) | AI triage -- fully optional; only used with `-EnableAiTriage` flag |

See [PERMISSIONS.md](PERMISSIONS.md) for exact scopes, token types, setup commands, and troubleshooting.

---

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for the full process. Key points:

- Fork → branch → PR against `main`
- Every PR that changes code must include a docs update (README, CHANGELOG, PERMISSIONS.md as applicable)
- ARG queries live in `queries/` as JSON -- every query must return a `compliant` column (boolean)
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
