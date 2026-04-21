# azure-analyzer

[![CI](https://github.com/martinopedal/azure-analyzer/actions/workflows/ci.yml/badge.svg)](https://github.com/martinopedal/azure-analyzer/actions/workflows/ci.yml)
[![CodeQL](https://github.com/martinopedal/azure-analyzer/actions/workflows/codeql.yml/badge.svg)](https://github.com/martinopedal/azure-analyzer/actions/workflows/codeql.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

**One PowerShell command, 33 read-only Azure assessment tools, one unified HTML and Markdown report.** Cloud-first by default: target remote GitHub and Azure DevOps repositories without cloning anything by hand.

## What does the output look like?

Two sample reports built from the same illustrative scan (tenant `contoso-prod`, 17 tools, 222 findings):

- **[samples/sample-report.html](samples/sample-report.html)** - interactive single-file HTML with a sortable findings table, control-domain heat map, tool coverage grid, top-risks panel, and a dark mode toggle. Open it locally in any browser; no server, no CDN, no JavaScript dependencies.
- **[samples/sample-report.md](samples/sample-report.md)** - the same scan rendered as GitHub-Flavored Markdown for pasting into PRs, issues, and email digests.

## Install

```powershell
git clone https://github.com/martinopedal/azure-analyzer.git
cd azure-analyzer
Import-Module .\AzureAnalyzer.psd1
```

PSGallery (preferred once published):

```powershell
Install-Module AzureAnalyzer   # coming in vNEXT once published to PSGallery
Import-Module AzureAnalyzer
```

> The `Install-Module` path is the planned canonical install once we publish to the PowerShell Gallery (PR-4 of the docs/restructure stream made the manifest publish-ready). Until then, use the `git clone + Import-Module .\AzureAnalyzer.psd1` form above.

## Quickstart

Three scenarios that cover the majority of consumer use:

### 1. Run a full Azure assessment for a subscription

```powershell
Connect-AzAccount -TenantId "<tenant-id>"
Invoke-AzureAnalyzer -SubscriptionId "<subscription-id>"
```

Runs every tool whose prerequisites are present (azqr, PSRule for Azure, AzGovViz, ALZ Resource Graph queries, WARA, Azure Cost, Azure Quota Reports, FinOps Signals, Application Insights, Azure Load Testing, AKS rightsizing, Defender for Cloud) and writes findings to `output\` plus `report.html` and `report.md`.

### 2. Scan a remote GitHub repository for CI/CD and secret hygiene

Cloud-first: pass an HTTPS URL, no manual clone needed.

```powershell
$env:GITHUB_AUTH_TOKEN = "<pat>"
Invoke-AzureAnalyzer -Repository "github.com/<org>/<repo>" -IncludeTools 'zizmor','gitleaks','scorecard','trivy'
```

The remote repo is fetched through `modules/shared/RemoteClone.ps1` (HTTPS-only, host allow-list, automatic token scrub) into a scratch path that is cleaned up at the end of the run. A local `-RepoPath "C:\repos\my-app"` fallback is available when working offline.

### 3. Generate an HTML report from an existing run

`Invoke-AzureAnalyzer` produces `report.html` automatically. To re-render after editing findings, or to build a report from a previous run's `results.json`:

```powershell
Import-Module .\AzureAnalyzer.psd1
New-HtmlReport -InputPath .\output\results.json -OutputPath .\output\report.html
New-MdReport   -InputPath .\output\results.json -OutputPath .\output\report.md
```

`New-HtmlReport.ps1` renders the HTML report directly. There is no separate checked-in HTML template to maintain or customize.

The HTML report includes an executive Summary tab, a Top recommendations by impact panel (RuleId-first grouping with fallback), a severity-by-resource-group heatmap, a Framework Coverage matrix (framework x tool with click-to-filter), a sticky severity strip (Critical, High, Medium, Low, Info, Total), a collapsible Tool -> Category -> Rule -> Finding tree with persisted expand state, a global filter bar (severity, framework, platform, tool, free text), and a CSV export of the currently filtered view.

## What you get

- **33 tools** across Azure resources, Entra ID, GitHub, and Azure DevOps.
- **Unified v2 schema** with 5 severity levels (Critical, High, Medium, Low, Info) and 14 entity types across 4 platforms (Azure, Entra, GitHub, ADO).
- **Read-only everywhere.** No write permissions on any cloud. See [PERMISSIONS.md](PERMISSIONS.md) for exact scopes.
- **HTML + Markdown reports** with executive summary, top impact recommendations, heatmap, framework coverage matrix, filtering, control-framework chips, and CSV export.
- **Manifest-driven installer.** Run with `-InstallMissingModules` to auto-install prerequisites (PSGallery modules, allow-listed package managers, HTTPS-only git clones).
- **Markdown link CI checks** on PRs that change `.md` files, plus a weekly scheduled link-rot sweep.

The full tool catalog, parameter reference, schema, scoped-run patterns, incremental-scan modes, and report internals all live in [docs/consumer/](docs/consumer/README.md). That index is the entry point for every advanced consumer page.

## More scenarios

The three quickstart scenarios above are the common path. The consumer index in [docs/consumer/](docs/consumer/README.md) covers the rest:

- Azure plus Entra identity (Maester) and cross-tenant identity-graph expansion
- GitHub Enterprise (GHEC-DR / GHES) targeting
- Azure DevOps Services and Azure DevOps Server pipeline, service-connection, repo-secret, and pipeline-consumption posture
- GitHub Actions billing and runner-minute cost telemetry
- Sentinel coverage and active incidents
- Application Insights performance signals (slow requests, dependency failures, exception clusters)
- Azure Load Testing failed and regressed runs
- AKS rightsizing via Container Insights utilization signals
- AKS runtime posture (kubescape, falco, kube-bench)
- Multi-tenant fan-out for MSPs and large enterprises
- Continuous control on a schedule (GitHub Actions or Azure Function App, with OIDC)
- Tuning gitleaks rule patterns: [docs/consumer/gitleaks-pattern-tuning.md](docs/consumer/gitleaks-pattern-tuning.md)

## Permissions at a glance

All tools run **read-only**. Most common scopes:

| Scope | Used by |
|-------|---------|
| Azure **Reader** | azqr, PSRule, AzGovViz, ALZ Queries, WARA, Azure Cost, Azure Quota Reports, FinOps Signals, App Insights, Defender for Cloud |
| **Cost Management Reader** (recommended) | FinOps Signals, Azure Cost |
| Microsoft **Graph** (read) | Maester (Entra ID) |
| **GitHub PAT** (optional) | Scorecard, GitHub Actions Billing, remote repo scans |
| **Azure DevOps PAT** (optional) | ADO Service Connections, Pipeline Security, Pipeline Consumption, Repo Secrets, Pipeline Correlator |
| Local CLI only (no cloud) | zizmor, gitleaks, Trivy on a local path |

Full breakdown, token types, and setup commands: [PERMISSIONS.md](PERMISSIONS.md).

## Continuous control

Run azure-analyzer on a schedule and stream findings to Log Analytics or open issues on net-new Critical findings only.

- [docs/consumer/continuous-control.md](docs/consumer/continuous-control.md): 10-minute deployment walkthrough (Function App on Consumption or Premium, OIDC federated credentials, optional Bicep template).
- [docs/consumer/sinks/log-analytics.md](docs/consumer/sinks/log-analytics.md): streaming findings into Azure Log Analytics via DCE / DCR.

## AI-assisted triage (optional)

`-EnableAiTriage` adds AI-assisted finding summaries when a Copilot or Azure OpenAI endpoint is configured. Fully optional, off by default. See [docs/consumer/ai-triage.md](docs/consumer/ai-triage.md).

## Contributing

- [CONTRIBUTING.md](CONTRIBUTING.md): fork / branch / PR workflow, docs-update rule, signed-commit policy.
- [docs/contributor/README.md](docs/contributor/README.md): architecture, adding a new tool, AI governance, and forward-looking proposals.
- [docs/contributor/ARCHITECTURE.md](docs/contributor/ARCHITECTURE.md): module layout, normalizer contract, EntityStore design.
- [docs/contributor/adding-a-tool.md](docs/contributor/adding-a-tool.md): end-to-end guide for registering a new analyzer tool in `tools/tool-manifest.json`.
- `scripts/Sync-AlzQueries.ps1`: manifest-driven sync of canonical `queries/alz_additional_queries.json` from the `alz-queries` upstream repo (`-DryRun` supported).
- Docs Check note: stacked PR titles formatted as `(PR-x of y)` skip docs enforcement until the final part, while missing docs errors now emit explicit `error:` lines for CI triage.
- Redirect stub deadlines are enforced by `.squad/stub-deadlines.json` + `scripts/Check-StubDeadline.ps1` (CI workflow: `stub-deadline-check.yml`).

The Pester baseline must stay green: `Invoke-Pester -Path .\tests -CI`.

## Security

Read-only by design, with a defense-in-depth posture across the codebase: HTTPS-only outbound, host allow-lists, package-manager allow-lists, 300s external-process timeouts, credential scrubbing on all written output, SHA-256-pinned tool binaries, and a CycloneDX 1.5 SBOM per release. Report vulnerabilities via [SECURITY.md](SECURITY.md).

## License

MIT. See [LICENSE](LICENSE) and [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for the full set of upstream-tool licenses and attributions.
