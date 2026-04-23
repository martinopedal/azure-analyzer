#Requires -Version 7.4
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# See tests/wrappers/Invoke-AlzQueries.Tests.ps1 header -- single-file run guard.
$env:AZURE_ANALYZER_SUPPRESS_TOOL_MISSING_WARNINGS = '1'

BeforeAll {
    $script:Here = Split-Path $PSCommandPath -Parent
    $script:RepoRoot = Resolve-Path (Join-Path $script:Here '..' '..')
    $script:Wrapper = Join-Path $script:RepoRoot 'modules' 'Invoke-PSRule.ps1'
    $script:RawFixturePath = Join-Path $script:RepoRoot 'tests' 'fixtures' 'psrule-raw-results.json'
}

Describe 'Invoke-PSRule: error paths' {
    Context 'when PSRule modules are missing' {
        BeforeAll {
            Mock Get-Module { return $null }
            $result = & $script:Wrapper -SubscriptionId '00000000-0000-0000-0000-000000000000'
        }

        It 'returns Status = Skipped' {
            $result.Status | Should -Be 'Skipped'
        }

        It 'returns empty Findings' {
            @($result.Findings).Count | Should -Be 0
        }

        It 'includes message about PSRule not installed' {
            $result.Message | Should -Match 'not installed'
        }

        It 'sets Source to psrule' {
            $result.Source | Should -Be 'psrule'
        }
    }
}

Describe 'Invoke-PSRule: success mapping' {
    BeforeAll {
        $global:RawResults = Get-Content $script:RawFixturePath -Raw | ConvertFrom-Json
        function global:Invoke-PSRule {
            [CmdletBinding()]
            param(
                [string]$Module,
                [string]$InputPath,
                [hashtable]$Option
            )
            return $global:RawResults
        }
        Mock Get-Module {
            param([string]$Name, [switch]$ListAvailable)
            if ($Name -eq 'PSRule.Rules.Azure') {
                return [PSCustomObject]@{ Name = 'PSRule.Rules.Azure'; Version = [version]'1.35.0' }
            }
            if ($Name -eq 'PSRule') {
                return [PSCustomObject]@{ Name = 'PSRule'; Version = [version]'2.9.0' }
            }
            return $null
        }
        $script:Result = & $script:Wrapper -SubscriptionId '00000000-0000-0000-0000-000000000001'
    }

    AfterAll {
        if (Test-Path Function:\global:Invoke-PSRule) {
            Remove-Item Function:\global:Invoke-PSRule -ErrorAction SilentlyContinue
        }
        Remove-Variable -Name RawResults -Scope Global -ErrorAction SilentlyContinue
    }

    It 'returns Success and findings from raw PSRule output' {
        $script:Result.Status | Should -Be 'Success'
        @($script:Result.Findings).Count | Should -Be 2
    }

    It 'maps severity from Level and keeps pass results as Info' {
        $script:Result.Findings[0].Severity | Should -Be 'High'
        $script:Result.Findings[1].Severity | Should -Be 'Info'
    }

    It 'emits schema 2.2 precursor fields in wrapper output' {
        $first = $script:Result.Findings[0]
        $first.RuleId | Should -Be 'AZR-000001'
        $first.Pillar | Should -Be 'Security'
        $first.BaselineTags | Should -Contain 'Azure.Default'
        $first.DeepLinkUrl | Should -Be 'https://azure.github.io/PSRule.Rules.Azure/en/rules/Azure.Storage.SoftDelete/'
        $first.ToolVersion | Should -Be '1.35.0'
        @($first.Frameworks).Count | Should -Be 1
        $first.Frameworks[0].Name | Should -Be 'WAF'
        $first.Frameworks[0].Controls[0] | Should -Be 'Azure.Storage.SoftDelete'
    }
}

