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