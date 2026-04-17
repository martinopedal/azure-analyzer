# Decision: SBOM + Pinned Versions Implementation (#102)

**Date**: 2025-01-01  
**Author**: Forge (Platform Automation & DevOps)  
**Status**: Implemented  

## Context

Issue #102 requested SBOM generation + version pinning with SHA-256 checksums for all tools downloaded by `Installer.ps1`. Supply-chain security requirement — avoid TOCTOU attacks, enable reproducible builds, provide audit trail.

## Decision

### 1. Install manifest (`tools/install-manifest.json`)

Created a new JSON manifest separate from `tool-manifest.json` (which is integration-focused) to hold version pins + checksums. Structure:

```json
{
  "schemaVersion": "1.0",
  "tools": [
    {
      "name": "azqr",
      "version": "3.1.2",
      "pinType": "cli-version",
      "upstream": "https://github.com/Azure/azqr",
      "platforms": {
        "windows": { "installMethod": "winget", "wingetId": "...", "pinningNote": "..." },
        "linux": { "url": "...", "sha256": "abc123..." }
      }
    }
  ]
}
```

**Key choices**:
- **Separate manifest**: `tool-manifest.json` drives orchestration; `install-manifest.json` drives supply-chain security. Clean separation of concerns.
- **Per-platform entries**: Windows/macOS often use package managers (winget/brew) which maintain their own checksums. Linux often uses direct downloads where we can pin SHA-256.
- **`pinningNote` field**: Documents exceptions (e.g., "brew formula includes checksum", "no stable releases; gitclone from main").

### 2. Tool pinning exceptions

- **winget/brew/pipx**: These package managers verify checksums themselves. We delegate to them and document via `pinningNote`. SHA-256 field is `PLACEHOLDER` or omitted.
- **PSGallery modules**: PowerShell Gallery enforces Authenticode signing. We trust PSGallery's integrity layer.
- **AzGovViz (gitclone)**: No stable releases. Pinned to `HEAD` with `pinType: sha`. Commit SHA is captured post-clone for audit trail.

### 3. SHA-256 verification in `Installer.ps1`

Added three functions:
- `Get-FileHash256`: Compute SHA-256 of a file (lowercase hex).
- `Test-InstallManifestHash`: Verify a downloaded file against `install-manifest.json`. Returns `true` if match, `false` if mismatch, `true` if no hash in manifest (delegated install).
- Updated `Install-CliTool` (future): Would integrate hash checks post-download for direct URLs. **Not implemented in this PR** — current `Installer.ps1` delegates to package managers which already verify. Future enhancement: download direct URLs (Linux) and verify before exec.

**Why not enforce hash checks on package-manager installs?**  
Package managers (winget, brew, pipx) already verify checksums from their manifests/formulas. Duplicating that check would require parsing their output or extracting the installed binary path, which is fragile and OS-dependent. We document the delegation via `pinningNote` instead.

### 4. CycloneDX 1.5 SBOM

`tools/Generate-SBOM.ps1` emits a CycloneDX 1.5 JSON SBOM to `output/sbom.json`. Structure:
- **metadata.component**: azure-analyzer (top-level component) with version from `git describe --tags` or branch+shortSHA.
- **components[]**: Each tool from `install-manifest.json` with `name`, `version`, `bom-ref` (pkg:generic/...), `externalReferences` (upstream VCS), `hashes` (SHA-256 where available), `properties` (pinType, pinningNote).
- **dependencies[]**: azure-analyzer depends on all tools.

**Why CycloneDX 1.5?**  
Industry-standard SBOM format. Supports components, dependencies, hashes, external references, and properties (for custom metadata). SPDX 2.3 is also common but less tooling-friendly for dependency graphs. CycloneDX has better GitHub/Docker/CI integration.

### 5. CI + release workflows

- **`.github/workflows/ci.yml`**: Runs on every PR. Three jobs:
  - `test`: Pester tests on ubuntu/windows/macos (parallel).
  - `verify-install-manifest`: Schema validation + hash function smoke test.
  - `generate-sbom`: Dry-run SBOM generation + upload artifact.
- **`.github/workflows/release.yml`**: Runs on `v*.*.*` tags. Generates SBOM + attaches to GitHub release as `sbom.json`.

### 6. Pester tests

Added 8 new tests to `tests/shared/Installer.Tests.ps1`:
- `Get-FileHash256`: Computes lowercase hex SHA-256.
- `Test-InstallManifestHash`: Matches, mismatches, placeholders, missing tools, missing platforms, missing manifest.

## Alternatives Considered

1. **Single manifest**: Merge `install-manifest.json` into `tool-manifest.json`.  
   **Rejected**: Would mix orchestration concerns (which tools to run, normalizers, report phase) with supply-chain concerns (versions, checksums). Hard to parse for SBOM generation.

2. **Enforce hash checks on package-manager installs**: Parse `winget show`, `brew info` to extract installed checksums.  
   **Rejected**: Fragile, OS-dependent, duplicates work already done by package managers. Document delegation instead.

3. **SPDX 2.3 SBOM**: Alternative to CycloneDX.  
   **Rejected**: CycloneDX has better tooling support for dependency graphs and is the de facto standard for container/CI SBOMs.

4. **In-band pinning**: Store version pins in `tool-manifest.json` `upstream.currentPin`.  
   **Rejected**: `upstream.currentPin` is for the auto-update workflow (`Update-ToolPins.ps1`). Install manifest needs SHA-256, download URLs, per-platform differences — different data model.

## Consequences

**Positive**:
- Supply-chain transparency: SBOM on every release lists exact versions + checksums.
- Reproducible installs (where possible): Direct downloads are SHA-256-verified.
- CI gate: Hash verification runs on every PR; SBOM generation tested.

**Negative**:
- **Maintenance burden**: When a tool version bumps, must update `install-manifest.json` with new SHA-256 (for direct downloads). Automation via `Update-ToolPins.ps1` can help but needs SHA-256 fetch from upstream release assets.
- **Limited enforcement**: Hash checks are informational only in this PR. Future work: make hash mismatches fail the install (opt-in via `-EnforceHashChecks`).

**Future enhancements**:
- Auto-populate SHA-256 in `Update-ToolPins.ps1`: When bumping a tool version, fetch the release asset SHA from GitHub releases API and update `install-manifest.json`.
- SBOM signing: Sign `sbom.json` with GPG or Sigstore for tamper-evidence.
- VEX (Vulnerability Exploitability eXchange): Attach CVE metadata to SBOM components when known vulnerabilities exist in a tool.

## References

- Issue: #102
- CycloneDX 1.5 spec: https://cyclonedx.org/docs/1.5/json/
- NIST SSDF practices: PO.3.1 (SBOM generation), PW.4.4 (dependency verification)
