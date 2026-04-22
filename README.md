# azure-analyzer

[![CI](https://github.com/martinopedal/azure-analyzer/actions/workflows/ci.yml/badge.svg)](https://github.com/martinopedal/azure-analyzer/actions/workflows/ci.yml)
[![CodeQL](https://github.com/martinopedal/azure-analyzer/actions/workflows/codeql.yml/badge.svg)](https://github.com/martinopedal/azure-analyzer/actions/workflows/codeql.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

**One PowerShell command, 37 read-only Azure assessment tools, one unified HTML and Markdown report.** Cloud-first by default: target remote GitHub and Azure DevOps repositories without cloning anything by hand.

## Sample Reports

- **[samples/sample-report.html](samples/sample-report.html)**, rendered HTML report with the framework coverage matrix, severity heatmap, top risks, and interactive findings exploration.
- **[samples/sample-report.md](samples/sample-report.md)**, Markdown report variant with the same posture summary, framework coverage, and detailed findings for Git-native review flows.

## What you get

- **Unified findings JSON** with Schema 2.2 metadata (severity, frameworks, MITRE mappings, remediation snippets, evidence URIs, entity references, deep links).
- **Interactive HTML report** with sortable findings tree, framework heatmap, CSV export.
- **Markdown report** for Git commit workflows.
- **Entity store** (JSON) with deduplicated cross-tool findings.
- **Optional local findings viewer scaffold** (`-Show`) that starts on `127.0.0.1` with a session token and health probe.

## Quickest start

```powershell
git clone https://github.com/martinopedal/azure-analyzer.git && cd azure-analyzer
Import-Module .\AzureAnalyzer.psd1
Connect-AzAccount -TenantId "<tenant-id>"
Invoke-AzureAnalyzer -SubscriptionId "<subscription-id>"  # outputs to output/, report.html, report.md
```

**[See docs/getting-started for installation, first run, and common scenarios &rarr;](docs/getting-started/)**

---

<details open><summary><b>Feature highlights</b></summary>

- **35 tools** across Azure (azqr, PSRule, Powerpipe, AzGovViz, Prowler, Defender for Cloud, ...), Entra (Maester, Identity Correlator, ...), GitHub (gitleaks, Trivy, Scorecard, zizmor), and Azure DevOps (pipeline security, service connections, repos).
- **Schema 2.2 metadata**: Frameworks, Pillar, Impact, Effort, DeepLinkUrl, RemediationSnippets, EvidenceUris, BaselineTags, MitreTactics, MitreTechniques, EntityRefs, ToolVersion.
- **Phase 0 foundation contract**: report architecture is selected with explicit thresholds and headroom, `output/report-manifest.json` captures picker and verification metadata, and normalizers can contribute edges through optional EdgeCollector introspection without breaking legacy signatures.
- **Read-only everywhere**. No write permissions on any cloud. See [PERMISSIONS.md](PERMISSIONS.md) for exact scopes.
- **HTML and Markdown reports** with executive summary, top recommendations, heatmap, framework coverage matrix, filtering, and CSV export.
- **Manifest-driven installer**: Run with `-InstallMissingModules` to auto-fetch prerequisites (PSGallery modules, allow-listed package managers, HTTPS-only git clones).
- **Pre-flight required-input resolution**: required tool inputs are collected before dispatch using `CLI > environment > prompt > fail-fast` with non-interactive safety.
- **Mandatory scanner-param prompts (#426)**: when a scanner is selected but its mandatory parameter is missing, `Read-MandatoryScannerParam` resolves it via env var (`AZURE_SUBSCRIPTION_ID`, `AZURE_TENANT_ID`, `ADO_ORG`, `GITHUB_REPOSITORY`, `AZUREANALYZER_REPO_PATH`) or interactive prompt. CI / `-NonInteractive` runs skip the scanner with a sanitized warning instead of failing late inside the underlying tool.

</details>

<details><summary><b>Tool catalog (37 tools)</b></summary>

See [docs/reference/tool-catalog.md](docs/reference/tool-catalog.md).

</details>

<details><summary><b>Tool output audit (Track D)</b></summary>

See [docs/tool-output-audit.md](docs/tool-output-audit.md) and [docs/tool-output-audit.json](docs/tool-output-audit.json) for per-tool wrapper-vs-normalizer field-coverage entries (audit-first input for #432b FindingRow extension).

</details>

<details><summary><b>All parameters and advanced usage</b></summary>

See [docs/reference/orchestrator-params.md](docs/reference/orchestrator-params.md) for every Invoke-AzureAnalyzer.ps1 parameter, plus scenario-specific grouping (subscription scan, repo scan, multi-tenant, CI/CD, Kubernetes).

</details>

<details><summary><b>For contributors and maintainers</b></summary>

See [docs/contributing/](docs/contributing/CONTRIBUTING.md) to add a new tool, extend the orchestrator, or contribute documentation. The [architecture docs](docs/architecture/) cover how azure-analyzer works under the hood, and design proposals belong under [docs/design/](docs/design/).

CI maintainers: the daily CI Health Digest reconciles triage status from both `ci-failure` issue bodies and their follow-up comments, so repeated `still failing` run URLs are not reported as untriaged duplicates.

</details>
