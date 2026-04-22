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
- **Read-only everywhere**. No write permissions on any cloud. See [PERMISSIONS.md](PERMISSIONS.md) for exact scopes.
- **HTML and Markdown reports** with executive summary, top recommendations, heatmap, framework coverage matrix, filtering, and CSV export.
- **Manifest-driven installer**: Run with `-InstallMissingModules` to auto-fetch prerequisites (PSGallery modules, allow-listed package managers, HTTPS-only git clones).

</details>

<details><summary><b>Tool catalog (37 tools)</b></summary>

See [docs/reference/tool-catalog.md](docs/reference/tool-catalog.md).

</details>

<details><summary><b>All parameters and advanced usage</b></summary>

See [docs/reference/orchestrator-params.md](docs/reference/orchestrator-params.md) for every Invoke-AzureAnalyzer.ps1 parameter, plus scenario-specific grouping (subscription scan, repo scan, multi-tenant, CI/CD, Kubernetes).

</details>

<details><summary><b>For contributors and maintainers</b></summary>

See [docs/contributing/](docs/contributing/CONTRIBUTING.md) to add a new tool, extend the orchestrator, or contribute documentation. The [architecture docs](docs/architecture/) cover how azure-analyzer works under the hood, and design proposals belong under [docs/design/](docs/design/).

CI maintainers: the daily CI Health Digest reconciles triage status from both `ci-failure` issue bodies and their follow-up comments, so repeated `still failing` run URLs are not reported as untriaged duplicates.

</details>
