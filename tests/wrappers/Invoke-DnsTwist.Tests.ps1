#Requires -Version 7.4
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Suppress the orchestrator's tool-missing warnings during contract tests.
$env:AZURE_ANALYZER_TEST_PRIOR_SUPPRESS = if ($null -eq $env:AZURE_ANALYZER_SUPPRESS_TOOL_MISSING_WARNINGS) { '__unset__' } else { $env:AZURE_ANALYZER_SUPPRESS_TOOL_MISSING_WARNINGS }
$env:AZURE_ANALYZER_SUPPRESS_TOOL_MISSING_WARNINGS = '1'

BeforeAll {
    $script:Here     = Split-Path $PSCommandPath -Parent
    $script:RepoRoot = (Resolve-Path (Join-Path $script:Here '..' '..')).Path
    $script:Wrapper  = Join-Path $script:RepoRoot 'modules' 'Invoke-DnsTwist.ps1'
}

AfterAll {
    if ($env:AZURE_ANALYZER_TEST_PRIOR_SUPPRESS -eq '__unset__') {
        Remove-Item Env:AZURE_ANALYZER_SUPPRESS_TOOL_MISSING_WARNINGS -ErrorAction SilentlyContinue
    } else {
        $env:AZURE_ANALYZER_SUPPRESS_TOOL_MISSING_WARNINGS = $env:AZURE_ANALYZER_TEST_PRIOR_SUPPRESS
    }
    Remove-Item Env:AZURE_ANALYZER_TEST_PRIOR_SUPPRESS -ErrorAction SilentlyContinue
}

Describe 'Invoke-DnsTwist' -Tag 'AllowsWarning' {

    Context 'when dnstwist CLI is missing' {
        BeforeAll {
            Mock Get-Command { return $null } -ParameterFilter { $Name -eq 'dnstwist' }
            $script:Result = & $script:Wrapper -WarningAction SilentlyContinue
        }

        It 'returns Status = Skipped' {
            $script:Result.Status | Should -Be 'Skipped'
        }

        It 'returns empty Findings array' {
            @($script:Result.Findings).Count | Should -Be 0
        }

        It 'attaches a MissingDependency error' {
            @($script:Result.Errors).Count | Should -BeGreaterThan 0
            $script:Result.Errors[0].Category | Should -Be 'MissingDependency'
        }

        It 'sets Source = dnstwist' {
            $script:Result.Source | Should -Be 'dnstwist'
        }

        It 'returns SchemaVersion = 1.0' {
            $script:Result.SchemaVersion | Should -Be '1.0'
        }
    }

    Context 'when dnstwist is installed but seed is empty' {
        BeforeAll {
            # dnstwist appears installed, but seed has no domains.
            Mock Get-Command { [PSCustomObject]@{ Name = 'dnstwist' } } -ParameterFilter { $Name -eq 'dnstwist' }
            $script:EmptyResult = & $script:Wrapper -Seed @{ Domains = @() } -WarningAction SilentlyContinue
        }

        It 'returns Status = Skipped' {
            $script:EmptyResult.Status | Should -Be 'Skipped'
        }

        It 'message mentions empty seed' {
            $script:EmptyResult.Message | Should -Match 'no domains'
        }
    }
}

Describe 'Get-DnsTwistFinding (pure helper)' {
    BeforeAll {
        # Dot-source the real implementation so the test exercises it
        # directly. Re-declaring an inline copy would let the two drift
        # apart silently; using the shared module keeps them in lockstep.
        $helperPath = Join-Path $script:RepoRoot 'modules' 'shared' 'DnsTwistHelpers.ps1'
        . $helperPath
    }

    It 'skips the original* synthetic record' {
        $r = [PSCustomObject]@{ fuzzer='original*'; domain='contoso.com'; dns_a=@('1.2.3.4') }
        Get-DnsTwistFinding -Record $r -SeedDomain 'contoso.com' | Should -Be $null
    }

    It 'flags homoglyph + registered as High severity' {
        $r = [PSCustomObject]@{ fuzzer='homoglyph'; domain='c0ntoso.com'; dns_a=@('1.2.3.4') }
        (Get-DnsTwistFinding -Record $r -SeedDomain 'contoso.com').Severity | Should -Be 'High'
    }

    It 'flags non-homoglyph + registered as Medium' {
        $r = [PSCustomObject]@{ fuzzer='typo'; domain='contso.com'; dns_a=@('1.2.3.4') }
        (Get-DnsTwistFinding -Record $r -SeedDomain 'contoso.com').Severity | Should -Be 'Medium'
    }

    It 'flags registered-but-not-resolving as Low' {
        $r = [PSCustomObject]@{ fuzzer='tld-swap'; domain='contoso.co' }
        (Get-DnsTwistFinding -Record $r -SeedDomain 'contoso.com').Severity | Should -Be 'Low'
    }
}
