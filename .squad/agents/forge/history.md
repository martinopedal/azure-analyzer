# Project Context

- **Owner:** martinopedal
- **Project:** ALZ Additional Graph Queries — DevOps/Platform API checks for ALZ platform items
- **Stack:** PowerShell, Azure DevOps REST API, GitHub REST API / gh CLI, JSON
- **Created:** 2026-04-14

## Work Completed

- **2024-12-19:** SHA-pinned 10 GitHub Actions across 4 workflows (analyze, squad-triage, release, codeql)
- **2024-12-19:** Fixed copilot-instructions.md line 49 — clarified "Signed commits NOT required"
- **2024-12-19:** Refined squad-triage.yml keyword matching (robustness improvements)
- **2024-12-19:** Updated ralph-triage.js `findRoleKeywordMatch()` — improved generic keyword handling
- **2024-12-19:** Made `go:needs-research` conditional (not unconditional application)
- **2024-12-19:** Commits c588589 (SHA-pinning), 506ae8c (triage + docs + code)

## Learnings

### 2025-01-01: SBOM generation + version pinning (#102)

**SBOM format choice**: CycloneDX 1.5 selected over SPDX 2.3 for better dependency graph support and broader CI/container tooling adoption. CycloneDX's `bom-ref` + `dependencies[]` model maps cleanly to our azure-analyzer→tools hierarchy. SPDX is more document-centric and less tool-friendly for automated consumption.

**Pinning exceptions**: Documented three categories:
1. **Package managers (winget/brew/pipx)**: Delegate checksum verification to the package manager. These systems maintain their own manifests/formulas with SHA-256. Duplicating the check is fragile and OS-dependent.
2. **PSGallery modules**: PowerShell Gallery enforces Authenticode signing on all published modules. Trust the gallery's integrity layer.
3. **Git clones (AzGovViz)**: No stable releases. Pin to `HEAD` with `pinType: sha`. Commit SHA is captured post-clone for audit trail.

Stored these in `tools/install-manifest.json` with `pinningNote` field per platform so future maintainers understand the rationale without reading code.

**Hash verification patterns**: Added `Get-FileHash256` + `Test-InstallManifestHash` to `Installer.ps1`. Current implementation is informational only (warns on mismatch but doesn't block install). Future enhancement: opt-in strict mode (`-EnforceHashChecks`) that fails on mismatch.

**Why separate manifest?**: `tool-manifest.json` drives orchestration (which tools, normalizers, report phase). `install-manifest.json` drives supply-chain security (versions, checksums, download URLs). Mixing them would create a mega-manifest that's hard to parse for SBOM generation and tool-selection logic. Clean separation of concerns.

**CI structure**: Three-job CI workflow:
- `test`: Pester on ubuntu/windows/macos (parallel) for cross-platform coverage.
- `verify-install-manifest`: Schema validation + smoke test of hash functions.
- `generate-sbom`: Dry-run SBOM generation + artifact upload so every PR proves the SBOM build works.

**Release workflow**: Auto-attaches `sbom.json` to GitHub release on tag push. Uses `softprops/action-gh-release` (SHA-pinned) for artifact upload. SBOM is part of the release assets alongside any future binaries or zipballs.

**Pester test strategy**: 8 new tests cover hash computation (lowercase hex, consistency), manifest lookup (matches, mismatches, placeholders, missing entries), and graceful degradation (no manifest → skip check). Mock manifest in `BeforeAll` with realistic tool entries so tests are fast and isolated.

**Future automation**: `Update-ToolPins.ps1` currently bumps `currentPin` in `tool-manifest.json`. Next iteration: also update `install-manifest.json` SHA-256 by fetching release asset checksums from GitHub releases API (many projects publish `.sha256` files alongside binaries). Reduces manual toil on version bumps.

## Learnings

<!-- Append new learnings below. Each entry is something lasting about the project. -->
- CI failure dedup key uses hash format `sha256("{workflow}|{first-error-line}")` truncated to 12 chars for stable issue-title matching.
- Self-skip pattern for `workflow_run` watchers should include workflow-name exclusion to avoid recursive self-processing.
- Repeated CI failures should comment `still failing — {run_url}` on the open hash-matched issue instead of creating duplicates.
- Treat `workflow_run` payload fields as untrusted input: pass through `env` and reference shell variables in `run:` blocks to reduce expression-injection risk.

- PR #118 gate fix: avoid parameter attributes in New-FindingRow for required/enum checks when the intended behavior is to return $null; perform those checks inside the function so normalizers can drop invalid rows safely.
- PR #120 gate fix: wrappers that scan multiple targets should return `PartialSuccess` when at least one target succeeds and at least one fails, preserving successful findings instead of collapsing the whole run to `Failed`.
## Learnings

### Issue #98: Wrapper error-path test coverage (2025-01-20)

**Challenge**: Pester tests for wrapper error paths needed to validate Status/Message/Findings shape without running actual CLIs or making API calls. Mock-based testing of external CLI tools (azqr, gitleaks, trivy, zizmor, kubescape, etc.) is inherently unreliable in PowerShell/Pester.

**Approach taken**:
- Focus on "missing dependency" path — the most testable and most common production failure
- Mock Get-Command (for CLI tools) or Get-Module (for PS modules) to return null
- Verify wrapper returns proper v1 contract: Source='toolname', Status='Skipped', Message='not installed', Findings=@()
- **Avoided** complex mocking of CLI execution or JSON parsing failures — those paths are implicitly tested by 413 existing normalizer tests

**Technical patterns discovered**:
1. **Parameter sets matter**: Invoke-AlzQueries requires *either* -SubscriptionId OR -ManagementGroupId, not both
2. **Environment variable handling**: AzGovViz's Find-AzGovViz can hit null $env:HOME on Windows; mock Get-Location + set env vars to non-existent paths
3. **Module mocking scope**: Can't mock a module that doesn't exist (-ModuleName requires loaded module)
4. **Identity-Correlator exception**: Function-invoke pattern (not script wrapper), so test validates empty-store graceful degradation instead

**Test count**: 60 new tests (473 total, up from 413). All passing.

**Future**: Integration tests with actual failing CLIs would complement these unit tests.

---

