# azure-analyzer

[![CI](https://github.com/martinopedal/azure-analyzer/actions/workflows/ci.yml/badge.svg)](https://github.com/martinopedal/azure-analyzer/actions/workflows/ci.yml)
[![CodeQL](https://github.com/martinopedal/azure-analyzer/actions/workflows/codeql.yml/badge.svg)](https://github.com/martinopedal/azure-analyzer/actions/workflows/codeql.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

**One PowerShell command, 35 read-only Azure assessment tools, one unified HTML and Markdown report.** Cloud-first by default: target remote GitHub and Azure DevOps repositories without cloning anything by hand.

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

Runs every tool whose prerequisites are present (azqr, PSRule for Azure, Powerpipe, AzGovViz, ALZ Resource Graph queries, WARA, Azure Cost, Azure Quota Reports, FinOps Signals, Application Insights, Azure Load Testing, AKS rightsizing, Defender for Cloud, Prowler) and writes findings to `output\` plus `report.html` and `report.md`. Azure Cost, Defender, Azure Quota Reports, FinOps, and Azure Load Testing findings now flow Schema 2.2 metadata end to end, including Pillar, Impact, Effort, DeepLinkUrl, EvidenceUris, BaselineTags, ScoreDelta, EntityRefs, and ToolVersion where available.

### 2. Scan a remote GitHub repository for CI/CD and secret hygiene

Cloud-first: pass an HTTPS URL, no manual clone needed.

```powershell
$env:GITHUB_AUTH_TOKEN = "<pat>"
Invoke-AzureAnalyzer -Repository "github.com/<org>/<repo>" -IncludeTools 'zizmor','gitleaks','scorecard','trivy'
```

The remote repo is fetched through `modules/shared/RemoteClone.ps1` (HTTPS-only, host allow-list, automatic token scrub) into a scratch path that is cleaned up at the end of the run. A local `-RepoPath "C:\repos\my-app"` fallback is available when working offline.
Scorecard findings include Schema 2.2 metadata (`Pillar`, `Frameworks`, `BaselineTags`, `ToolVersion`, `DeepLinkUrl`, `RemediationSnippets`, `EvidenceUris`) so HTML and Markdown reports render supply-chain context without placeholders.

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

- **35 tools** across Azure resources, Entra ID, GitHub, and Azure DevOps.
- **Unified v2.2 schema** with 5 severity levels (Critical, High, Medium, Low, Info), 16 entity types across 5 platforms (Azure, Entra, GitHub, ADO, AzureDevOps), and additive metadata fields (`Frameworks`, `Pillar`, `MitreTactics`, `MitreTechniques`, `EvidenceUris`, `BaselineTags`, `ToolVersion`).
- **Read-only everywhere.** No write permissions on any cloud. See [PERMISSIONS.md](PERMISSIONS.md) for exact scopes.
- **HTML + Markdown reports** with executive summary, top impact recommendations, heatmap, framework coverage matrix, filtering, control-framework chips, and CSV export.
- **Trivy now emits full Schema 2.2 ETL metadata** for CVEs and misconfigurations, including `Pillar`, `Impact`, `Effort`, `DeepLinkUrl`, `Frameworks` (`CVE`/`GHSA`/`CWE` + IaC check IDs), `RemediationSnippets` (before/after version bumps), `EvidenceUris`, `BaselineTags` (`CIS-DI-*` when Dockerfile checks provide them), `ScoreDelta` (CVSS), `EntityRefs`, and `ToolVersion`.
- **terraform-iac now emits full Schema 2.2 ETL metadata** from terraform validate and trivy config, including per-rule `Pillar`, `Frameworks`, `BaselineTags`, `DeepLinkUrl`, `RemediationSnippets`, `EvidenceUris`, `EntityRefs`, and `ToolVersion`, with IaC file entity IDs (`iac:terraform:{path}#{resource_address}`) for deterministic EntityStore dedup.
- **Sentinel incidents now emit Schema 2.2 security context** (`Pillar`, `ToolVersion`, `MitreTactics`, `MitreTechniques`, `Frameworks`, `DeepLinkUrl`, `EvidenceUris`, `EntityRefs`) so incident rows carry MITRE and entity-link evidence end to end.
- **ADO pipeline security now emits Schema 2.2 ETL context** (`RuleId`, `Pillar`, `Impact`, `Effort`, `DeepLinkUrl`, `RemediationSnippets`, `EvidenceUris`, `BaselineTags`, `EntityRefs`, `ToolVersion`) with BuildDefinition/ReleaseDefinition asset typing for graph dedup.
- **AKS rightsizing now emits Schema 2.2 performance and cost context** (`Pillar`, `Impact`, `Effort`, `DeepLinkUrl`, `RemediationSnippets`, `EvidenceUris`, `BaselineTags`, `ScoreDelta`, `EntityRefs`, `ToolVersion`) with workload-stable entity IDs for namespace/workload dedup in the entity store.
- **kube-bench now emits Schema 2.2 AKS hardening context** (`Frameworks`, `Pillar`, `Impact`, `DeepLinkUrl`, `RemediationSnippets`, `BaselineTags`, `EntityRefs`, `ToolVersion`) so CIS control findings preserve benchmark/profile metadata end to end.
- **Infracost now emits Schema 2.2 cost ETL metadata** (`Pillar=Cost`, `Impact`, `Effort`, `DeepLinkUrl`, `RemediationSnippets`, `EvidenceUris`, `BaselineTags`, `ScoreDelta`, `EntityRefs`, `ToolVersion`) and adds a v1 `ToolSummary` block (`currency`, total and baseline monthly cost, hourly cost, diff monthly cost, project name).
- **Maester now emits Schema 2.2 identity security context** (`Frameworks`, `Pillar`, `DeepLinkUrl`, `RemediationSnippets`, `EvidenceUris`, `BaselineTags`, `MitreTactics`, `MitreTechniques`, `EntityRefs`, `ToolVersion`) so Entra test findings preserve framework tags, MITRE mapping, remediation snippets, and scoped entity references.
- **Identity Correlator now emits Schema 2.2 identity attack-path context** (`Frameworks`, `Pillar`, `Impact`, `Effort`, `DeepLinkUrl`, `RemediationSnippets`, `EvidenceUris`, `BaselineTags`, `MitreTactics`, `MitreTechniques`, `EntityRefs`, `ToolVersion`) with NIST/CIS mappings, Entra deep links, and linked SPN or User entity refs.
- **Identity Graph Expansion now emits full Schema 2.2 identity graph context** (`Frameworks` with NIST and CIS controls, `Pillar=Security`, `Impact`, `Effort`, Entra `DeepLinkUrl`, `RemediationSnippets`, `EvidenceUris`, `BaselineTags`, `MitreTactics`, `MitreTechniques`, dense `EntityRefs`, `ToolVersion`) and propagates edge-linked entity refs in the normalizer for graph-aware triage.
- **Application Insights now emits Schema 2.2 reliability and performance context** (`Pillar`, `Impact`, `Effort`, `DeepLinkUrl`, `EvidenceUris`, `BaselineTags`, `ScoreDelta`, `EntityRefs`, `ToolVersion`) so telemetry regressions include portal evidence links and triage metadata.
- **ADO service connections now emit Schema 2.2 auth posture context** (`Pillar`, `Impact`, `Effort`, `DeepLinkUrl`, `RemediationSnippets`, `EvidenceUris`, `BaselineTags`, `EntityRefs`, `ToolVersion`) so connection inventory includes migration guidance and evidence links.
- **ADO pipeline consumption now emits Schema 2.2 cost-governance context** (`Pillar`, `Impact`, `Effort`, `DeepLinkUrl`, `EvidenceUris`, `BaselineTags`, `ScoreDelta`, `EntityRefs`, `ToolVersion`) for minute-share, duration-regression, fail-rate, and budget-overrun findings.
- **ADO pipeline correlator now emits Schema 2.2 blast-radius context** (`Pillar`, `Impact`, `Effort`, `DeepLinkUrl`, `RemediationSnippets`, `EvidenceUris`, `BaselineTags`, `EntityRefs`, `ToolVersion`) for build-to-secret correlation tracking.
- **gitleaks now emits Schema 2.2 secret-governance context** (`Frameworks`, `Pillar=Security`, `Impact`, `Effort`, `DeepLinkUrl`, `RemediationSnippets`, `EvidenceUris`, `BaselineTags`, `EntityRefs`, `ToolVersion`) with cloud-credential severity mapping (`Critical`) and repo-commit-workflow references for triage.
- **zizmor now emits Schema 2.2 workflow security context** (`RuleId`, `Pillar`, `Impact`, `Effort`, `DeepLinkUrl`, `RemediationSnippets`, `EvidenceUris`, `BaselineTags`, `MitreTechniques`, `EntityRefs`, `ToolVersion`) for GitHub workflow findings.
- **Bicep IaC validation now emits Schema 2.2 ETL metadata** (`Frameworks`, `Pillar`, `Impact`, `Effort`, `DeepLinkUrl`, `RemediationSnippets`, `EvidenceUris`, `BaselineTags`, `ScoreDelta`, `EntityRefs`, `ToolVersion`) with rule-aware baseline tags and file-anchor evidence URIs.
- **Falco now emits Schema 2.2 runtime threat context** (`Frameworks`, `Pillar=Security`, `Impact`, `Effort`, `DeepLinkUrl`, `RemediationSnippets`, `EvidenceUris`, `BaselineTags`, `MitreTactics`, `MitreTechniques`, `EntityRefs`, `ToolVersion`) with CIS Kubernetes benchmark mapping and ATT&CK technique tags for runtime alerts.
- **Azure Cost now emits Schema 2.2 FinOps context** (`Frameworks=FinOps Foundation`, `Pillar=CostOptimization`, `Impact`, `Effort`, Cost Management `DeepLinkUrl`, `RemediationSnippets`, `EvidenceUris`, `BaselineTags`, `ScoreDelta`, `EntityRefs`, `ToolVersion`) for subscription and top-resource spend findings.
- **ALZ Resource Graph Queries now emit Schema 2.2 governance context** (`Frameworks=ALZ`, `Pillar` mapped to Security or OperationalExcellence, `Impact`, `Effort`, `DeepLinkUrl`, `RemediationSnippets`, `EvidenceUris`, `BaselineTags`, `EntityRefs`, `ToolVersion`) with deep links back to the upstream `alz-graph-queries` source.
- **Manifest-driven installer.** Run with `-InstallMissingModules` to auto-install prerequisites (PSGallery modules, allow-listed package managers, HTTPS-only git clones).
- **ADO repo secret findings now emit full Schema 2.2 evidence context** (`Pillar`, `Impact`, `Effort`, `DeepLinkUrl`, `EvidenceUris`, `BaselineTags`, `EntityRefs`, `ToolVersion`) with commit and blob links plus line-aware dedup-safe titles.
- **Markdown link CI checks** on PRs that change `.md` files, plus a weekly scheduled link-rot sweep.

The full tool catalog, parameter reference, schema, scoped-run patterns, incremental-scan modes, and report internals all live in [docs/consumer/](docs/consumer/README.md). That index is the entry point for every advanced consumer page.

## More scenarios

The three quickstart scenarios above are the common path. The consumer index in [docs/consumer/](docs/consumer/README.md) covers the rest:

- Azure plus Entra identity (Maester) and cross-tenant identity-graph expansion
- GitHub Enterprise (GHEC-DR / GHES) targeting
- Azure DevOps Services and Azure DevOps Server pipeline, service-connection, repo-secret, and pipeline-consumption posture
- GitHub Actions billing and runner-minute cost telemetry with Schema 2.2 cost ETL metadata (`Pillar`, `Impact`, `Effort`, `DeepLinkUrl`, `ScoreDelta`, `EvidenceUris`, `BaselineTags`, `EntityRefs`, `ToolVersion`)
- Sentinel coverage and active incidents
- AzGovViz governance findings with Schema 2.2 enrichments (`Pillar`, `Frameworks` for ALZ and CAF controls, `Impact`, `Effort`, `DeepLinkUrl` to source policy context, `RemediationSnippets`, `EvidenceUris`, `BaselineTags`, `EntityRefs`, `ToolVersion`)
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
| Azure **Reader** | azqr, PSRule, Powerpipe, AzGovViz, ALZ Queries, WARA, Azure Cost, Azure Quota Reports, FinOps Signals, App Insights, Defender for Cloud |
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

## ALZ queries

The `alz-queries` tool runs a curated set of Azure Resource Graph (ARG) queries that check landing-zone compliance and drift against CIS Azure, NIST 800-53, Azure WAF, and Azure CAF.

- **Canonical source of truth:** [martinopedal/alz-graph-queries](https://github.com/martinopedal/alz-graph-queries). That repo owns the query schema, the query set, and the validation tooling (`Validate-Queries.ps1`, `Validate-KqlSyntax.ps1`, Pester suite).
- **Local cache:** the `queries/alz/` folder in this repo (`queries/alz/alz_additional_queries.json`) is a snapshot of the upstream JSON. `modules/Invoke-AlzQueries.ps1` reads it directly via `Search-AzGraph`. Each query MUST return a boolean `compliant` column; see the upstream repo for the full schema.
- **Provenance:** queries derive from [Azure/review-checklists](https://github.com/Azure/review-checklists). The full chain is documented in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
- **Sync workflow (in flight):** `scripts/Sync-AlzQueries.ps1` (see issue #315) will pull the latest queries from upstream into `queries/`, replacing the manual copy step. Until that lands, refresh by cloning [alz-graph-queries](https://github.com/martinopedal/alz-graph-queries) and copying `alz_additional_queries.json` into `queries/`.

Manifest pin: `tools/tool-manifest.json` -> `alz-queries.upstream.repo` points at `martinopedal/alz-graph-queries`.

## Contributing

- [CONTRIBUTING.md](CONTRIBUTING.md): fork / branch / PR workflow, docs-update rule, signed-commit policy.
- [docs/contributor/README.md](docs/contributor/README.md): architecture, adding a new tool, AI governance, and forward-looking proposals.
- [docs/contributor/ARCHITECTURE.md](docs/contributor/ARCHITECTURE.md): module layout, normalizer contract, EntityStore design.
- [docs/contributor/adding-a-tool.md](docs/contributor/adding-a-tool.md): end-to-end guide for registering a new analyzer tool in `tools/tool-manifest.json`.
- `scripts/Sync-AlzQueries.ps1`: manifest-driven sync of canonical `queries/alz/alz_additional_queries.json` from the `alz-queries` upstream repo (`-DryRun` supported).
- Docs Check note: stacked PR titles formatted as `(PR-x of y)` skip docs enforcement until the final part, while missing docs errors now emit explicit `error:` lines for CI triage.
- Redirect stub deadlines are enforced by `.squad/stub-deadlines.json` + `scripts/Check-StubDeadline.ps1` (CI workflow: `stub-deadline-check.yml`).

The Pester baseline must stay green: `Invoke-Pester -Path .\tests -CI`. Wrapper suites include deep Azure Quota coverage (subscription/region fanout, retry semantics, sanitizer paths, and strict v1 envelope assertions) backed by realistic Azure CLI fixtures.

## Security

Read-only by design, with a defense-in-depth posture across the codebase: HTTPS-only outbound, host allow-lists, package-manager allow-lists, 300s external-process timeouts, credential scrubbing on all written output, SHA-256-pinned tool binaries, and a CycloneDX 1.5 SBOM per release. Report vulnerabilities via [SECURITY.md](SECURITY.md).

AKS Karpenter cost findings now carry Schema 2.2 cost context (`Pillar`, `Impact`, `Effort`, `DeepLinkUrl`, `RemediationSnippets`, `EvidenceUris`, `BaselineTags`, `ScoreDelta`, `EntityRefs`, `ToolVersion`) from wrapper to normalizer.

## License

MIT. See [LICENSE](LICENSE) and [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for the full set of upstream-tool licenses and attributions.
