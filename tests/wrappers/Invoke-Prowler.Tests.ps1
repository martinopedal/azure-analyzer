#Requires -Version 7.4
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# See tests/wrappers/Invoke-AlzQueries.Tests.ps1 header -- single-file run guard.
$env:AZURE_ANALYZER_SUPPRESS_TOOL_MISSING_WARNINGS = '1'

BeforeAll {
    $script:Here = Split-Path $PSCommandPath -Parent
    $script:RepoRoot = Resolve-Path (Join-Path $script:Here '..' '..')
    $script:Wrapper = Join-Path $script:RepoRoot 'modules' 'Invoke-Prowler.ps1'
    $script:RawFixturePath = Join-Path $script:RepoRoot 'tests' 'fixtures' 'prowler-raw-findings.json'
}

Describe 'Invoke-Prowler' {
    Context 'when prowler CLI is missing' {
        BeforeAll {
            Mock Get-Command { return $null } -ParameterFilter { $Name -eq 'prowler' }
            $result = & $script:Wrapper -SubscriptionId '00000000-0000-0000-0000-000000000001'
        }

        It 'returns Status = Skipped' {
            $result.Status | Should -Be 'Skipped'
        }

        It 'returns Source = prowler' {
            $result.Source | Should -Be 'prowler'
        }

        It 'returns SchemaVersion = 1.0' {
            $result.SchemaVersion | Should -Be '1.0'
        }
    }

    Context 'when prowler output is present' {
        BeforeAll {
            $script:OutputPath = Join-Path $script:Here '..\output-test\prowler-wrapper'
            if (Test-Path $script:OutputPath) {
                Remove-Item -Path $script:OutputPath -Recurse -Force
            }
            $null = New-Item -ItemType Directory -Path $script:OutputPath -Force
            Copy-Item -Path $script:RawFixturePath -Destination (Join-Path $script:OutputPath 'prowler-test.json') -Force

            function global:prowler {
                param([Parameter(ValueFromRemainingArguments = $true)] [string[]]$Args)
                if ($Args -contains '--version') { return 'Prowler 4.8.1' }
                return ''
            }

            Mock Get-Command { [PSCustomObject]@{ Name = 'prowler' } } -ParameterFilter { $Name -eq 'prowler' }
            $script:Result = & $script:Wrapper -SubscriptionId '00000000-0000-0000-0000-000000000001' -OutputPath $script:OutputPath
        }

        AfterAll {
            Remove-Item Function:\global:prowler -ErrorAction SilentlyContinue
            if (Test-Path $script:OutputPath) {
                Remove-Item -Path $script:OutputPath -Recurse -Force
            }
        }

        It 'returns success and findings' {
            $script:Result.Status | Should -Be 'Success'
            @($script:Result.Findings).Count | Should -Be 2
        }

        It 'captures ToolVersion from prowler --version' {
            $script:Result.ToolVersion | Should -Be '4.8.1'
            $script:Result.Findings[0].ToolVersion | Should -Be '4.8.1'
        }

        It 'emits Security pillar and deep link' {
            $f = $script:Result.Findings[0]
            $f.Pillar | Should -Be 'Security'
            $f.DeepLinkUrl | Should -Match 'docs\.prowler\.com/checks/azure_storage_secure_transfer_required'
        }

        It 'maps frameworks and baseline tags from compliance baselines' {
            $f = $script:Result.Findings[0]
            @($f.Frameworks).Count | Should -BeGreaterThan 2
            @($f.Frameworks | Where-Object { $_.Name -eq 'CIS' }).Count | Should -Be 1
            $f.Frameworks[0].Controls[0] | Should -Be 'azure_storage_secure_transfer_required'
            $f.BaselineTags | Should -Contain 'baseline:cis'
            $f.BaselineTags | Should -Contain 'baseline:nist'
            $f.BaselineTags | Should -Contain 'baseline:pci-dss'
        }

        It 'passes through MITRE fields and remediation snippets' {
            $f = $script:Result.Findings[0]
            $f.MitreTactics | Should -Contain 'Defense Evasion'
            $f.MitreTechniques | Should -Contain 'T1562'
            @($f.RemediationSnippets).Count | Should -BeGreaterThan 0
            $f.RemediationSnippets[0].Type | Should -Be 'CLI'
        }
    }
}
