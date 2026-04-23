# tests

Pester 5 test suite for azure-analyzer. Run with `Invoke-Pester -Path .\tests -CI`.

Layout:
- `tests/shared/` — shared-module unit tests (`modules/shared/*`).
- `tests/wrappers/` — tool-wrapper unit tests (`modules/Invoke-*.ps1`).
- `tests/normalizers/` — v1 -> v2 normalizer tests with fixtures under `tests/fixtures/`.
- `tests/integration/` — cross-module smoke / integration and runtime tool-availability tests.
- `tests/workflows/` — static `.github/workflows/*.yml` invariant checks.

## Negative-path tests that exercise `Write-Warning`

Production code emits `Write-Warning` on recoverable failure paths
(malformed JSON index, unknown schema, corrupt state file, missing snapshot
file, etc). Negative-path tests that drive those branches MUST NOT let those
warnings leak into the Pester test log: CI output must stay signal-only.

Two supported patterns, in preference order:

1. **Capture and assert the warning (preferred, strongest contract).**
   The warning IS the asserted behavior. Capture it with `-WarningVariable`
   and suppress display with `-WarningAction SilentlyContinue`, then assert
   on the captured records. Example:

   ```powershell
   $warnings = @()
   Resolve-BaselineRun -SnapshotDir $sd `
       -WarningVariable warnings `
       -WarningAction SilentlyContinue |
       Should -BeNullOrEmpty
   $warnings.Count | Should -BeGreaterThan 0
   ($warnings -join "`n") | Should -Match 'could not read snapshot index'
   ```

   This promotes the warning from log-noise to asserted behavior: the test
   fails loudly if the warning text ever drifts, and no `WARNING:` line
   reaches the CI log.

2. **Silent suppression (only when the warning is truly incidental to the
   assertion under test).** Use `-WarningAction SilentlyContinue` without
   `-WarningVariable`. Do this only when the warning is a side-effect of a
   different branch under test, not the behavior being asserted.

Do NOT:
- Set `$WarningPreference = 'SilentlyContinue'` at suite or Describe scope;
  that masks legitimate warnings from unrelated code paths.
- Remove `Write-Warning` from production code to make tests quieter — those
  warnings fire correctly for real users.
- Let `WARNING:` lines accumulate in CI test output. Treat them as regressions.

## LiveTool tier for wrapper tests

Wrapper tests that depend on a live tool being installed (e.g. trivy, scorecard, gitleaks)
use the `_LiveTool.Helper.ps1` module to skip gracefully when the tool is unavailable.

### Usage

In a wrapper test file (e.g. `tests/wrappers/Invoke-Trivy.Tests.ps1`):

```powershell
. (Join-Path $PSScriptRoot '_LiveTool.Helper.ps1')
New-LiveToolSkipFilter -ToolName 'trivy'

Describe 'Invoke-Trivy' {
    It 'runs and produces findings' {
        # Test is skipped unless trivy is installed or LIVE_TOOL_TESTS=1
    }
}
```

### Behavior

- If the tool is installed, all tests run.
- If the tool is NOT installed AND the `LIVE_TOOL_TESTS=1` environment variable is set,
  all tests run (expected to be on a runner with tools pre-installed).
- If the tool is NOT installed AND `LIVE_TOOL_TESTS` is not set, all tests are skipped
  (default for local development without all optional tools).
