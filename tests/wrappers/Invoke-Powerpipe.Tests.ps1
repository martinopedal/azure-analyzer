#Requires -Version 7.4
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# See tests/wrappers/Invoke-AlzQueries.Tests.ps1 header -- single-file run guard.
$env:AZURE_ANALYZER_TEST_PRIOR_SUPPRESS = if ($null -eq $env:AZURE_ANALYZER_SUPPRESS_TOOL_MISSING_WARNINGS) { '__unset__' } else { $env:AZURE_ANALYZER_SUPPRESS_TOOL_MISSING_WARNINGS }
$env:AZURE_ANALYZER_SUPPRESS_TOOL_MISSING_WARNINGS = '1'

BeforeAll {
    $script:Here = Split-Path $PSCommandPath -Parent
    $script:RepoRoot = Resolve-Path (Join-Path $script:Here '..' '..')
    $script:Wrapper = Join-Path $script:RepoRoot 'modules' 'Invoke-Powerpipe.ps1'
}

Describe 'Invoke-Powerpipe' {
    It 'declares SubscriptionId and optional Benchmark parameters' {
        $cmd = Get-Command -Name $script:Wrapper
        $cmd.Parameters.Keys | Should -Contain 'SubscriptionId'
        $cmd.Parameters.Keys | Should -Contain 'Benchmark'
    }

    Context 'when powerpipe is missing' {
        BeforeAll {
            Mock Get-Command { return $null } -ParameterFilter { $Name -eq 'powerpipe' }
            $result = & $script:Wrapper -SubscriptionId '00000000-0000-0000-0000-000000000000'
        }

        It 'returns skipped envelope' {
            $result.Source | Should -Be 'powerpipe'
            $result.Status | Should -Be 'Skipped'
            @($result.Findings).Count | Should -Be 0
            $result.Message | Should -Match 'not installed'
        }
    }
}

AfterAll {
    if ($env:AZURE_ANALYZER_TEST_PRIOR_SUPPRESS -eq '__unset__') {
        Remove-Item Env:AZURE_ANALYZER_SUPPRESS_TOOL_MISSING_WARNINGS -ErrorAction SilentlyContinue
    } elseif ($null -ne $env:AZURE_ANALYZER_TEST_PRIOR_SUPPRESS) {
        $env:AZURE_ANALYZER_SUPPRESS_TOOL_MISSING_WARNINGS = $env:AZURE_ANALYZER_TEST_PRIOR_SUPPRESS
    }
    Remove-Item Env:AZURE_ANALYZER_TEST_PRIOR_SUPPRESS -ErrorAction SilentlyContinue
}
