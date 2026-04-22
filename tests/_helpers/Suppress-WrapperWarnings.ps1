#Requires -Version 7.0
<#
.SYNOPSIS
    Composite suppressor for wrapper-test transcript noise (#472, sweep #4).

.DESCRIPTION
    Wrapper tests exercise real module code. Some wrappers emit soft-fail
    Write-Warning lines when optional environment is missing, e.g.:

      Triage class A  - Tool-missing warnings
                        Already covered by:
                          - modules/shared/MissingTool.ps1 (Write-MissingToolNotice)
                          - tests/_Bootstrap.Tests.ps1 (sets the suppress env var)
                          - tests/_helpers/Mock-ToolPresence.ps1 (per-test mocks)

      Triage class B  - Auth-token-missing warnings
                        Example: Invoke-Scorecard.ps1 warns when neither
                        GITHUB_AUTH_TOKEN nor GITHUB_TOKEN is set. Wrapper
                        tests that exercise the happy path don't care about
                        this warning and should not leak it into transcripts.

      Triage class C  - Cap-truncation warnings
                        Example: Invoke-IdentityGraphExpansion.ps1 warns when
                        principal count exceeds -MaxPrincipals. Tests that
                        intentionally cross that threshold should redirect
                        the warning stream (3>$null) and assert on the Info
                        finding instead.

    This helper is the canonical seam for classes B and C. It:
      - Records the current value of auth-related env vars
      - Sets safe placeholder values so wrappers take the authenticated path
      - Returns a scriptblock that restores the prior state

    Usage:
        BeforeAll {
            . (Join-Path $PSScriptRoot '..' '_helpers' 'Suppress-WrapperWarnings.ps1')
            $script:RestoreEnv = Enable-WrapperWarningSuppression
        }
        AfterAll {
            if ($script:RestoreEnv) { & $script:RestoreEnv }
        }

    The placeholder tokens are obviously fake ('gha_test_dummy_...') so they
    can never be mistaken for real secrets in transcripts or logs. All writes
    are process-scoped and reverted via the returned scriptblock.

.NOTES
    Keep this file narrow. Per-wrapper mocks belong in Mock-ToolPresence.ps1.
    The suppress env var itself is set by tests/_Bootstrap.Tests.ps1.
#>

Set-StrictMode -Version Latest

function Enable-WrapperWarningSuppression {
    <#
    .SYNOPSIS
        Set placeholder auth env vars so wrappers don't emit "token not set"
        warnings during the happy-path test. Returns a scriptblock that
        restores the prior env-var state.

    .PARAMETER Include
        Optional list of env-var names to restrict the suppression to. When
        omitted, the default bundle (GitHub auth tokens) is applied.
    #>
    [CmdletBinding()]
    param (
        [string[]] $Include
    )

    $bundle = @{
        'GITHUB_TOKEN'      = 'gha_test_dummy_token_000000000000000000'
        'GITHUB_AUTH_TOKEN' = 'gha_test_dummy_token_000000000000000000'
    }

    if ($Include) {
        $filtered = @{}
        foreach ($key in $Include) {
            if ($bundle.ContainsKey($key)) { $filtered[$key] = $bundle[$key] }
        }
        $bundle = $filtered
    }

    $snapshot = @{}
    foreach ($key in $bundle.Keys) {
        $snapshot[$key] = [Environment]::GetEnvironmentVariable($key, 'Process')
        [Environment]::SetEnvironmentVariable($key, $bundle[$key], 'Process')
    }

    return {
        foreach ($key in $snapshot.Keys) {
            [Environment]::SetEnvironmentVariable($key, $snapshot[$key], 'Process')
        }
    }.GetNewClosure()
}
