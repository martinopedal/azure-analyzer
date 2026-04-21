# Project Context

- **Owner:** martinopedal
- **Project:** ALZ Additional Graph Queries - DevOps/Platform API checks for ALZ platform items
- **Stack:** PowerShell, Azure DevOps REST API, GitHub REST API / gh CLI, JSON
- **Created:** 2026-04-14

## Core Context

Accumulated learnings from prior sessions (summarized 2026-04-22):

- **SHA-pinning (2024-12-19):** 10 GitHub Actions across 4 workflows. Commits c588589, 506ae8c.
- **Canonical-ID regressions (2026-04-18):** Updated fixtures/tests for canonical repository/subscription IDs. Extended runspace sanitizer to AzureCost, DefenderForCloud, Kubescape parallel paths.
- **SBOM (2025-01-01, #102):** CycloneDX 1.5 format. `install-manifest.json` (supply-chain) separate from `tool-manifest.json` (orchestration). Pinning exceptions: package managers delegate to OS, PSGallery trusts Authenticode, AzGovViz pins to HEAD SHA. `Get-FileHash256` + `Test-InstallManifestHash` in Installer.ps1 (warn-only, strict mode deferred). 3-job CI: test (Pester multiplatform), verify-install-manifest, generate-sbom. Release auto-attaches `sbom.json`.
- **Wrapper error paths (2025-01-20, #98):** 60 tests covering "missing dependency" path. Mock `Get-Command`/`Get-Module` → null, verify v1 contract (`Status='Skipped'`). Avoid complex CLI execution mocking; 413 normalizer tests cover those implicitly.
- **Module import integrity (2026-04-20, #244):** Root modules use `$ModuleRoot = $PSScriptRoot`, not `Split-Path -Parent`. PSGallery readiness requires `PrivateData.PSData` + real GUID.

## Learnings

<!-- Append new learnings below. Each entry is something lasting about the project. -->
- CI failure dedup key uses hash format `sha256("{workflow}|{first-error-line}")` truncated to 12 chars for stable issue-title matching.
- Self-skip pattern for `workflow_run` watchers should include workflow-name exclusion to avoid recursive self-processing.
- Repeated CI failures should comment `still failing - {run_url}` on the open hash-matched issue instead of creating duplicates.
- Treat `workflow_run` payload fields as untrusted input: pass through `env` and reference shell variables in `run:` blocks to reduce expression-injection risk.
- workflow_run payload does not expose 'head_branch'; branch checks in watchdog logic must use API lookup or avoid branch gating in job-level expressions.
- Any script that runs under `ForEach-Object -Parallel` must dot-source shared helpers (like `Sanitize.ps1`) inside that runspace and provide a local fallback to avoid `CommandNotFoundException`.
- PR #118 gate fix: avoid parameter attributes in New-FindingRow for required/enum checks when the intended behavior is to return $null; perform those checks inside the function so normalizers can drop invalid rows safely.
- PR #120 gate fix: wrappers that scan multiple targets should return `PartialSuccess` when at least one target succeeds and at least one fails, preserving successful findings instead of collapsing the whole run to `Failed`.

- Root modules should set `$ModuleRoot = $PSScriptRoot`; using `Split-Path -Parent $PSScriptRoot` points one directory too high and breaks relative module-path assumptions.
- Importing a `.psd1` should not dot-source script entry points that execute immediately. For `AzureAnalyzer.psm1`, export wrapper functions that invoke root scripts on demand, and limit import-time dot-sourcing to pure helper modules.
- PSGallery readiness is manifest-driven: replace placeholder GUIDs before publication and populate `PrivateData.PSData` with `Tags`, `ProjectUri`, `LicenseUri`, and `ReleaseNotes` so the package page is navigable and discoverable.

### 2026-04-20T15:18:09Z: CI-failure batch #260/#261/#262/#264

- Triage complete: all four issues were categorized stale or transient and closed with rationale comments.
- Root failure pattern observed: watchdog did not capture GitHub annotation lines (`##[error]`) from failed logs.
- Hardening applied in `.github/workflows/ci-failure-watchdog.yml` to extract actionable first error lines using annotation-first matching and broader fallback patterns.
- Validation: `Invoke-Pester -Path .\tests -CI` passed (1213 passed, 0 failed, 5 skipped).


- **2026-04-21:** Dependabot batch #288-292 — all 5 merged

  | PR | Action | Verdict | SHA |
  |----|--------|---------|-----|
  | #288 | azure/login 2.3.0 -> 3.0.0 | Merged | 4a50783 |
  | #289 | actions/github-script 7.1.0 -> 9.0.0 | Merged | 1dc8fb8 |
  | #290 | github/codeql-action SHA bump (4.35.1 -> 4.35.2) | Merged with comment fix | 1a6a957 |
  | #291 | softprops/action-gh-release 2.0.9 -> 3.0.0 | Merged with comment fix | 1b88dfe |
  | #292 | actions/upload-artifact 4.4.3 -> 7.0.1 | Merged | f2d6ccd |

  Notes for future-Forge:
  - **upload-artifact v7**: safe here only because we have ZERO download-artifact consumers and both upload calls already use unique names (sbom-{sha}, scheduled-scan-{run_id}). Adding a matrix consumer of upload-artifact later requires per-matrix-leg name suffix.
  - **github-script v9**: `require('@actions/github')` is gone and `getOctokit` is now an injected param. Inline scripts must not redeclare `getOctokit` with const/let.
  - **action-gh-release v3** and **azure/login v3**: Node 20 -> Node 24 runtime only. Self-hosted runners must support node24.
  - **Dependabot stale comment quirk**: Dependabot occasionally bumps the SHA but leaves the version comment at the previous tag (#290 left v4.35.1 for a v4.35.2 SHA; #291 left v2.2.0 for a v3.0.0 SHA). Always diff before merging; fix with a follow-up commit on the dependabot branch.
  - **Required checks reality**: branch protection requires BOTH `Analyze (actions)` AND `rubberduck-gate` (with strict=true), not just Analyze as the runbook claimed. Each merge invalidates downstream PRs because of strict; expect to `gh pr update-branch` + wait ~90s + retry merge for each subsequent PR in a batch.

### 2026-04-21: CLI tool UI patterns research (Trivy / Infracost / Scorecard) for Sentinel report rebuild
- Wrote `.squad/decisions/inbox/forge-cli-tools-ui-patterns.md` covering native UIs, hex palettes, severity mapping recommendations, end-to-end ETL fixes (per coordinator scope expansion) and per-tool sample data.
- Trivy ships a Go-template HTML at `contrib/html.tpl`; severity hex palette to standardise on across the unified report: Critical `#e40000`, High `#ff8800`, Medium `#e9c600`, Low `#5fbb31`, Info `#747474`. Wrapper drops CVSS, CweIDs, Layer info, References, PublishedDate, Result.Type — all should be preserved for the row drawer.
- Infracost has no static HTML CLI report; the canonical UI is the PR-comment markdown from `infracost output --format github-comment`. Our wrapper today only calls `breakdown` (not `diff`), so we render absolute-cost severity instead of delta-vs-main severity. Recommended delta thresholds: `>+$100 Critical, +$20–100 High, +$5–20 Medium, ≤+$5 Low, decreases Info`. Cost should live in its own report section, not the Findings table.
- Scorecard has no native HTML; UIs are badge + viewer + REST JSON + SARIF. The 0–10 score is the strongest hero-card candidate of any tool we wrap — propose three placements: exec-summary KPI, per-repo hero gauge, sticky badge. Wrapper currently treats `score=-1` (errored) as `High` which is wrong — should be `Info` with `Status='Errored'` marker.
- Cross-tool: a shared "scan target" badge style is missing today and causes most "what was actually scanned?" support questions. Recommended single-emoji prefix per target kind (📁 path, 🔗 repo, 🐳 image, 🧱 IaC, ☁ subscription, ⚙ workflow). SARIF support across Trivy/Scorecard/Zizmor/Gitleaks is also a strong candidate for a single shared renderer.

### 2026-04-21: End-to-end ETL audit of FindingRow schema (scope expansion from Sentinel report rebuild)
- Audited `New-FindingRow` ([`modules/shared/Schema.ps1:180-235`](../../../modules/shared/Schema.ps1)): no slot for `Tags`, `References`, `Tools`, `Evidence` (only `EvidenceCount [int]`), or generic `Properties` bag. Today's normalizers (Infracost) bolt extras on with `Add-Member -Force` — these survive `Export-Findings → ConvertTo-Json -Depth 100` but are NOT carried into entity records by `New-StoreEntity` (allowlist at [`EntityStore.ps1:335-343`](../../../modules/shared/EntityStore.ps1) is fixed).
- Recommended one-time additive schema bump: `Tags [string[]]`, `References [string[]]`, `Tools [string[]]`, `Evidence [object[]]`, `Properties [object]` — all default `$null`, fully back-compat (Test-FindingRow only validates required-field presence).
- Recommended new top-level `ToolSummary [object]` field on the v1 wrapper envelope for per-run aggregates (Infracost's `diffTotalMonthlyCost`, Scorecard's aggregate `score`) — neither of these belong on a finding row.
- Recommended new `IacProject` EntityType for Infracost (replaces the synthetic-`AzureResource` ARM ID hack at `Normalize-Infracost.ps1:53,95`); requires only an enum addition in `Test-EntityRecord` because `Import-EntitiesFile` is already shape-agnostic.
- Recommended generic `EntityProperties [object]` bag on entity records — lets Scorecard's aggregate score (and Defender secure score, Azqr WAF score, …) attach to entities without per-tool schema bumps.
- Bug fixes uncovered en route: Scorecard `score=-1` should map to `Info` (errored ≠ failed), `score=0` should map to `Critical` (currently `High` understates urgency); Infracost severity should be delta-aware, not absolute-cost.

### 2026-04-22: Report UX arc complete — briefs merged, per-tool issues filed

- Brief merged to `decisions.md`. Schema 2.2 contract locked (#299). Per-tool ETL issues filed: #311 (Trivy), #312 (Infracost), #313 (Scorecard).
- Scorecard severity inversion bug (#313): `-1` errored → Info, `0` true failure → Critical. Currently both → High.
- Trivy misconfig/secret scan types currently disabled (`--scanners vuln` only) — enabling them unlocks two entire finding categories.
- Manifest-only tool registration still needs full docs freshness updates (`README.md`, `CHANGELOG.md`, permissions page, generated tool catalogs/index), or docs-check and Pester generator tests will fail even if code is unchanged.

### 2026-04-21: Issue #315 — manifest-driven ALZ query sync script merged (PR #331)
- Delivered `scripts/Sync-AlzQueries.ps1` with manifest-driven upstream resolution (`tools/tool-manifest.json` → `alz-queries.upstream.repo`), HTTPS/allow-list enforcement via `RemoteClone.ps1`, idempotent hash compare + copy into top-level `queries/alz_additional_queries.json`, `-DryRun`, verbose diagnostics, retry+timeout wrappers, and rich `New-InstallerError` failures with sanitized output.
- Added `tests/scripts/Sync-AlzQueries.Tests.ps1` covering dry-run no-write behavior, idempotent re-run no-op behavior, transient-clone retry behavior, and credential redaction in verbose logs.
- Baseline preserved and extended: full Pester run moved from 1349 passed (pre-change) to 1354 passed (post-change), 0 failed, 5 skipped.
- Key upstream-path learning: the canonical source file in `martinopedal/alz-graph-queries` lives at `queries/alz_additional_queries.json` (not repo root), and sync logic now treats this as the default upstream relative path.

### 2026-04-22: Issue #316 — scheduled ALZ query drift detection workflow
- Added `.github/workflows/alz-queries-drift-check.yml` with weekly Monday 06:00 UTC schedule plus manual dispatch to run `scripts/Sync-AlzQueries.ps1 -DryRun` and fail when `.Changed` is true.
- Kept permissions minimal (`contents: read`) and action pinning compliant (`actions/checkout@de0fac2e... # v6`) to satisfy repo security posture and Actions CodeQL scanning.
- Updated `CHANGELOG.md` and validated baseline remained green at `Tests Passed: 1354, Failed: 0, Skipped: 5`.

### 2026-04-21: Issue #341 — Update-ToolPins idempotency on existing bump branches
- Root cause fixed in `tools/Update-ToolPins.ps1`: replaced unconditional `git checkout -b` with branch initialization that fetches `origin/main`, detects local/remote branch state, checks out existing bump branches, and resets them to `origin/main` before committing.
- Added retry-wrapped git helper (`Invoke-GitCommand` via `Invoke-WithRetry`) for fetch/checkout/reset/add/commit/push paths and switched remote-existing branch pushes to `--force-with-lease` to keep one PR per tool bump.
- Added open-PR reuse logic (`gh pr list` + `gh pr edit`) so reruns update the existing PR instead of failing on duplicate `gh pr create`.
- Added `tests/scripts/Update-ToolPins.Tests.ps1` with mocked `git`/`gh` coverage of the previously failing remote-branch-exists path; asserts checkout/reset behavior and no `checkout -b` call.

### 2026-04-21: Issue #300 azqr wrapper and normalizer Schema 2.2 ETL
- Upgraded `modules/Invoke-Azqr.ps1` to project raw findings into stable fields and include `ToolVersion`, WAF pillar mapping, framework refs, and MITRE metadata in the wrapper payload.
- Upgraded `modules/normalizers/Normalize-Azqr.ps1` to pass Schema 2.2 optional fields through `New-FindingRow` without dropping legacy fields.
- Added fixture coverage for `RecommendationId`, `Impact`, `Effort`, `DeepLinkUrl`, `Frameworks`, `RemediationSnippets`, `EvidenceUris`, `BaselineTags`, `MitreTactics`, `MitreTechniques`, `EntityRefs`, and `ToolVersion`.
- Extended wrapper and normalizer Pester tests to assert the new ETL contract end-to-end.

### 2026-04-23: Docs Architecture Audit (forge-docs-restructure) — Refined with Progressive Disclosure

**Initial findings**: 68 docs files, 7 orphaned stubs, no root index, README oversized (130 lines mixes marketing, quickstart, reference). Tool catalog scattered, ETL and field mapping hidden. Parameter reference missing.

**Martin's refinement principles applied**:
1. **Progressive disclosure**: Visible layer (first 10 seconds) shows "what is this, how do I run it, what do I get". Expanded layers (collapsed `<details>`) hold advanced params, full ETL mapping, gotchas, maintainer notes.
2. **README contract** (new shape): One-sentence pitch (1 line), three-bullet outputs (3 lines), single command example (5 lines), link to getting-started. Everything else in collapsed details blocks. Target visible section: ~50 lines max.
3. **Tool page contract** (new): Purpose (1 line), scan target (1 line), min permissions (1 line), min invocation (code block). Collapsed sections for: full params, ETL field mapping, known gotchas, maintainer notes.
4. **New reference pages**: `docs/reference/orchestrator-params.md` (every Invoke-AzureAnalyzer.ps1 param; common visible, advanced collapsed). `docs/reference/etl-pipeline.md` (v1 envelope to v3 entity flow with per-normalizer field mapping in collapsibles, Schema 2.2 spec in collapsibles).
5. **Dual-audience pages**: Where consumer and maintainer guidance diverges, use side-by-side collapsibles ("For consumers: run the tool" / "For maintainers: extend or debug"). No flat mixing.
6. **Accessibility**: GitHub's `<details><summary>` is native, keyboard-navigable, screen-reader friendly. Nesting rule: max 2 levels (readability cliff beyond). Summary text always a complete phrase, not fragment. Default state: `<details open>` for critical (quickstart, common params), `<details>` (closed) for advanced.

**Refined proposal outcome** (written to `.squad/decisions/inbox/forge-docs-restructure-proposal.md`, 23 KB):
- Visibility policy per page type (README, orchestrator params, tool pages, guides, reference, architecture).
- Concrete examples of collapsed sections with markdown.
- Structure tree with new pages: orchestrator-params.md, etl-pipeline.md, entity-model.md.
- Migration checklist (Phase 1-6): generators, directory creation, file moves, deletions, validation.
- No file moves yet, still proposal-only.

**Key learnings for future doc work**:
- Progressive disclosure must be consistent: same visual patterns across all pages. Users learn the structure once, apply everywhere.
- Tool pages need "at-a-glance" contracts (purpose, scan target, min permissions, min invocation) above all else. Gotchas and deep ETL mapping belong in collapsed sections.
- Root-level paths (README, PERMISSIONS, CHANGELOG) are stable anchors; they're referenced externally (tool-manifest.json report metadata, GitHub links, etc.). Changes require link audits.
- Generators with hardcoded defaults breed confusion. New structure makes defaults explicit in script documentation and maintainer checklists.
- Orphaned stubs with redirect deadlines create maintenance overhead. Delete or consolidate, not redirect with deadline tracking.
- ETL and field mapping deserve their own reference page (not scattered across CHANGELOG, README, ARCHITECTURE, tool pages). One stop for "what raw field -> what v2 slot" questions.
- Parameter reference page (orchestrator-params.md) should group params by scenario (subscription scan, repo scan, multi-tenant, CI/CD, etc.) and collapse advanced params. Consumers find their scenario, maintainers find exhaustive reference.
