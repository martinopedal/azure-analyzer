# WrapperConsistencyRatchet.Tests.ps1
#
# Codifies the wrapper consistency contract introduced by sweep #2
# (cats 7-11 of the post-#473 hardening sweep, complementing PR #501
# which delivered cats 1-6).
#
# This is a ratchet: each wrapper is grandfathered at its current count of
# raw `throw "..."` strings. New code must use `New-FindingError` +
# `Format-FindingErrorMessage` from modules/shared/Errors.ps1 instead. If
# you intentionally remove a raw throw (good!) tighten the ratchet for that
# file in $script:RawThrowBaseline below. If a wrapper drops to zero
# raw throws, remove its entry entirely so any future regression fails fast.
#
# The test also enforces:
#  - Cat 7: every wrapper declares [CmdletBinding()] (no positional-only
#    invocations leaking through).
#  - Cat 10: any wrapper that calls Invoke-RestMethod / Invoke-AzRestMethod
#    must also route through Invoke-WithRetry at least once. Direct REST
#    calls without retry are forbidden.

BeforeDiscovery {
    $script:WrapperRoot = Join-Path $PSScriptRoot '..' '..' 'modules'
    $script:WrapperFiles = @(
        Get-ChildItem -Path $script:WrapperRoot -Filter 'Invoke-*.ps1' -File |
            Sort-Object Name
    )
    $script:WrapperNames = $script:WrapperFiles | ForEach-Object { $_.Name }
}

BeforeAll {
    $script:WrapperRoot = Join-Path $PSScriptRoot '..' '..' 'modules'

    # Grandfathered baseline: number of raw `throw "..."` (and inline
    # `catch { throw "..." }`) strings allowed per wrapper. Any change
    # in either direction fails the test, forcing a conscious update.
    $script:RawThrowBaseline = @{
        'Invoke-AksKarpenterCost.ps1'  = 3
        'Invoke-AksRightsizing.ps1'    = 3
        'Invoke-AppInsights.ps1'       = 2
        'Invoke-AzGovViz.ps1'          = 1
        'Invoke-AzureCost.ps1'         = 1
        'Invoke-AzureLoadTesting.ps1'  = 1
        'Invoke-DefenderForCloud.ps1'  = 3
        'Invoke-Falco.ps1'             = 4
        'Invoke-FinOpsSignals.ps1'     = 2
        'Invoke-GhActionsBilling.ps1'  = 1
        'Invoke-Gitleaks.ps1'          = 3
        'Invoke-KubeBench.ps1'         = 4
        'Invoke-Kubescape.ps1'         = 4
        'Invoke-Powerpipe.ps1'         = 1
        'Invoke-Scorecard.ps1'         = 1
        'Invoke-SentinelCoverage.ps1'  = 1
        'Invoke-SentinelIncidents.ps1' = 1
    }

    function Get-RawThrowCount {
        param ([Parameter(Mandatory)][string] $Path)
        $text = Get-Content -LiteralPath $Path -Raw
        $top = ([regex]::Matches($text, "(?m)^\s*throw\s+[`"']")).Count
        $inline = ([regex]::Matches($text, "catch\s*\{[^{}]*throw\s+[`"']")).Count
        return $top + $inline
    }
}

Describe 'Wrapper consistency contract (sweep #2 ratchet)' {

    Context 'Cat 7 - every wrapper opts into common-parameter support' {
        It '<_> declares [CmdletBinding()]' -ForEach $script:WrapperNames {
            $path = Join-Path $script:WrapperRoot $_
            $text = Get-Content -LiteralPath $path -Raw
            $text | Should -Match '\[CmdletBinding'
        }
    }

    Context 'Cat 10 - REST calls go through Invoke-WithRetry' {
        It '<_> wraps Invoke-RestMethod / Invoke-AzRestMethod with Invoke-WithRetry' -ForEach $script:WrapperNames {
            $path = Join-Path $script:WrapperRoot $_
            $text = Get-Content -LiteralPath $path -Raw
            $restCount  = ([regex]::Matches($text, 'Invoke-RestMethod|Invoke-AzRestMethod')).Count
            $retryCount = ([regex]::Matches($text, 'Invoke-WithRetry')).Count
            if ($restCount -gt 0) {
                $retryCount | Should -BeGreaterThan 0 -Because "wrapper $_ issues $restCount REST call(s) but never invokes Invoke-WithRetry"
            }
        }
    }

    Context 'Cat 11 - raw throw "..." ratchet (use New-FindingError instead)' {
        It '<_> raw-throw count matches grandfathered baseline' -ForEach $script:WrapperNames {
            $path     = Join-Path $script:WrapperRoot $_
            $actual   = Get-RawThrowCount -Path $path
            $expected = if ($script:RawThrowBaseline.ContainsKey($_)) { $script:RawThrowBaseline[$_] } else { 0 }
            $actual | Should -Be $expected -Because @"
Raw `throw "..."` count for $_ changed.
Expected (baseline): $expected. Actual: $actual.

If the count went DOWN (e.g. you converted throws to New-FindingError),
update `$script:RawThrowBaseline` in this test to the new lower value
(or remove the entry entirely if it dropped to 0).

If the count went UP, replace the new throw with:
  throw (Format-FindingErrorMessage (New-FindingError ``
      -Source 'wrapper:<name>' ``
      -Category '<InvalidParameter|MissingDependency|...>' ``
      -Reason  '<what failed>' ``
      -Remediation '<concrete next step>'))

See modules/shared/Errors.ps1 for the full FindingError schema.
"@
        }
    }
}
