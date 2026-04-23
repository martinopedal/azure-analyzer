# azure-analyzer

<<<<<<< HEAD
> **Active maintenance in progress (2026-04-23).** This repository is undergoing a comprehensive hardening sprint: CI workflow hygiene, wrapper consistency, E2E validation harness, and report architecture upgrades. Expect frequent commits on `main` and rapid iteration on internal docs. Markdown Link Check is currently advisory. This banner will be removed once the sprint closes and all open PRs land. For production use, pin to the latest tagged release.

=======

>>>>>>> f549853 (test(e2e): end-to-end harness for Invoke-AzureAnalyzer with 3-surface coverage)
[![CI](https://github.com/martinopedal/azure-analyzer/actions/workflows/ci.yml/badge.svg)](https://github.com/martinopedal/azure-analyzer/actions/workflows/ci.yml)
[![CodeQL](https://github.com/martinopedal/azure-analyzer/actions/workflows/codeql.yml/badge.svg)](https://github.com/martinopedal/azure-analyzer/actions/workflows/codeql.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

**One PowerShell command, 36 read-only assessment tools (+ 1 opt-in), one unified HTML and Markdown report.** Cloud-first by default: target remote GitHub and Azure DevOps repositories without cloning anything by hand.

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

## Testing

- `Invoke-Pester -Path .\tests -CI`: full Pester suite (baseline 842+ green).
- `Invoke-Pester -Path .\tests\e2e -Output Detailed`: end-to-end harness that drives `Invoke-AzureAnalyzer`'s output pipeline (FindingRow -> EntityStore -> `results.json` + `entities.json` -> HTML + Markdown reports) across three surfaces (Azure subscription, GitHub repo, Tenant / management-group) with synthetic fixtures under `tests/e2e/fixtures/`. Runs in CI via [`.github/workflows/e2e.yml`](.github/workflows/e2e.yml) on windows-latest, ubuntu-latest, and macos-latest (8-minute timeout per leg). Asserts v1 / v3.1 schema shapes, tier selection across PureJson / EmbeddedSqlite / SidecarSqlite, `Invoke-RemoteRepoClone` host allow-list, and credential-scrub for planted `ghp_*` / `xoxb-*` / `AKIA*` / `pat-*` literals.

---

<details open><summary><b>Feature highlights</b></summary>

- **36 tools** (+ 1 opt-in) across Azure (azqr, PSRule, Powerpipe, AzGovViz, Prowler, Defender for Cloud, ...), Entra (Maester, Identity Correlator, ...), GitHub (gitleaks, Trivy, Scorecard, zizmor), and Azure DevOps (pipeline security, service connections, repos).
- **Schema 2.2 metadata**: Frameworks, Pillar, Impact, Effort, DeepLinkUrl, RemediationSnippets, EvidenceUris, BaselineTags, MitreTactics, MitreTechniques, EntityRefs, ToolVersion.
- **Phase 0 foundation contract**: report architecture is selected with explicit thresholds and headroom, `output/report-manifest.json` captures picker and verification metadata, and normalizers can contribute edges through optional EdgeCollector introspection without breaking legacy signatures.
- **Read-only everywhere**. No write permissions on any cloud. See [PERMISSIONS.md](PERMISSIONS.md) for exact scopes.
- **HTML and Markdown reports** with executive summary, top recommendations, heatmap, framework coverage matrix, filtering, and CSV export.
- **Manifest-driven installer**: Run with `-InstallMissingModules` to auto-fetch prerequisites (PSGallery modules, allow-listed package managers, HTTPS-only git clones).
- **Pre-flight required-input resolution**: required tool inputs are collected before dispatch using `CLI > environment > prompt > fail-fast` with non-interactive safety.
- **Mandatory scanner-param prompts (#426)**: when a scanner is selected but its mandatory parameter is missing, `Read-MandatoryScannerParam` resolves it via env var (`AZURE_SUBSCRIPTION_ID`, `AZURE_TENANT_ID`, `ADO_ORG`, `GITHUB_REPOSITORY`, `AZUREANALYZER_REPO_PATH`) or interactive prompt. CI / `-NonInteractive` runs skip the scanner with a sanitized warning instead of failing late inside the underlying tool.
- **Opt-in LLM triage** scaffold: defaults to 3-model rubberduck consensus, supports explicit `-SingleModel` opt-out, and applies credential sanitization on prompt + response paths.

</details>

<details><summary><b>Tool catalog (36 enabled + 1 opt-in)</b></summary>

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

CodeQL (`Analyze (actions)`) now uses a global workflow concurrency queue to reduce GitHub App installation API throttling during PR bursts.

</details>

<details><summary><b>Environment variables</b></summary>azure-analyzer honours a small set of opt-in environment variables for CI / quiet-mode use:

- `AZURE_ANALYZER_NO_BANNER=1` — suppress the ASCII banner. Also auto-suppressed when `CI=true` or `GITHUB_ACTIONS=true`.
- `AZURE_ANALYZER_SUPPRESS_TOOL_MISSING_WARNINGS=1` — silence `<tool> is not installed. Skipping...` notices from every wrapper. Routes through `Write-Verbose` instead. Belt-and-suspenders kill-switch for noisy CI / Pester transcripts (#472). Truthy values: `1`, `true`, `yes`, `on` (case-insensitive).
- `AZURE_ANALYZER_ORCHESTRATED=1` (set automatically by `Invoke-AzureAnalyzer.ps1`) — tells wrappers they were launched by the orchestrator, not standalone.
- `AZURE_ANALYZER_EXPLICIT_TOOLS=trivy,gitleaks,...` (set automatically) — comma-separated CSV of tools the user named via `-IncludeTools`. Empty when no filter was passed.</details>
