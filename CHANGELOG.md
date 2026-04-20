# Changelog

All notable changes to azure-analyzer will be documented here.

## [Unreleased]

### Added

- **K8s wrappers + orchestrator: explicit `-KubeconfigPath`, `-KubeContext`, and per-tool namespace params (closes #240).**
  Adds `-KubeconfigPath`, `-KubeContext`, `-KubescapeNamespace`, `-FalcoNamespace`, `-KubeBenchNamespace` to `Invoke-AzureAnalyzer.ps1` (top-level) and `-KubeconfigPath`, `-KubeContext`, `-Namespace` to `Invoke-Kubescape.ps1`, `Invoke-Falco.ps1`, and `Invoke-KubeBench.ps1`. When a kubeconfig path is provided the wrappers skip Azure Resource Graph discovery and `az aks get-credentials`, scanning a single cluster reachable via the supplied kubeconfig (kubeconfig mode). Default behavior is unchanged: with no new params supplied, every wrapper continues to discover AKS managed clusters via ARG and fetch per-cluster credentials. Validation rejects URL-style values and missing files at the wrapper boundary with sanitized errors. Per-wrapper namespace defaults: kubescape `''` (all namespaces), falco `'falco'`, kube-bench `'kube-system'`. Tests: `tests/wrappers/Invoke-Kubescape.Tests.ps1`, `tests/wrappers/Invoke-Falco.Tests.ps1`, `tests/wrappers/Invoke-KubeBench.Tests.ps1`, `tests/orchestrator/AzureAnalyzer-K8sParams.Tests.ps1`, fixture `tests/fixtures/kubeconfig-mock.yaml`. Phase 1 of parent issue #236; clears the way for #241/#242 (additional K8s auth modes).

### Fixed

- docs: update README tool count to 27 to match current manifest (closes #235)
- ci: improved CI failure watchdog error extraction to prioritize GitHub Actions annotations (`##[error]`, `::error::`) and fall back to broader exception/exit-code patterns so ci-failure issues include actionable first error lines.
- fix(ci): prevent docs-check from re-firing + watchdog hash dedupe (closes #266)

### Permissions documentation split (closes #252)

- **docs: split PERMISSIONS.md per-tool detail to `docs/consumer/permissions/<tool>.md`**. The root `PERMISSIONS.md` is now a 116-line summary plus a manifest-driven per-tool index (down from 867 lines); detailed permission tables, sample commands, and "what it does / does not do" prose for each tool live in dedicated pages under `docs/consumer/permissions/`. Cross-cutting topics (Continuous Control OIDC + MI, multi-tenant fan-out, MG recursion, auth troubleshooting, the cross-tool matrix) were extracted to `_*.md` companion pages in the same folder. Squad automation that hardcodes the `PERMISSIONS.md` path keeps working unchanged.
- **scripts/Generate-PermissionsIndex.ps1**: new manifest-driven generator that rewrites the INDEX section of `PERMISSIONS.md` between `<!-- BEGIN INDEX -->` / `<!-- END INDEX -->` markers and verifies a `docs/consumer/permissions/<name>.md` page exists for every enabled tool.
- **tests/scripts/Generate-PermissionsIndex.Tests.ps1**: Pester coverage for the generator (markers present, per-tool pages exist, idempotent regeneration, `-CheckOnly` is green on a clean tree).
- **`permissions-pages-fresh` CI gate** added to `.github/workflows/docs-check.yml`, mirroring the `tool-catalog-fresh` pattern.

### Removed

- Removed orphaned `report-template.html`; HTML reports are rendered directly by `New-HtmlReport.ps1`, and the unused static scaffold no longer ships in the repo (closes #249).

### Added

- ci: add markdown link-check workflow (advisory, weekly + PR path filter) (closes #251)
- feat(reports): per-category severity totals strip in Findings with click-to-filter and sticky visibility; includes Critical, High, Medium, Low, Info, and Total (closes #226)
- feat: Infracost wrapper for Bicep/Terraform pre-deploy cost (closes #233)
- feat: Azure Load Testing wrapper for failed and regressed test runs (closes #238)
  - Added `modules/Invoke-AzureLoadTesting.ps1` with 30-day default lookback, failed and cancelled run detection (High), regression detection across response time p95, error rate, and requests per second (Medium, default threshold 10%), and optional healthy-run info findings.
  - Added `modules/normalizers/Normalize-AzureLoadTesting.ps1` to convert wrapper output into v2 FindingRow records via `New-FindingRow` with `EntityType=AzureResource`.
  - Registered new `loadtesting` tool in `tools/tool-manifest.json` (`provider=azure`, `scope=subscription`) with manifest-driven install metadata.
  - Added test coverage and fixtures: `tests/wrappers/Invoke-AzureLoadTesting.Tests.ps1`, `tests/normalizers/Normalize-AzureLoadTesting.Tests.ps1`, and `tests/fixtures/loadtesting/loadtesting-output.json`.
  - Added per-tool permission documentation at `docs/consumer/permissions/loadtesting.md` and updated consumer docs and generated tool catalogs.

### Consumer-first documentation restructure

The documentation now leads with the consumer experience, keeps advanced operator and contributor material under dedicated indexes, and leaves short redirect stubs at the old paths so existing links keep working during the transition. The same stream also made module consumption safer, generated the tool catalog from the manifest, and aligned the root README with the new consumer-first quickstart flow. This entry consolidates PRs #243, #244, #246, #247, and #253.

#### Moved

| Old path | New path |
| --- | --- |
| `AI_GOVERNANCE.md` | `docs/contributor/ai-governance.md` |
| `docs/ARCHITECTURE.md` | `docs/contributor/ARCHITECTURE.md` |
| `docs/CONTRIBUTING-TOOLS.md` | `docs/contributor/adding-a-tool.md` |
| `docs/ai-triage.md` | `docs/consumer/ai-triage.md` |
| `docs/continuous-control.md` | `docs/consumer/continuous-control.md` |
| `docs/future-iac-drift.md` | `docs/contributor/proposals/iac-drift.md` |
| `docs/gitleaks-pattern-tuning.md` | `docs/consumer/gitleaks-pattern-tuning.md` |
| `docs/proposals/copilot-triage-panel.md` | `docs/contributor/proposals/copilot-triage-panel.md` |
| `docs/sinks/log-analytics.md` | `docs/consumer/sinks/log-analytics.md` |

#### Added

- `docs/consumer/` as the consumer-facing documentation home.
- `docs/contributor/` as the contributor and operator documentation home.
- `scripts/Generate-ToolCatalog.ps1` for manifest-driven tool catalog generation.
- `tests/module/Import-AzureAnalyzer.Tests.ps1` for module import, exported command, and manifest validation coverage.
- `tests/scripts/Generate-ToolCatalog.Tests.ps1` for tool catalog generation coverage.
- Manifest hygiene in `AzureAnalyzer.psd1`, including the `PrivateData.PSData` block and GUID rotation.
- The `tool-catalog-fresh` CI gate that checks generated catalog freshness.

#### Fixed

- `AzureAnalyzer.psm1` root-path resolution for `Import-Module .\AzureAnalyzer.psd1` consumption.
- `docs-check.yml` now skips docs enforcement for non-final stacked PRs titled `(PR-x of y)` and emits explicit `error:` lines when docs are missing so CI-failure triage can extract the first error reliably.

#### Stub deadline

- Redirect stubs at the old paths stay in place through the `1.0.x` line and will be removed in `v1.1.0`, the next minor version bump.

#### Enforcement

- chore: enforce stub-deadline removal via `.squad/stub-deadlines.json` + `scripts/Check-StubDeadline.ps1` + `.github/workflows/stub-deadline-check.yml` + `tests/scripts/Check-StubDeadline.Tests.ps1` (closes #250)

## [Unreleased - earlier entries]

### Fixed (earlier)
- **gitleaks false-success on failure**: Check `$LASTEXITCODE` after gitleaks runs. Non-zero exit with no report now returns Status='Failed'. Invalid report JSON also returns Failed instead of silently succeeding with empty findings.
- **gitleaks writes raw secrets to disk in repo**: Report file is now written to `[System.IO.Path]::GetTempPath()` instead of inside the scanned repository. Secret/Match fields are stripped from parsed JSON before creating findings. Temp file is cleaned up in a finally block.
- **gitleaks report contained plaintext secrets**: Added `--redact` flag to gitleaks CLI invocation so the report file never contains raw secret values. The existing Secret/Match field stripping is retained as defense-in-depth.
- **zizmor parse failures return success**: JSON parse failure now returns Status='Failed' instead of Success with empty findings. Checks `$LASTEXITCODE` for non-zero exit codes.
- **zizmor stderr mixed into JSON stream**: Uses `--output` flag to write JSON to a temp file instead of capturing stdout. stderr is kept separate and logged via Write-Verbose.
- **trivy stderr/stdout mixing corrupts JSON**: Uses `--output` flag to write JSON to a temp file instead of capturing stdout directly. stderr is kept separate and logged via Write-Verbose. Temp file is cleaned up in a finally block.

### Added
- **trivy minimum version check**: `Invoke-Trivy.ps1` now runs `trivy --version`, parses the version number, and warns if below the minimum known-safe version (0.50.0). Includes guidance to download from official GitHub releases only.

### Added
- **Phase 3: CI/CD security tools (zizmor, gitleaks, Trivy)**: Three new local CLI tools for repository security scanning, all operating read-only on the local filesystem with no cloud permissions required.
- **zizmor integration (tool #9)**: `modules/Invoke-Zizmor.ps1` wrapper scans GitHub Actions workflow YAML files for security anti-patterns (expression injection, untrusted inputs, dangerous triggers). Normalizer maps findings to Platform=GitHub, EntityType=Workflow.
- **gitleaks integration (tool #10)**: `modules/Invoke-Gitleaks.ps1` wrapper scans the repository for hardcoded secrets (API keys, tokens, passwords). Normalizer maps findings to Platform=GitHub, EntityType=Repository.
- **Trivy integration (tool #11)**: `modules/Invoke-Trivy.ps1` wrapper scans the filesystem for dependency vulnerabilities in package manifests (package-lock.json, requirements.txt, go.sum, pom.xml, etc.). Maps trivy severity (CRITICAL/HIGH/MEDIUM/LOW) to schema severity. Each CVE = one finding with CVE ID + package name as title. Normalizer in `modules/normalizers/Normalize-Trivy.ps1` with Platform=GitHub, EntityType=Repository.
- **`-RepoPath` parameter**: New parameter on `Invoke-AzureAnalyzer.ps1` for local repo scanning. zizmor and gitleaks use this path (defaults to current directory). Separate from `-Repository` (GitHub URL for Scorecard).
- **`-ScanPath` and `-ScanType` parameters**: New parameters on `Invoke-AzureAnalyzer.ps1` for Trivy. `-ScanPath` sets the filesystem path to scan (default: current directory). `-ScanType` selects `fs` (filesystem, default) or `repo` (remote repository).
- **Workflow EntityType**: Added `Workflow` to schema v2 EntityTypes with Platform=GitHub mapping. Used by zizmor normalizer to distinguish workflow files from repository-level findings.
- **CLI-provider orchestrator support**: Repository-scoped tools with `provider=cli` in the manifest now run automatically without requiring `-Repository`. They scan the local filesystem and are always eligible when enabled.
- **Phase 3 manifest entries**: zizmor, gitleaks, and trivy added to `tools/tool-manifest.json` with provider=cli, scope=repository.
- **Phase 3 normalizer tests**: Pester test suites for Normalize-Zizmor, Normalize-Gitleaks, and Normalize-Trivy with fixture-driven validation covering schema conversion, entity ID normalization, severity mapping, field preservation, provenance tracking, and error handling.

### Fixed
- **`$host` reserved variable crash**: Renamed `$host` to `$repoHost` in `Normalize-Scorecard.ps1` to avoid StrictMode crash (System.Management.Automation.Internal.Host.InternalHost is read-only).
- **Identity correlator never invoked**: Correlators (type=correlator in manifest) now run in a post-collection stage after all parallel tools complete and EntityStore is populated, instead of running as a script in the parallel loop. The orchestrator dot-sources the correlator script and calls `Invoke-IdentityCorrelation` directly.
- **Candidate alias merge for objectId/appId**: Added `Merge-CandidateAliases` function to `IdentityCorrelator.ps1`. After initial candidate extraction, candidates keyed by objectId are merged into their appId counterpart when both refer to the same identity, eliminating false-negative splits.
- **ADO scanner pagination**: `Get-AdoProjects` and `Get-AdoServiceConnections` now use continuation-token loops (`$top=100`) to handle orgs with >100 projects or connections. Per-project failures are tracked; when some projects fail, the wrapper returns `Status='PartialSuccess'` with a message listing failed projects.
- **`$entities.Count` null crash under StrictMode**: Added explicit null guard (`if ($null -eq $entities) { $entities = @() }`) before accessing `.Count` on the Export-Entities result in `Invoke-AzureAnalyzer.ps1`.

### Added
- **ADO service connection scanner**: New `modules/Invoke-ADOServiceConnections.ps1` wrapper queries Azure DevOps REST API to inventory service connections across an organization. Returns connection type, authorization scheme (ServicePrincipal, ManagedServiceIdentity, WorkloadIdentityFederation), and sharing status. All findings are informational (Compliant=true, Severity=Info) -- compliance correlation comes in a later phase.
- **ADO connections normalizer**: `modules/normalizers/Normalize-ADOConnections.ps1` converts raw ADO findings to v3 FindingRow format with Platform=ADO, EntityType=ServiceConnection, and canonical IDs in `ado://org/project/serviceconnection/name` format.
- **`-AdoOrg` and `-AdoProject` parameters**: New parameters on `Invoke-AzureAnalyzer.ps1` to enable ADO-scoped tools. ADO tools only run when `-AdoOrg` is provided. When `-AdoProject` is omitted, all projects in the organization are scanned.
- **ADO tool manifest entry**: `ado-connections` added to `tools/tool-manifest.json` with provider=ado, scope=ado.
- **ADO normalizer tests**: Pester test suite for Normalize-ADOConnections with fixture-driven validation covering schema conversion, canonical ID normalization, field preservation, error handling, and provenance tracking.

### Added
- **GHEC-DR and GHES support**: New `-GitHubHost` parameter on `Invoke-AzureAnalyzer.ps1` and `Invoke-Scorecard.ps1` sets the `GH_HOST` environment variable for the Scorecard CLI, enabling scans against GitHub Enterprise Cloud with Data Residency and GitHub Enterprise Server instances. Canonical entity IDs now use the actual host instead of hardcoding `github.com`. Backward compatible -- omitting `-GitHubHost` defaults to github.com.
- **Identity correlator v0**: Cross-dimensional identity correlation engine (`modules/shared/IdentityCorrelator.ps1`) that maps service principals, managed identities, and app registrations across Azure, Entra, GitHub, and ADO dimensions. Uses candidate reduction (never bulk-enumerates SPNs). Opt-in Graph enrichment via `-IncludeGraphLookup` for federated identity credential lookups. Confidence scoring: Confirmed (3+ dimensions), Likely (2), Unconfirmed (name-only). Includes normalizer passthrough, tool manifest entry, and Pester tests.

### Fixed
- **README schema table**: Split into three sections: `results.json` (v1 backward-compatible, 10 fields), `entities.json` (v3 entity model), and `v2 FindingRow` (24 fields used in entity Observations). Previously documented all 24 fields as the results.json format.
- **Sample results.json**: Stripped to the 10-field v1 format that the orchestrator actually writes to results.json (removed EntityId, EntityType, Platform, Provenance, SubscriptionId, SubscriptionName, ResourceGroup, ManagementGroupPath, Frameworks, Controls, Confidence, EvidenceCount, MissingDimensions, SchemaVersion).
- **Sample entities.json**: Replaced FindingId mini-records in Observations with full v2 FindingRow objects matching actual EntityStore output.
- **ARCHITECTURE.md AzGovViz entity type**: Updated from single `AzureResource` to `ManagementGroup / Subscription / AzureResource` with contextual typing note.
- **ARCHITECTURE.md WARA normalizer filename**: Corrected `Normalize-Wara.ps1` to `Normalize-WARA.ps1` matching actual file.
- **ARCHITECTURE.md report stage**: Replaced stale `report-model.json` reference with actual inputs (results.json, entities.json, tool-status.json).
- **CONTRIBUTING-TOOLS.md normalizer paths**: Updated `modules/Normalize-{ToolName}.ps1` to `modules/normalizers/Normalize-{ToolName}.ps1`. Fixed manifest example to use function-name normalizer field. Fixed test example to use `-ToolResult` parameter.
- **Em-dashes**: Replaced em-dashes with `--` in ARCHITECTURE.md and CONTRIBUTING-TOOLS.md.

### Added
- **CONTRIBUTING.md normalizer workflow**: Added "Adding a new tool" section describing the three-component workflow (collector, normalizer, manifest entry) with link to CONTRIBUTING-TOOLS.md.
- **README Roadmap section**: Added roadmap with planned ADO pipeline security scanning (issue #48) and GHEC/GHES compatibility note for Scorecard.
- **Phase 1 normalizers**: Seven normalizer functions in `modules/normalizers/` that convert raw tool output (v1) to schema v3 FindingRow format. Each normalizer parses ARM ResourceIds, extracts subscription and resource group context, and maps platform/entity-type per tool.
- **Phase 1 manifest-driven plugin model**: `tools/tool-manifest.json` drives tool registration and execution. Orchestrator loads manifest to resolve eligible tools and call corresponding collector and normalizer scripts.
- **Phase 1 dual output model**: Parallel output streams produce both `entities.json` (entity-centric observations) and `results.json` (backward-compatible flat findings). Normalizers feed into entity correlation pipeline.
- **Phase 1 parallel tool execution**: New `WorkerPool` module enables concurrent tool invocation with provider-based concurrency limits (Azure, EntraID, GitHub). Tools execute in parallel up to provider limits, with shared isolation.
- **Phase 1 normalizer test fixtures**: Comprehensive test fixtures for all 7 tools under `tests/fixtures/normalizers/` to validate v1-to-v3 schema conversion.
- **Phase 0 security helpers**: shared sanitization, masking, retry, and rate-limit modules with Pester coverage for retry and credential scrubbing.
- **V3 Phase 0 core modules**: Add schema v2 factories/validation, canonicalization helpers, in-memory EntityStore with spill-to-disk, schema/canonicalization Pester tests, and a tool manifest for plugin registration.
- **Management group recursion**: When `-ManagementGroupId` is provided, the orchestrator auto-discovers all child subscriptions via ARG query and runs subscription-scoped tools (azqr, PSRule, WARA) across each one. MG-scoped tools (AzGovViz, ALZ queries) and tenant-wide tools (Maester) are unaffected. Use `-Recurse:$false` to disable.
- **AI triage (optional, requires GitHub Copilot license)**: `-EnableAiTriage` switch enriches non-compliant findings via GitHub Copilot SDK with priority ranking, risk context, remediation steps, and root cause grouping. Zero footprint when disabled. See `docs/ai-triage.md`.
- **AI triage in reports**: HTML/Markdown reports include AI Triage Summary when `triage.json` exists.
- **Wrapper status contract**: All tool wrappers now return `Status` ('Success', 'Skipped', 'Failed') and `Message` fields alongside `Source` and `Findings`.
- **Tool status summary**: Orchestrator tracks which tools succeeded, were skipped, or failed.
- **Maester integration**: Added `modules/Invoke-Maester.ps1` wrapper for Entra ID / identity security posture assessment (tool #6). Checks Graph connection, maps Pester test results to unified schema. Runs unconditionally (tenant-scoped, not subscription-gated).
- **OpenSSF Scorecard integration**: Added `modules/Invoke-Scorecard.ps1` wrapper for repository supply chain security assessment (tool #7). Evaluates branch protection, dependency pinning, CI/CD configuration, and other security practices. Requires repository context via new `-Repository` parameter.
- **Sample reports and visual previews in README**: Added `samples/` directory with mock findings data and pre-generated HTML + Markdown reports so users can see output before running the tool. README now includes collapsed preview sections for both report formats.
- **Bundled ALZ queries**: ALZ Resource Graph queries are now automatically bundled from [alz-graph-queries](https://github.com/martinopedal/alz-graph-queries) -- no manual copy-step required. Queries originate from [Azure/review-checklists](https://github.com/Azure/review-checklists).
- CI: `docs-check.yml` workflow enforces documentation updates on PRs that change code files
- **Schema enrichment**: Unified findings now include `ResourceId` (Azure ARM resource ID) and `LearnMoreUrl` (Microsoft Learn link) fields
- **Auto-report generation**: `Invoke-AzureAnalyzer.ps1` now automatically calls `New-HtmlReport.ps1` and `New-MdReport.ps1` after writing `results.json` -- no manual step needed
- **HTML report enhancements**:
  - Executive summary with auto-generated compliance prose (resource count, tool count, compliance %, high-severity callout)
  - Pure-CSS donut chart using conic-gradient for compliance percentage (zero JS dependencies)
  - Per-source horizontal bar chart showing finding counts per tool (azqr, PSRule, AzGovViz, ALZ Queries, WARA, Maester, Scorecard)
  - Clickable stat cards for severity filtering with `aria-pressed` accessibility support
  - Filter banner with clear button when severity filter is active
  - Zebra striping on findings tables for readability
  - Severity left-border on table rows (color-coded by High/Medium/Low/Info)
  - Text filter/search input above each findings table with instant keyup filtering
  - Clickable remediation URLs auto-detected and wrapped in anchor tags
  - Tool coverage badges based on actual tool status (Success/Skipped/Failed/Excluded), not just presence of findings
  - Remediation column added to all findings tables
  - Print-friendly @media print CSS hiding interactive elements, preventing page breaks in rows
- **Markdown report enhancements**:
  - Executive summary with GitHub-flavored callouts (WARNING/NOTE/TIP) based on severity
  - Mermaid pie chart for compliance breakdown (rendered natively on GitHub)
  - Per-source emoji badges (🔴 High, 🟠 Med, 🟡 Low, 🟢 All compliant)
  - Collapsible per-category finding tables via `<details>` tags
  - Tool coverage section showing which tools ran vs were skipped

### Changed
- **Phase 1 refactor**: `Invoke-AzureAnalyzer.ps1` refactored to use plugin model from `tools/tool-manifest.json` instead of hardcoded tool calls. Orchestrator now resolves, validates, and executes tools based on manifest entries and provided scope identifiers.
- PowerShell minimum version raised to 7.4 to support Phase 0 security modules.
- README: Restructure as consumer-first (Quick Start → What you get → Prerequisites → Usage → Schema → Permissions) with contributor/CI sections below a separator
- README: Rewrite CI/Automation section -- separate user-facing CI from maintainer-only squad workflows behind a collapsed `<details>` block
- README: Add "For Contributors" section explaining that `.squad/` is maintainer infrastructure, not part of the tool
- `.gitattributes`: Add `export-ignore` rules so squad files (`.squad/`, squad workflows, `.github/agents/`) are excluded from archive downloads
- README & THIRD_PARTY_NOTICES.md: Update ALZ queries attribution to reflect derivation chain (alz-graph-queries ← Azure/review-checklists)
- `Invoke-PSRule.ps1` -- populate `ResourceId` from `TargetName` when it looks like an ARM resource ID
- `Invoke-AlzQueries.ps1` -- populate `ResourceId` from first non-compliant ARG row
- `Invoke-WARA.ps1` -- populate `ResourceId` from ImpactedResources and `LearnMoreUrl` from LearnMoreLink
- Updated README.md to document unified 10-field schema and auto-generated reports

### Removed
- Delete dead Python stubs (`src/run.py`, `src/__init__.py`) -- orchestrator is PowerShell only

### Fixed
- **Phase 0 core hardening**: Removed unsupported null-conditional member access from `EntityStore`, fixed severity comparison invocation parsing, and corrected spill-file entity merge to aggregate compliant/non-compliant counts.
- **Tool manifest v3 metadata**: Added `provider`, `scope`, `normalizer`, and `invokeMethod` fields per tool entry; retained `azgovviz` with a migration note for native ARG in a later phase.
- **Sanitization coverage**: `Remove-Credentials` now redacts Azure `sig=...`, `client_secret=...`, and `SharedAccessSignature=...` patterns in addition to existing token patterns.
- **Security helper fail-fast mode**: Added `$ErrorActionPreference = 'Stop'` to shared `Sanitize`, `Mask`, `Retry`, and `RateLimit` modules for consistent terminating behavior.
- **Rate limit header handling**: Azure `x-ms-ratelimit-remaining-*` headers are now tracked across all matching buckets instead of stopping at the first one.
- **Tool status diagnostics**: `New-HtmlReport.ps1` now emits a warning when tool status JSON cannot be parsed in report generation.
- **WorkerPool parallel safety**: Fixed `$using:` indexing and argument splatting in `ForEach-Object -Parallel` by copying to local variables before indexing/splatting.
- **Checkpoint hardening**: Scope key components are sanitized, identity scope now uses `identity-correlator`, checkpoint path resolution enforces checkpoint-directory boundaries, and writes are now atomic via temp-file move.
- **Checkpoint resilience**: `Get-Checkpoint` now treats corrupt JSON as a cache miss and emits a warning instead of failing the run.
- **Report template guidance**: Added XSS-safe JSON embedding note (`</` escaping) and sidecar guidance for large-tenant report payloads.
- **Invoke-Wrapper fallback status**: Both fallback paths (script-not-found and exception-after-retries) now return `Status='Failed'` and `Message`, preventing `tool-status.json` and reports from falsely showing success after hard failures.
- **Maester API mapping**: Fix `.Tests` → `.Result` to match Pester `TestResultContainer` returned by `Invoke-Maester -PassThru`. Handle `NotRun` status alongside `Passed`/`Skipped`.
- **Graph scopes hint**: Warning message now shows `Connect-MgGraph -Scopes (Get-MtGraphScope)` with correct scope helper.
- **Prereq behavior**: `Install-Prerequisites` now advise-only by default -- lists missing modules with install commands. Add `-InstallMissingModules` switch to opt-in to auto-install. Prevents unexpected writes in shared/CI environments.
- **Report field rendering**: HTML and Markdown reports now render `ResourceId` and `LearnMoreUrl` columns in all findings tables (previously only stored in JSON but not displayed)
- **PS 7.6 compatibility**: Fix `New-HtmlReport.ps1` `-join` operator parsing error on PowerShell 7.6 (wrap `ForEach-Object` pipeline in parentheses)
- **Dedup key strengthened**: Use `Source+ResourceId+Category+Title+Compliant` as composite key. Never dedup across tools when ResourceId is empty -- prevents unrelated findings from collapsing.
- **PSRule severity mapping**: Fix `Outcome` (Pass/Fail) incorrectly mapping to severity via `Map-Severity` (Fail fell through to Info). Now derives severity from Outcome directly: Fail=Medium, Error=High, Pass=Info.
- **errors.json completeness**: Wrapper `Status='Failed'` returns now recorded in `$toolErrors` and `errors.json`, not just exception-path failures.
- **Tool status tracking**: Orchestrator writes `tool-status.json` alongside `results.json` with per-tool Status/Message/Findings count. Reports use this to distinguish success-with-zero-findings from skipped/failed.
- **HTML stat cards clickable**: Stat cards converted from `<div>` to `<button>` elements with `onclick` severity filter, `aria-pressed` for screen readers, and visible focus styles.
- **HTML zebra striping**: Alternating row backgrounds on findings tables for readability.
- **HTML severity borders**: Left-border color on each finding row matching its severity (High=red, Medium=orange, Low=yellow, Info=gray).
- **HTML tool coverage accuracy**: Coverage badges now reflect actual tool status (Success/Skipped/Failed/Excluded) from `tool-status.json`, not just presence/absence of findings.
- **Markdown source table**: All 7 tools shown in source breakdown table with Status column, even when they have zero findings or were skipped.
- **AzGovViz path discovery**: `Find-AzGovViz` now also searches `tools/AzGovViz/` and `$PSScriptRoot/tools/AzGovViz/`, matching README instructions.
- **ScorecardThreshold param**: Added `-ScorecardThreshold` parameter to orchestrator, passed through to Scorecard wrapper. Default: 7.
- Remove `python` from CodeQL language matrix; repo is PowerShell-only, no Python extractor needed
- Update branch protection to require `Analyze (actions)` only
- Update codeql.yml to use actions/checkout v6 SHA (was v4)
- Fix copilot-instructions.md SHA-pinning example to reference v6 (was v4.2.2)
- **V3 Phase 0 infrastructure**: Added shared `WorkerPool.ps1` and `Checkpoint.ps1` utilities (PS 7.4) plus the new static `report-template.html`.
- **V3 documentation**: Added `docs/ARCHITECTURE.md` and `docs/CONTRIBUTING-TOOLS.md` for the v3 pipeline and tool authoring guidance.

## [1.0.0] - 2025-01-15

### Added
- **Auto-install prerequisites**: `Install-Prerequisites` auto-installs missing PSGallery modules (Az.ResourceGraph, PSRule, PSRule.Rules.Azure, WARA, Maester) on first run. CLI tools (azqr, scorecard) print install instructions. Respects `-IncludeTools` to only install what's needed. Use `-SkipPrereqCheck` to bypass in CI.
- **Local module packaging**: Created `AzureAnalyzer.psd1` manifest and `AzureAnalyzer.psm1` loader. Users can now `Import-Module ./AzureAnalyzer.psd1` after cloning. Simplifies local invocation and development.
- **Public module API**: Three exported functions: `Invoke-AzureAnalyzer`, `New-HtmlReport`, `New-MdReport`. All tool wrappers remain internal.
- **Module auto-loading**: Root script dot-sources all tool wrappers from `modules/` directory and public functions from root scripts.
- **README module instructions**: Quick Start updated to show `Import-Module` workflow after clone.

### Changed
- README: Updated Quick Start to include `Import-Module ./AzureAnalyzer.psd1` step.
- ModuleVersion: 1.0.0 (local module only, no PSGallery).

## [0.0.1] - Initial scaffold
- Initial scaffold

