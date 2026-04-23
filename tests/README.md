# tests

Pester 5 test suite for azure-analyzer. Run with `Invoke-Pester -Path .\tests -CI`.

Layout:
- `tests/shared/` — shared-module unit tests (`modules/shared/*`).
- `tests/wrappers/` — tool-wrapper unit tests (`modules/Invoke-*.ps1`).
- `tests/normalizers/` — v1 -> v2 normalizer tests with fixtures under `tests/fixtures/`.
- `tests/integration/` — cross-module smoke / integration.
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

## Test isolation (#746)

Every test file MUST restore any environment variables, global variables, or
module-scope state that it mutates. Shared-process test runners (macOS/Linux
runners, local `Invoke-Pester` across multiple files) will leak state from
earlier files into later ones, causing order-dependent flakes.

**Required pattern:**
```powershell
BeforeAll {
    # Capture prior state
    $script:_origFoo = $env:FOO
    $env:FOO = 'test-value'
}

AfterAll {
    # Restore prior state
    if ($null -eq $script:_origFoo) {
        Remove-Item Env:FOO -ErrorAction SilentlyContinue
    } else {
        $env:FOO = $script:_origFoo
    }
}
```

**Guard test:** `tests/shared/TestIsolation.Tests.ps1` scans all test files
for `$env:*` and `$global:*` writes and asserts that matching cleanup blocks
exist. Add new exemptions to `$script:Exemptions` ONLY with written
justification. The guard also includes a meta-test (gated behind
`$env:AZURE_ANALYZER_RUN_ISOLATION_META_TEST=1`) that runs a subset of the
suite twice back-to-back and asserts identical PassedCount, detecting leaks
that the static heuristic might miss.

**Common state to restore:**
- Environment variables: `$env:*`
- Global variables: `$global:*` (excluding `$global:LASTEXITCODE`, auto-managed)
- Script-scope variables shared across `It` blocks
- `$PSDefaultParameterValues`
- Preference variables (`$ErrorActionPreference`, `$WarningPreference`, etc.)
  set at module scope

**File-scoped mutations are safe:** `Set-StrictMode -Version Latest` and
`$ErrorActionPreference = 'Stop'` at the top of a `.Tests.ps1` file are
automatically scoped to that file and do not leak.
