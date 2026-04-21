# Squad Decisions

## Active Decisions

### Routing Infrastructure (2024-12-19)
- **Decision:** routing.md uses `## Work Type → Agent` header format
- **Rationale:** Clear separation of concerns and agent dispatch rules
- **Status:** Active

### GitHub Actions Security (2024-12-19)
- **Decision:** All GitHub Actions MUST be SHA-pinned (never use tags)
- **Rationale:** Security hardening; prevents workflow injection attacks
- **Implementation:** Applied across 10 action references in 4 workflows
- **Status:** Active

### Signed Commits Policy (2024-12-19)
- **Decision:** Signed commits NOT required for this repository
- **Rationale:** Breaks GitHub Dependabot and GitHub API commits; solo maintenance model
- **Status:** Active

### Triage Keyword Robustness (2024-12-19)
- **Decision:** Generic keywords in triage (go:needs-research) must be conditional, not unconditional
- **Rationale:** Prevents false-positive labeling; improves signal-to-noise ratio
- **Status:** Active

### Routing Table & Casting Registry Migration (2024-12-19)
- **Decision:** Squad routing infrastructure fully initialized with domain-specific routing table and casting registry
- **Details:**
  - routing.md section header: `## Work Type → Agent` (Ralph parser requirement)
  - 11 work-type mappings covering all agent specializations
  - Module Ownership section added (12 module-to-owner mappings)
  - Casting registry populated with 6 agents marked `legacy_named: true`
- **Commit:** 85d8c5e
- **Status:** Active

### Multi-Model Development Process Codified (2026-01-15)
- **Decision:** All code changes follow the mandatory multi-model review pipeline: Build -> Review (3 models) -> Fix -> Re-gate -> CI -> Merge. Models: Opus 4.6, Goldeneye, GPT-5.3-codex. All 3 must approve before merge.
- **Why:** Ensures code quality through independent multi-perspective validation. Catches bugs that single-model review misses. Proven across 4 phases with 50+ findings caught.
- **Enforcement:** Documented in `.copilot/copilot-instructions.md` and `.squad/ceremonies.md` for automatic discovery by future sessions.
- **Status:** Active

### Canonical Entity IDs in Test Fixtures (2026-04-18)
- **Decision:** Wrapper and normalizer fixtures must use canonical entity ID shapes expected by `ConvertTo-CanonicalEntityId` (`Subscription` as bare GUID, `Repository` as `host/owner/repo`).
- **Rationale:** Strict `New-FindingRow` validation now enforces canonical IDs, and non-canonical fixture data causes false-negative unit test failures unrelated to wrapper behavior.
- **Implementation:** Updated fixtures/tests for azure-cost, defender-for-cloud, gitleaks, scorecard, trivy, plus subscription-ID handling in Azure Cost/Defender normalizers.
- **Status:** Active

### CI Failure Watchdog Automation (2026-04-17)
- **Decision:** Implement CI failure triage as a dedicated `workflow_run` watchdog plus an opt-in local PowerShell watcher that share the same dedup contract using hash: first 12 chars of `sha256("{workflow}|{first-error-line}")`.
- **Rationale:** Converts failed runs into actionable backlog items. Prevents issue spam by grouping repeats by deterministic workflow+error signature. Keeps behavior consistent between GitHub-hosted and local polling loops.
- **Security:** Self-trigger loops blocked with workflow-name exclusion. Error lines sanitized before issue generation. Workflow payload values passed through environment variables.
- **Implementation:** `.github/workflows/ci-failure-watchdog.yml`, `tools/Watch-GithubActions.ps1`, tests, docs updated.
- **Status:** Active

### Issue #127 Fix: CI Failure Watchdog Event Registration (2026-04-17)
- **Decision:** Fixed `.github/workflows/ci-failure-watchdog.yml` by adding missing `workflows:` key to `workflow_run` trigger.
- **Root Cause:** `workflow_run` event payload does not include `head_branch`; referencing it in job condition caused parse-time workflow failure preventing job initialization.
- **Chosen Fix:** Minimal and safe — applied job condition `if: github.event.workflow_run.conclusion == 'failure' && github.event.workflow_run.name != 'CI failure watchdog'` with proper trigger registration.
- **Validation:** 2 post-merge live runs returned `conclusion=success` with `event=workflow_run`.
- **PR:** #154 (SHA 0f287ad)
- **Status:** Active

### SBOM + Pinned Versions Implementation (#102) (2025-01-01)
- **Decision:** Created separate `install-manifest.json` for supply-chain security (versions, checksums) distinct from `tool-manifest.json` (orchestration). Added CycloneDX 1.5 SBOM generation, SHA-256 verification functions, and CI/release workflow gates.
- **Rationale:** Clean separation of concerns. Package managers (winget/brew) verify checksums; we document delegation via `pinningNote`. Direct downloads use SHA-256 verification. Industry-standard CycloneDX format with GitHub/Docker/CI integration.
- **Key Choices:** Per-platform entries (Windows/macOS use package managers; Linux uses direct downloads). Separate manifest prevents mixing orchestration and supply-chain concerns.
- **Consequences:** Positive: supply-chain transparency on every release, reproducible installs (where possible), CI gate on hash verification. Negative: maintenance burden when tool versions bump (must update SHA-256).
- **Status:** Active

### Error Sanitization Boundary (2026-04-18)
- **Decision:** Sanitize at error-capture time (in `catch` blocks), not write-time. Every exception message assigned to a `Message` property must wrap with `Remove-Credentials`.
- **Rationale:** Single boundary enforcement prevents bypasses. If we sanitized only at write-time, future developers might write new output paths and forget. Keeps error messages in result objects always safe.
- **Pattern:** `$result.Message = "Context: $(Remove-Credentials $_.Exception.Message)"`
- **Enforcement:** Grep audit for `Exception.Message|Error.Message|.Message`, Pester tests (6 scenarios: SAS URI, bearer token, connection string, GitHub PAT, null, multi-secret), CI gate (398/398 tests).
- **Status:** Active

### PR #116 Re-Gate Extension (2026-04-18)
- **Decision:** Apply Falco-established dot-source pattern to all missing runspace boundaries. Dot-source `shared/Sanitize.ps1` in parallel-runspace callsites. Add dot-source + fallback stub inside `Invoke-AzureAnalyzer.ps1` before invoking wrappers.
- **Rationale:** PowerShell 7 `ForEach-Object -Parallel` creates isolated runspaces where parent-scope functions are not inherited. Guarantees `Remove-Credentials` exists at runtime in each worker runspace.
- **Validation:** `Invoke-Pester -Path .\tests -CI` → 398 passed, 0 failed.
- **Status:** Active

### PR #120 Revision for Issue #126 Gate (2026-04-17)
- **Decision:** Applied five corrections to wrapper error paths: (1) parser safety via `"${testNumber}: $testDesc"` string formatting; (2) test hard-fail with `$ErrorActionPreference = 'Stop'`; (3) retry API alignment with `-MaxAttempts` canonical (backward-compat `-MaxRetries` mapped); (4) sanitization invariant on all 17 wrappers; (5) `PartialSuccess` semantics for multi-target scans with mixed success/failure.
- **Rationale:** Prevents parse regressions, improves test signal, reduces secret leakage, preserves findings during partial outages.
- **Status:** Active

### SHA-Pinning + Triage Keyword Routing + Consistency Fixes (2025-01-26)
- **Decision:** (1) SHA-pinned 4 squad workflows (10 action instances); (2) replaced generic triage keywords in workflows and ralph-triage.js with azure-analyzer specialist keywords; (3) removed contradiction in copilot-instructions.md line 49; (4) made `go:needs-research` conditional (only applied to issues routed to Lead or with no domain match).
- **Keywords:** Atlas (`arg`, `kql`, `query`), Iris (`entra`, `identity`, `graph`, `pim`), Forge (`pipeline`, `workflow`, `ci`, `devops`), Sentinel (`security`, `compliance`, `azqr`, `score`), Sage (`research`, `spike`, `investigation`).
- **Impact:** ✅ Security (all workflows SHA-pinned), ✅ Triage accuracy (route to specialists), ✅ Label hygiene (`go:needs-research` only when needed).
- **Status:** Active

### PR Review Gate Model Selection (2026-04-17)
- **Decision:** For PR review-gate triage, use three diverse models: `claude-opus-4.6`, `gpt-5.3-codex`, `goldeneye`. All 3 must approve before merge.
- **Rationale:** Single-model review under-captures edge cases. Trio gives overlap on core correctness while preserving disagreement signal. Avoids homogeneous failure modes.
- **Operating Rule:** Ingest PR reviews, generate model-specific prompt bundle, merge three responses into deterministic consensus. Read + comment + plan-write only (no auto-approve/dismiss).
- **Status:** Active

### Issue-First Workflow Directive (2026-04-18)
- **Decision:** Do not ship ad-hoc PRs; always work on issues first. When an issue is fully planned (acceptance criteria, design, scope confirmed), then create code and implement the issue plan. PRs reference and implement issue plans, never the other way around.
- **Rationale:** Consistency across the squad. The issue is the contract; the PR is the implementation. Forces planning before code.
- **Status:** Active

### Rubberduck-Gate in Required Checks (2026-04-21)
- **Decision:** Branch protection enforces BOTH `Analyze (actions)` AND `rubberduck-gate` (strict=true), not just `Analyze (actions)`.
- **Impact:** With strict=true, each PR merge invalidates downstream PRs in a batch. Requires `gh pr update-branch` + ~90s CI wait per subsequent merge.
- **Operational Guidance:** Run Dependabot batches sequentially, not in parallel. Update coordinator runbook to reflect dual-gate requirement.
- **Discovery:** Found during Dependabot batch #288-#292 processing (2026-04-21).
- **Status:** Active

### Upload-Artifact v7 Matrix Safety Pattern (2026-04-21)
- **Decision:** `actions/upload-artifact@v7` is safe in this repo because (a) zero `download-artifact` consumers, (b) both upload sites use unique artifact names (sbom-{sha}, scheduled-scan-{run_id}).
- **Future Watchpoint:** Any new matrix consumer of `actions/upload-artifact@v7` MUST suffix artifact name with matrix variable (v5+ no longer merges same-named artifacts across matrix legs).
- **Pattern Example:** `name: sbom-${{ matrix.os }}-${{ github.sha }}` instead of `name: sbom`
- **Status:** Documented

### GitHub-Script v9 Compatibility Pattern (2026-04-21)
- **Decision:** `actions/github-script@v9` removed `require('@actions/github')`. The `getOctokit` function is now injected as a parameter, not defined via `const` or `let`.
- **Incompatible Pattern:** `const getOctokit = require('@actions/github').getOctokit;` or redeclaring with `const getOctokit = ...`
- **Compatible Pattern:** Use the injected `getOctokit` directly: `const octokit = getOctokit();`
- **Audit Result:** Zero instances of incompatible patterns found in 9 inline-script consumers. Safe to deploy.
- **Status:** Documented

### Dependabot Stale Version Comment Quirk (2026-04-21)
- **Decision:** Dependabot sometimes bumps the action SHA to a newer version but leaves the version comment tag at the previous release.
- **Example:** PR #290 bumped codeql-action to SHA matching v4.35.2 but left comment as `v4.35.1`. PR #291 bumped action-gh-release to v3.0.0 SHA but left comment as `v2.2.0`.
- **Mitigation:** Always `git diff` before merging Dependabot PRs. Fix stale comments with a follow-up commit on the Dependabot branch (before merge) to maintain SHA-pin policy accuracy.
- **Status:** Documented

## Governance

- All meaningful changes require team consensus
- Document architectural decisions here
- Keep history focused on work, decisions focused on direction
