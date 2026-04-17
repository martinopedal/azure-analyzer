# azure-analyzer

Automated Azure assessment that bundles **15 tools** — **azqr**, **PSRule for Azure**, **AzGovViz**, **ALZ Resource Graph queries**, **WARA**, **Azure Cost (Consumption API)**, **Defender for Cloud**, **kubescape (AKS runtime)**, **Maester**, **OpenSSF Scorecard**, **ADO Service Connections**, **Identity Correlator**, **zizmor**, **gitleaks**, and **Trivy** — into a single orchestrated run with unified Markdown and HTML reports. Covers resource compliance, reliability, cost, Defender Secure Score, AKS runtime posture (CIS Kubernetes Benchmark + NSA/CISA hardening), identity security, cross-dimensional identity correlation, supply chain security, CI/CD workflow security, secrets detection, and DevOps service connection dimensions.

Findings are normalized to a single v2 schema with 5 severity levels (**Critical**, **High**, **Medium**, **Low**, **Info**) and 12 entity types (AzureResource, Subscription, ManagementGroup, ServicePrincipal, ManagedIdentity, Application, User, Tenant, Repository, Workflow, Pipeline, ServiceConnection) across 4 platforms (Azure, Entra, GitHub, ADO).

**Cloud-first by default.** Repository-scoped scanners (zizmor, gitleaks, trivy, scorecard) target **remote** GitHub/ADO repos via `-Repository` / `-AdoOrg`, cloned through `modules/shared/RemoteClone.ps1` (HTTPS-only, host allow-list, token scrub). Local filesystem scanning remains available as a fallback via `-RepoPath`/`-ScanPath`.

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

**Scenario 4: GitHub Enterprise (GHEC-DR or GHES) repository**

```powershell
$env:GITHUB_AUTH_TOKEN = "<enterprise-pat>"
.\Invoke-AzureAnalyzer.ps1 -Repository "github.contoso.com/org/repo" -GitHubHost "github.contoso.com"
```

**Scenario 5: Azure DevOps service connections**

```powershell
$env:AZURE_DEVOPS_EXT_PAT = "<ado-pat>"
.\Invoke-AzureAnalyzer.ps1 -AdoOrg "contoso"
# Or scan a specific project:
.\Invoke-AzureAnalyzer.ps1 -AdoOrg "contoso" -AdoProject "my-project"
```

**Scenario 6: Local repo CI/CD security scan (zizmor + gitleaks)**

```powershell
# Scan current directory for workflow issues and leaked secrets
.\Invoke-AzureAnalyzer.ps1 -IncludeTools 'zizmor','gitleaks'
# Or scan a specific repo path
.\Invoke-AzureAnalyzer.ps1 -IncludeTools 'zizmor','gitleaks' -RepoPath "C:\repos\my-app"
```

Steps 2 and 3 are optional -- skip `Connect-MgGraph` if you only need Azure resource checks. See [Scoped Runs](#scoped-runs) for cherry-picking individual tools.

Missing prerequisites are detected and reported with install commands. Use **`-InstallMissingModules`** to auto-install them: the installer is **manifest-driven** — it reads each tool's `install` block in `tools/tool-manifest.json` and supports four kinds:

- **`psmodule`** — PSGallery install (PSRule, WARA, Maester, Az.ResourceGraph)
- **`cli`** — package-manager install (winget / brew / pipx / pip / snap) with a name-allow-list regex and an allow-listed set of managers
- **`gitclone`** — HTTPS-only clone with a host allow-list (used by AzGovViz auto-bootstrap into `tools/AzGovViz/`)
- **`none`** — no-op for tools that have nothing to install

The installer enforces a 300s timeout on external commands, scrubs credentials from output via `Remove-Credentials`, returns rich error objects (`New-InstallerError` / `Write-InstallerError`), and retries transient failures via `Invoke-WithInstallRetry` (jittered backoff).

**AzGovViz auto-bootstrap:** when `-InstallMissingModules` is set and AzGovViz is enabled, the installer clones `https://github.com/JulianHayward/Azure-MG-Sub-Governance-Reporting` into `tools/AzGovViz/` on first run — no manual step required.

Results land in `output/` -- multiple JSON files (findings, entities, tool status, and conditionally errors), an HTML dashboard, and a Markdown report. That's it.
Sensitive tokens are scrubbed from console output, errors.json, and report files before writing.

## What you get

After a run, `output/` contains:

| File | Description |
|---|---|
| `results.json` | Backward-compatible flat findings (v1 format, all tools' observations in single array) |
| `entities.json` | Entity-centric view (v3 format, observations per entity with platform/type hierarchy) |
| `tool-status.json` | Per-tool execution status (Success, Skipped, Failed) with message and finding count |
| `errors.json` | Tool failures and error details (only written when errors occur) |
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

## Architecture & contributor docs

- **Pipeline + dual data model:** [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)
- **Add a new tool:** [docs/CONTRIBUTING-TOOLS.md](docs/CONTRIBUTING-TOOLS.md)
- **Template safety:** report generators must escape `</` as `<\/` when replacing `{{MODEL_JSON}}` in `report-template.html`.

## Prerequisites

| What | Install | Needed for |
|------|---------|-----------|
| PowerShell 7.4+ | `winget install Microsoft.PowerShell` | Everything |
| Az PowerShell module | `Install-Module Az -Scope CurrentUser` | Azure tools (azqr, PSRule, AzGovViz, ALZ, WARA) |
| Microsoft.Graph module | `Install-Module Microsoft.Graph -Scope CurrentUser` | Maester (identity security) |
| azqr CLI | `winget install azure-quick-review.azqr` | Resource compliance scanning |
| scorecard CLI | [Download](https://github.com/ossf/scorecard/releases) | Repository security (optional) |
| zizmor CLI | [Download](https://github.com/woodruffw/zizmor/releases) | GitHub Actions workflow security (optional) |
| gitleaks CLI | [Download](https://github.com/gitleaks/gitleaks/releases) | Secrets detection (optional) |
| trivy CLI ≥ 0.50.0 | [Download](https://github.com/aquasecurity/trivy/releases) | Dependency vulnerability scanning (optional) — download from [official releases](https://github.com/aquasecurity/trivy/releases) only; verify binary integrity |

- **Auto-install**: With `-InstallMissingModules` the manifest-driven installer covers **all 13 tools** — PowerShell modules (PSRule, WARA, Maester, Az.ResourceGraph, Az.Accounts for azure-cost), CLI tools via winget/brew/pipx/pip/snap (azqr, scorecard, zizmor, gitleaks, trivy), and git-clone bootstraps (AzGovViz). Without the flag, missing prerequisites are only listed with install commands — nothing is mutated.

**AzGovViz** is a standalone script, not a module. With `-InstallMissingModules` it is auto-cloned into `tools/AzGovViz/` on first run. To clone manually:
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

# GHEC-DR / GHES repository (enterprise GitHub instance)
.\Invoke-AzureAnalyzer.ps1 -Repository "github.contoso.com/org/repo" -GitHubHost "github.contoso.com"

# Azure DevOps service connections (all projects)
.\Invoke-AzureAnalyzer.ps1 -AdoOrg "contoso"

# Azure DevOps + Azure resources
.\Invoke-AzureAnalyzer.ps1 -SubscriptionId "..." -AdoOrg "contoso" -AdoProject "my-project"

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
| `-Repository` | string | -- | GitHub repo for Scorecard / zizmor / gitleaks / trivy (e.g. `github.com/org/repo` or full HTTPS URL) |
| `-AdoRepoUrl` | string | -- | Azure DevOps Git repo URL for zizmor / gitleaks / trivy (HTTPS only, e.g. `https://dev.azure.com/org/proj/_git/repo`) |
| `-RepoPath` | string | `.` | Local repo path for CI/CD scanning (zizmor, gitleaks) — fallback when no remote target |
| `-GitHubHost` | string | `github.com` | Custom GitHub host for GHEC-DR/GHES (e.g. `github.contoso.com`) |
| `-AdoOrg` | string | -- | Azure DevOps organization name (enables ADO tools) |
| `-AdoProject` | string | -- | Azure DevOps project (scans all projects if omitted) |
| `-IncludeTools` | string[] | -- | Run only these tools (allowlist) |
| `-ExcludeTools` | string[] | -- | Skip these tools (blocklist) |
| `-Framework` | `CIS`\|`NIST`\|`PCI` | -- | Scope compliance enrichment + report to a single framework |
| `-PreviousRun` | string | -- | Path to a prior `results.json`; HTML report renders New/Resolved/Unchanged badges + a delta summary banner |
| `-Recurse` | switch | `$true` when MG set | Discover child subscriptions under MG |
| `-ScorecardThreshold` | int (0-10) | 7 | Minimum score for a Scorecard check to be compliant |
| `-ScanPath` | string | `.` | Filesystem path for Trivy dependency scanning |
| `-ScanType` | string | `fs` | Trivy scan type: `fs` (filesystem) or `repo` (remote repository) |
| `-InstallMissingModules` | switch | `$false` | Auto-install missing PowerShell modules |
| `-SkipPrereqCheck` | switch | `$false` | Skip prerequisite detection (for CI pipelines) |
| `-EnableAiTriage` | switch | `$false` | Enrich findings via GitHub Copilot SDK (requires license) |

### Management Group hierarchy

When you provide `-ManagementGroupId`, subscription-scoped tools (azqr, PSRule, WARA, azure-cost) automatically run per discovered child subscription:

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
| **ADO service connections only** | `.\Invoke-AzureAnalyzer.ps1 -AdoOrg "contoso" -IncludeTools 'ado-connections'` |
| **Azure + ADO** | `.\Invoke-AzureAnalyzer.ps1 -SubscriptionId "..." -AdoOrg "contoso"` |
| **CI/CD security only** | `.\Invoke-AzureAnalyzer.ps1 -IncludeTools 'zizmor','gitleaks','trivy' -Repository "github.com/org/repo"` |
| **Supply chain scan (remote GitHub)** | `.\Invoke-AzureAnalyzer.ps1 -IncludeTools 'trivy' -Repository "github.com/org/repo"` |
| **Supply chain scan (remote ADO)** | `.\Invoke-AzureAnalyzer.ps1 -IncludeTools 'trivy' -AdoRepoUrl "https://dev.azure.com/org/proj/_git/repo"` |
| **CI/CD security (local fallback)** | `.\Invoke-AzureAnalyzer.ps1 -IncludeTools 'zizmor','gitleaks' -RepoPath "C:\repos\my-app"` |
| **Supply chain scan (local path)** | `.\Invoke-AzureAnalyzer.ps1 -IncludeTools 'trivy' -ScanPath "./src"` |

**Valid tool names:** `azqr`, `psrule`, `azgovviz`, `alz-queries`, `wara`, `maester`, `scorecard`, `ado-connections`, `identity-correlator`, `zizmor`, `gitleaks`, `trivy`

Use `-IncludeTools` OR `-ExcludeTools` (not both). The orchestrator throws if you specify both.

### What each tool does

| # | Tool | What it assesses | How it works |
|---|------|-----------------|-------------|
| 1 | **[azqr](https://azure.github.io/azqr)** | Azure resource compliance -- storage encryption, Key Vault config, App Service HTTPS, SQL auditing, 200+ checks | CLI scans a subscription and emits per-resource recommendations with severity |
| 2 | **[PSRule for Azure](https://azure.github.io/PSRule.Rules.Azure/)** | Infrastructure best practices -- managed disks, network isolation, diagnostic settings, WAF alignment | PowerShell module evaluates resources against 400+ rules, returns pass/fail per rule |
| 3 | **[AzGovViz](https://github.com/JulianHayward/Azure-MG-Sub-Governance-Reporting)** | Governance hierarchy -- management group structure, RBAC assignments, policy compliance, orphaned resources | PowerShell script crawls the tenant tree and reports governance anomalies |
| 4 | **[ALZ Queries](https://github.com/martinopedal/alz-graph-queries)** | Azure Landing Zone compliance -- 132 ARG queries from Azure review checklists covering networking, identity, compute, storage | Runs each query against Azure Resource Graph and checks the `compliant` column |
| 5 | **[WARA](https://github.com/Azure/Azure-Proactive-Resiliency-Library-v2)** | Reliability posture -- single points of failure, missing geo-replication, health probe config, zone redundancy | PSGallery module runs the Well-Architected Reliability Assessment collector |
| 6 | **Azure Cost (Consumption API)** | 30-day subscription spend + top 20 costly resources; folds `MonthlyCost` / `Currency` onto existing entities for blast-radius-weighted reporting | Read-only REST call to `Microsoft.Consumption/usageDetails`; no new role required |
| 7 | **Defender for Cloud** | Per-subscription Secure Score + non-healthy assessments (MFA, secure transfer, disk encryption, etc.); each recommendation folds onto the same AzureResource entity as azqr/PSRule | Read-only REST call to `Microsoft.Security/secureScores` + `/assessments`; graceful skip when Defender is not enabled |
| 8 | **[kubescape](https://github.com/kubescape/kubescape)** | AKS runtime posture — CIS Kubernetes Benchmark + NSA/CISA hardening controls run against each discovered AKS cluster via kubectl | CLI scans each cluster using an isolated per-cluster kubeconfig; each failing control folds onto the AKS cluster AzureResource entity |
| 9 | **[Maester](https://github.com/maester365/maester)** | Entra ID security configuration -- EIDSCA and CISA baseline compliance checks for identity posture | PowerShell module runs Pester tests against Microsoft Graph and tenant configuration |
| 10 | **[OpenSSF Scorecard](https://github.com/ossf/scorecard)** | Repository supply chain security -- branch protection, dependency pinning, CI/CD, commit signing practices | CLI scans a GitHub repository and scores security controls (0-10 per category) |
| 11 | **ADO Service Connections** | Azure DevOps service connection inventory -- connection types, authorization schemes, federation status, sharing | REST API queries ADO org/projects and catalogs all service endpoints with auth details |
| 12 | **[zizmor](https://github.com/woodruffw/zizmor)** | GitHub Actions workflow security -- expression injection, untrusted inputs, dangerous triggers, artipacked patterns | CLI scans workflow YAML files and reports security anti-patterns with severity |
| 13 | **[gitleaks](https://github.com/gitleaks/gitleaks)** | Secrets detection -- API keys, tokens, passwords, certificates committed in source code or git history | CLI scans the repository filesystem (or git log) for hardcoded secrets with regex patterns |
| 14 | **[Trivy](https://github.com/aquasecurity/trivy)** | Dependency vulnerability scanning -- CVEs in package-lock.json, requirements.txt, go.sum, pom.xml, and other manifests | CLI scans the filesystem (local or cloned remote repo) for known vulnerabilities in dependencies (CRITICAL/HIGH/MEDIUM/LOW) |
| 15 | **Identity Correlator** | Cross-dimensional identity correlation -- links service principals, managed identities, and app registrations across Azure / Entra / GitHub / ADO | In-process correlator (`modules/shared/IdentityCorrelator.ps1`) uses candidate reduction (no bulk SPN enumeration); emits Confirmed/Likely/Unconfirmed findings with evidence counts |

> **Note:** Scorecard supports GitHub Enterprise Cloud with Data Residency (GHEC-DR) and GitHub Enterprise Server (GHES). Use `-GitHubHost` to specify the enterprise hostname (e.g. `github.contoso.com`). Requires a `GITHUB_AUTH_TOKEN` valid on the enterprise instance. See the [Scorecard docs](https://github.com/ossf/scorecard#authentication) for details.

> **Note:** zizmor, gitleaks, and Trivy are cloud-first. When `-Repository` / `-AdoOrg` is provided they scan the **remote** repo via a vetted HTTPS clone (`modules/shared/RemoteClone.ps1`: allow-listed hosts github.com, dev.azure.com, `*.visualstudio.com`, `*.ghe.com`; auth tokens scrubbed from `.git/config` after clone). When neither is provided they fall back to scanning `-RepoPath` / `-ScanPath` on the local filesystem. gitleaks is invoked with `--redact` so report files never contain plaintext secrets.

## Schema reference

Azure Analyzer writes two JSON output files with different schemas:

- **`results.json`** -- v1 backward-compatible flat findings (10 fields per finding). This is the stable contract consumed by reports and downstream tooling.
- **`entities.json`** -- v3 entity-centric model. Groups findings by owning entity with aggregated metadata. Each entity's `Observations` array contains full v2 FindingRow objects (24 fields).

### results.json (v1 flat findings)

| Field | Type | Required | Description |
|---|---|---|---|
| `Id` | string | yes | Unique finding identifier |
| `Source` | string | yes | `azqr`, `psrule`, `azgovviz`, `alz-queries`, `wara`, `maester`, `scorecard`, `ado-connections`, `identity-correlator`, `zizmor`, `gitleaks`, or `trivy` |
| `Category` | string | | e.g. Security, Reliability, Networking, Compute, Storage, Identity |
| `Title` | string | yes | Short finding title |
| `Severity` | string | | `Critical`, `High`, `Medium`, `Low`, or `Info` |
| `Compliant` | boolean | yes | Whether the resource passes the check |
| `Detail` | string | | Detailed description of the finding |
| `Remediation` | string | | Steps to fix (may include URLs) |
| `ResourceId` | string | | Azure ARM resource ID (or repo URL for Scorecard) |
| `LearnMoreUrl` | string | | Link to Microsoft Learn documentation |

### entities.json (v3 entity model)

Each entry in `entities.json` represents a real-world resource (subscription, repo, user, app) with all observations aggregated:

| Field | Type | Description |
|---|---|---|
| `EntityId` | string | Canonical entity identifier (lowercase ARM ID, repo URL, or synthetic key) |
| `EntityType` | string | One of 12: `AzureResource`, `Subscription`, `ManagementGroup`, `ServicePrincipal`, `ManagedIdentity`, `Application`, `User`, `Tenant`, `Repository`, `Workflow`, `Pipeline`, `ServiceConnection` |
| `Platform` | string | `Azure`, `Entra`, `GitHub`, or `ADO` |
| `DisplayName` | string | Human-readable name for the entity |
| `SubscriptionId` | string | Azure subscription GUID (when applicable) |
| `SubscriptionName` | string | Human-readable subscription name |
| `ResourceGroup` | string | Azure resource group name |
| `ManagementGroupPath` | string[] | Management group hierarchy path |
| `ExternalIds` | object[] | Cross-platform identity links |
| `Observations` | object[] | Array of full v2 FindingRow objects (24 fields each -- see below) |
| `WorstSeverity` | string | Highest severity across all observations |
| `CompliantCount` | int | Number of compliant observations |
| `NonCompliantCount` | int | Number of non-compliant observations |
| `Sources` | string[] | Tools that contributed observations |
| `MonthlyCost` | number | Monthly cost (when cost data is available) |
| `Currency` | string | Cost currency code |
| `CostTrend` | object | Cost trend metadata |
| `Frameworks` | object[] | Compliance framework mappings |
| `Controls` | string[] | Control identifiers from compliance frameworks |
| `Policies` | object[] | Policy assignments |
| `Correlations` | object[] | Cross-dimension relationships |
| `Confidence` | string | `Confirmed`, `Likely`, `Unconfirmed`, or `Unknown` |
| `MissingDimensions` | string[] | Dimensions the tool could not assess |

### v2 FindingRow (24 fields -- used in entity Observations)

Normalizers produce v2 FindingRow objects internally. These appear as entries in each entity's `Observations` array in `entities.json`. The full field list is defined in `modules/shared/Schema.ps1`:

`Id`, `Source`, `Category`, `Title`, `Severity`, `Compliant`, `Detail`, `Remediation`, `ResourceId`, `LearnMoreUrl`, `EntityId`, `EntityType`, `Platform`, `Provenance` (`{ RunId, Source, RawRecordRef, Timestamp }`), `SubscriptionId`, `SubscriptionName`, `ResourceGroup`, `ManagementGroupPath`, `Frameworks`, `Controls`, `Confidence`, `EvidenceCount`, `MissingDimensions`, `SchemaVersion`

The v3 architecture uses shared schema v2 modules (`modules/shared/Schema.ps1`, `Canonicalize.ps1`, `EntityStore.ps1`) and a tool registry (`tools/tool-manifest.json`) for dual-model outputs. Phase 1 adds seven per-tool normalizers (`modules/normalizers/`) that convert v1 wrapper output to v3 FindingRow objects, and a manifest-driven orchestrator that reads `tool-manifest.json` to resolve eligible tools, run them in parallel via `Invoke-ParallelTools`, and feed normalized findings into the EntityStore pipeline.

## Permissions

All tools operate read-only. No write permissions required anywhere.

| Scope | What needs it |
|-------|--------------|
| **Azure Reader** | azqr, PSRule, AzGovViz, ALZ Queries, WARA, Azure Cost, Defender for Cloud |
| **Microsoft Graph** (read) | Maester -- Entra ID security |
| **GitHub token** (optional) | Scorecard -- repo security (recommended for rate limits) |
| **Local CLI only** (no cloud permissions) | zizmor, gitleaks, Trivy -- scan local filesystem |
| **Copilot license** (optional) | AI triage -- fully optional; only used with `-EnableAiTriage` flag |

See [PERMISSIONS.md](PERMISSIONS.md) for exact scopes, token types, setup commands, and troubleshooting.

---

## Roadmap

- **Azure DevOps pipeline security** -- ADO pipeline scanning (build/release definitions, variable groups, environments) is planned as a follow-up to the service connection scanner shipped in Phase 2 ([#48](https://github.com/martinopedal/azure-analyzer/issues/48)). Service connection inventory is live; compliance correlation (e.g. overprivileged SPNs, shared connections) comes next.

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
| ADO Service Connections | Native REST API scanner (no external dependency) | -- |
| zizmor | [woodruffw/zizmor](https://github.com/woodruffw/zizmor) | MIT |
| gitleaks | [gitleaks/gitleaks](https://github.com/gitleaks/gitleaks) | MIT |
| Trivy | [aquasecurity/trivy](https://github.com/aquasecurity/trivy) | Apache 2.0 |

## License

MIT
