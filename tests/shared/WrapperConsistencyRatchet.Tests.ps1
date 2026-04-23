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

    $script:SinkRoot = Join-Path $script:WrapperRoot 'sinks'
    $script:SinkFiles = @(
        Get-ChildItem -Path $script:SinkRoot -Filter '*.ps1' -File |
            Sort-Object Name
    )
    $script:SinkNames = $script:SinkFiles | ForEach-Object { $_.Name }
}

BeforeAll {
    $script:WrapperRoot = Join-Path $PSScriptRoot '..' '..' 'modules'
    $script:SinkRoot    = Join-Path $script:WrapperRoot 'sinks'

    # Grandfathered baseline: number of raw `throw "..."` (and inline
    # `catch { throw "..." }`) strings allowed per wrapper. Any change
    # in either direction fails the test, forcing a conscious update.
    # CON-003 (#626): all wrapper raw throws have been migrated to
    # New-FindingError + Format-FindingErrorMessage. Baseline is now empty
    # so any new raw throw fails fast. Re-add an entry only with explicit
    # justification (e.g. bootstrap guard before Errors.ps1 is sourced).
    $script:RawThrowBaseline = @{}

    $script:SinkRawThrowBaseline = @{
        # Bootstrap guard for missing modules/shared/Errors.ps1 - cannot use New-FindingError
        # because the guard runs precisely when New-FindingError is unavailable.
        'Send-FindingsToLogAnalytics.ps1' = 1
    }

    function Get-RawThrowCount {
        param ([Parameter(Mandatory)][string] $Path)
        $text = Get-Content -LiteralPath $Path -Raw
        # Broad match: count any `throw "..."` or `throw '...'` anywhere in the file
        # (top-of-line, inside catch blocks, or inline inside `if (...) { throw '...' }`).
        # Previously this regex only matched throws at start-of-line plus one
        # `catch { throw }` form, which allowed inline throws to slip past the ratchet.
        # The negative lookbehind keeps us from matching identifiers that end in "throw"
        # (there are none in the current codebase, but it future-proofs the check).
        return ([regex]::Matches($text, "(?<![a-zA-Z0-9_\-])throw\s+[`"']")).Count
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

    Context 'CON-004 - side-effecting wrappers declare SupportsShouldProcess' {
        # Wrappers that mutate cluster state (helm install/upgrade, kubectl apply)
        # MUST declare [CmdletBinding(SupportsShouldProcess=$true)] and gate
        # mutations behind $PSCmdlet.ShouldProcess(...). Add new entries here
        # whenever a wrapper grows a side effect; remove only when the side
        # effect is removed.
        $script:SideEffectingWrappers = @(
            'Invoke-Falco.ps1',
            'Invoke-AksKarpenterCost.ps1'
        )
        It '<_> declares [CmdletBinding(SupportsShouldProcess)] and calls $PSCmdlet.ShouldProcess' -ForEach $script:SideEffectingWrappers {
            $path = Join-Path $script:WrapperRoot $_
            $text = Get-Content -LiteralPath $path -Raw
            # Require SupportsShouldProcess to be enabled (bare switch or `=$true`).
            # This regex explicitly rejects `SupportsShouldProcess=$false` or `=0`.
            # The pattern matches:
            # - `SupportsShouldProcess` followed by optional `=$true`
            # - Must be followed by comma, closing paren, or another parameter
            # - Must NOT be followed by `=$false` or `=0` or any falsy value
            $text | Should -Match '\[CmdletBinding\([^\]]*SupportsShouldProcess\s*(?:=\s*\$true)?(?=\s*[,\)])' -Because "side-effecting wrapper $_ must opt into -WhatIf / -Confirm (SupportsShouldProcess enabled, not disabled)"
            # Require an actual call to $PSCmdlet.ShouldProcess(...) - the trailing `(`
            # prevents a bare mention inside a comment or string from satisfying the gate.
            $text | Should -Match '\$PSCmdlet\.ShouldProcess\s*\(' -Because "side-effecting wrapper $_ must gate mutations behind a \$PSCmdlet.ShouldProcess(...) call"
        }
    }

    Context 'Sinks - raw throw "..." ratchet (use New-FindingError instead)' {
        It '<_> raw-throw count matches sink baseline' -ForEach $script:SinkNames {
            $path     = Join-Path $script:SinkRoot $_
            $actual   = Get-RawThrowCount -Path $path
            $expected = if ($script:SinkRawThrowBaseline.ContainsKey($_)) { $script:SinkRawThrowBaseline[$_] } else { 0 }
            $actual | Should -Be $expected -Because @"
Raw `throw "..."` count for sink $_ changed.
Expected (baseline): $expected. Actual: $actual.

If the count went DOWN, update `$script:SinkRawThrowBaseline` in this test
to the new lower value (or remove the entry entirely if it dropped to 0).

If the count went UP, replace the new throw with:
  throw (Format-FindingErrorMessage (New-FindingError ...))
"@
        }
    }
}
