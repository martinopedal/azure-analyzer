# Atlas - Issue #233 complete: Infracost wrapper for pre-deploy IaC cost

- **Date (UTC):** 2026-04-20T16:09:39Z
- **Agent:** Atlas
- **Issue:** [#233](https://github.com/martinopedal/azure-analyzer/issues/233)
- **PR:** [#271](https://github.com/martinopedal/azure-analyzer/pull/271)
- **Merge SHA:** `163a59a8af6db71681b3bca9c974406d3bc341f2`
- **Decision status:** Implemented and merged.

## Delivered

- Added `infracost` tool registration in `tools/tool-manifest.json` with CLI install metadata and upstream release metadata.
- Added wrapper: `modules/Invoke-Infracost.ps1` with:
  - local path mode (`-Path`)
  - remote cloud-first mode (`-Repository`, alias `-RemoteUrl`) through `RemoteClone.ps1`
  - retry (`Invoke-WithRetry`) and timeout (`Invoke-WithTimeout`, 300s) for CLI execution
  - v1 envelope output with one finding per estimated IaC resource
- Added normalizer: `modules/normalizers/Normalize-Infracost.ps1` using `New-FindingRow`.
- Added fixtures and tests:
  - `tests/fixtures/infracost/infracost-breakdown.json`
  - `tests/fixtures/infracost/infracost-output.json`
  - `tests/wrappers/Invoke-Infracost.Tests.ps1`
  - `tests/normalizers/Normalize-Infracost.Tests.ps1`
  - `tests/wrappers/Wrappers-Remote.Tests.ps1` updated for infracost routing
- Added permission page: `docs/consumer/permissions/infracost.md`
- Updated docs and regenerated manifest-driven outputs:
  - `docs/consumer/tool-catalog.md`
  - `docs/contributor/tool-catalog.md`
  - `PERMISSIONS.md` index
  - `CHANGELOG.md`

## Heuristic and entity decision

- Severity thresholds:
  - monthly cost `> 1000` -> `High`
  - monthly cost `> 100` -> `Medium`
  - monthly cost `<= 100` -> `Low`
- EntityType: `AzureResource`.
  - Rationale: keep cost findings in Azure resource-centric reporting.
  - IaC pre-deploy inputs do not expose real ARM IDs, so the normalizer emits deterministic synthetic ARM-style IDs.

## Validation

- `Invoke-Pester -Path .\tests -CI` -> **1230 total, 1225 passed, 0 failed, 5 skipped**
- `pwsh -File scripts/Generate-ToolCatalog.ps1`
- `pwsh -File scripts/Generate-PermissionsIndex.ps1`
- `pwsh -File scripts/Check-StubDeadline.ps1 -Mode Check`

## Merge loop note

Main moved during review. Branch was rebased and force-pushed with `--force-with-lease` until checks were green and mergeable. Markdown Link Check had one transient network failure (keda.sh) and passed on rerun.
