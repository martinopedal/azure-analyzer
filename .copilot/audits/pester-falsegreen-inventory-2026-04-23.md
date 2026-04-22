# Pester false-green audit — 2026-04-23

**Auditor:** Helix
**Scope:** `tests/**/*.Tests.ps1` (165 files, 1729 discovered tests)
**Trigger:** User complaint — "WARNING: bicep CLI is not installed... can you properly validate pester if tools are missing?"

## Hypothesis under test

Some Pester tests use a silent-skip-as-pass anti-pattern: detect a missing CLI
(`bicep`, `terraform`, `trivy`, `gitleaks`, `zizmor`, `kubectl`, ...), emit
`Write-Warning "<tool> is not installed. Skipping"`, then `return` from the
`It` block so Pester records the test as **Passed** even though no assertion
ran. The fix would be to convert each occurrence to the canonical pattern:

```powershell
BeforeDiscovery {
    $script:HasBicep = [bool](Get-Command bicep -ErrorAction SilentlyContinue)
}
Describe 'X' {
    It 'validates Y' -Skip:(-not $script:HasBicep) {
        # real assertion
    }
}
```

so the run summary truthfully shows `Tests Skipped: N`.

## Methodology

Searched `tests/` with the following queries:

| Query | Hits |
|-------|------|
| `Write-Warning.*([Nn]ot installed\|[Ss]kipping)` inside `It` blocks | 0 |
| `Write-Host.*[Ss]kipping` / `Write-Verbose.*[Ss]kipping` | 0 |
| `Set-ItResult -Skipped` | 0 |
| `if (-not (Get-Command <cli>)) { ... return }` inside `It` blocks | 0 |
| `Get-Command <cli>` (where `<cli>` is bicep/terraform/trivy/...) at module-load time | 1 (Gitleaks — already correct) |
| `$script:<X>Installed = ...` pre-discovery flags | 1 (Gitleaks — already correct) |

Tools probed: `bicep terraform trivy az kubectl gh docker gitleaks zizmor kubescape helm prowler checkov tfsec cosign grype syft powerpipe steampipe infracost azqr`.

## Result: zero false-greens

The repository **does not exhibit the silent-skip-as-pass anti-pattern**.
Every wrapper test that exercises a missing-tool path does so via:

1. **`Mock Get-Command { return $null }`** + real assertions on
   `Status -eq 'Skipped'`, `Message -match 'not installed'`, etc.
   Examples (all correct):
   - `tests/wrappers/Invoke-IaCBicep.Tests.ps1` (lines 13–37)
   - `tests/wrappers/Invoke-IaCTerraform.Tests.ps1` (lines 13–35)
   - `tests/wrappers/Invoke-Trivy.Tests.ps1`
   - `tests/wrappers/Invoke-Kubescape.Tests.ps1`
   - `tests/wrappers/Invoke-Zizmor.Tests.ps1`
   - `tests/wrappers/Invoke-Falco.Tests.ps1`
   - `tests/wrappers/Invoke-Powerpipe.Tests.ps1`
   - `tests/wrappers/Invoke-Maester.Tests.ps1`
   - `tests/wrappers/Invoke-WARA.Tests.ps1`
   - `tests/wrappers/Invoke-PSRule.Tests.ps1`
   - `tests/wrappers/Invoke-Azqr.Tests.ps1`
   - `tests/wrappers/Invoke-AzureCost.Tests.ps1`
   - `tests/wrappers/Invoke-AlzQueries.Tests.ps1`
   - `tests/wrappers/Invoke-DefenderForCloud.Tests.ps1`
   - `tests/wrappers/Invoke-FinOpsSignals.Tests.ps1`
   - `tests/wrappers/Invoke-SentinelIncidents.Tests.ps1`

2. **Canonical `-Skip:(...)` with a `BeforeAll` install probe** — used by the
   single test file that does NOT mock and instead exercises the real binary:
   - `tests/wrappers/Invoke-Gitleaks.Tests.ps1`
     ```powershell
     $script:GitleaksInstalled = $null -ne (Get-Command gitleaks -ErrorAction SilentlyContinue)
     ...
     It 'returns Status = Skipped' -Skip:$script:GitleaksInstalled { ... }
     ```
   This is the exact pattern the user asked for, already in place.

3. **Adapter dispatch tests** that pass a path with no IaC files
   (`tests/shared/IaCAdapters.Tests.ps1` lines 18–58) hit the wrapper's
   *no-files-found* early return before the missing-CLI check, so they pass
   independently of whether bicep/terraform is installed. These are real
   assertions on dispatch routing and the no-files envelope, not silent
   skips.

## Source of the user-visible warning

The `WARNING: bicep CLI is not installed. Skipping Bicep IaC validation.`
line the user observed is emitted by **production code**
(`modules/Invoke-IaCBicep.ps1:88` via `Write-MissingToolNotice` from
`modules/shared/MissingTool.ps1`). It surfaces during test runs because
`tests/wrappers/Invoke-IaCBicep.Tests.ps1` deliberately mocks `Get-Command`
to return `$null` to drive the wrapper down the missing-CLI branch — and
that branch then asserts:

- `result.Status -eq 'Skipped'`
- `result.Message -match 'not installed'`
- `result.Source -eq 'bicep-iac'`
- `result.SchemaVersion -eq '1.0'`
- `@(result.Findings).Count -eq 0`

Five real assertions per missing-CLI scenario across all wrappers. The
warning is signal that the production missing-tool guard is firing as
designed inside a test that fully validates that guard. **It is not a false
green.**

## Conversion count

| Bucket | Count |
|--------|-------|
| Silent-skip patterns identified | 0 |
| Tests converted to `-Skip:(...)` | 0 |
| Tests already using `-Skip:(...)` correctly | 5 (Gitleaks file, all `It` blocks) |
| Tests using `Mock Get-Command` for missing-tool paths | ~80 across 17 wrapper test files |
| Net change to Pester baseline | 0 (no changes warranted) |

## Recommendations

1. **No code change required.** The audit hypothesis is falsified for the
   current state of `tests/`.
2. **Future safeguard:** if a contributor adds a new wrapper whose missing-
   tool path is hard to mock (e.g. a CLI version probe at module load), they
   should follow the **Gitleaks pattern** documented above — not the silent
   warn-and-return pattern.
3. **Consider a lightweight test linter** (e.g. PSScriptAnalyzer custom
   rule, or a 5-line CI grep) that fails the build on any new occurrence
   of `Write-Warning.*not installed.*Skipping[\s\S]{0,200}return` inside
   an `It { }` block. This audit can serve as the regression baseline.

## References

- User complaint: "WARNING: bicep CLI is not installed... can you properly validate pester if tools are missing?"
- Production missing-tool helper: `modules/shared/MissingTool.ps1`
- Reference correct pattern: `tests/wrappers/Invoke-Gitleaks.Tests.ps1`
- Audit exemption for `.copilot/audits/`: PR #503
