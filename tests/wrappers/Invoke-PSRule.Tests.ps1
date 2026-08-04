#Requires -Version 7.4
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# See tests/wrappers/Invoke-AlzQueries.Tests.ps1 header -- single-file run guard.
$env:AZURE_ANALYZER_TEST_PRIOR_SUPPRESS = if ($null -eq $env:AZURE_ANALYZER_SUPPRESS_TOOL_MISSING_WARNINGS) { '__unset__' } else { $env:AZURE_ANALYZER_SUPPRESS_TOOL_MISSING_WARNINGS }
$env:AZURE_ANALYZER_SUPPRESS_TOOL_MISSING_WARNINGS = '1'

BeforeAll {
    $script:Here = Split-Path $PSCommandPath -Parent
    $script:RepoRoot = Resolve-Path (Join-Path $script:Here '..' '..')
    $script:Wrapper = Join-Path $script:RepoRoot 'modules' 'Invoke-PSRule.ps1'
    $script:RawFixturePath = Join-Path $script:RepoRoot 'tests' 'fixtures' 'psrule-raw-results.json'
}

AfterAll {
    if ($env:AZURE_ANALYZER_TEST_PRIOR_SUPPRESS -eq '__unset__') {
        Remove-Item Env:AZURE_ANALYZER_SUPPRESS_TOOL_MISSING_WARNINGS -ErrorAction SilentlyContinue
    } else {
        $env:AZURE_ANALYZER_SUPPRESS_TOOL_MISSING_WARNINGS = $env:AZURE_ANALYZER_TEST_PRIOR_SUPPRESS
    }
    Remove-Item Env:AZURE_ANALYZER_TEST_PRIOR_SUPPRESS -ErrorAction SilentlyContinue
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
        # Subscription mode exports resources to JSON via Export-AzRuleData and then scans
        # that directory. The stub writes a real file so the wrapper's empty-export guard is
        # exercised honestly rather than bypassed.
        function global:Export-AzRuleData {
            param($Subscription, $OutputPath, $Tenant, $ErrorAction, $WarningAction)
            $null = New-Item -ItemType Directory -Path $OutputPath -Force
            '[]' | Set-Content -Path (Join-Path $OutputPath 'resources.json') -Encoding UTF8
        }
        function global:Get-AzSubscription {
            param($SubscriptionId, $ErrorAction)
            [PSCustomObject]@{ Id = $SubscriptionId; TenantId = '00000000-0000-0000-0000-0000000000aa' }
        }
        $script:Result = & $script:Wrapper -SubscriptionId '00000000-0000-0000-0000-000000000001'
    }

    AfterAll {
        if (Test-Path Function:\global:Invoke-PSRule) {
            Remove-Item Function:\global:Invoke-PSRule -ErrorAction SilentlyContinue
        }
        foreach ($fn in 'Export-AzRuleData', 'Get-AzSubscription') {
            if (Test-Path "Function:\global:$fn") { Remove-Item "Function:\global:$fn" -ErrorAction SilentlyContinue }
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

Describe 'Invoke-PSRule: subscription export path' {
    BeforeAll {
        Mock Get-Module {
            param([string]$Name, [switch]$ListAvailable)
            if ($Name -eq 'PSRule.Rules.Azure') { return [PSCustomObject]@{ Name = 'PSRule.Rules.Azure'; Version = [version]'1.35.0' } }
            if ($Name -eq 'PSRule') { return [PSCustomObject]@{ Name = 'PSRule'; Version = [version]'2.9.0' } }
            return $null
        }
        function global:Get-AzSubscription {
            param($SubscriptionId, $ErrorAction)
            [PSCustomObject]@{ Id = $SubscriptionId; TenantId = '00000000-0000-0000-0000-0000000000bb' }
        }
    }

    AfterAll {
        foreach ($fn in 'Export-AzRuleData', 'Get-AzSubscription', 'Invoke-PSRule') {
            if (Test-Path "Function:\global:$fn") { Remove-Item "Function:\global:$fn" -ErrorAction SilentlyContinue }
        }
        Remove-Variable -Name ExportArgs -Scope Global -ErrorAction SilentlyContinue
    }

    Context 'when the export yields resource data' {
        BeforeAll {
            $global:ExportArgs = $null
            function global:Export-AzRuleData {
                param($Subscription, $OutputPath, $Tenant, $ErrorAction, $WarningAction)
                $global:ExportArgs = @{ Subscription = $Subscription; OutputPath = $OutputPath; Tenant = $Tenant }
                $null = New-Item -ItemType Directory -Path $OutputPath -Force
                '[]' | Set-Content -Path (Join-Path $OutputPath 'resources.json') -Encoding UTF8
            }
            # TargetName here is a bare resource name, as PSRule emits for exported data.
            # The ARM id lives on TargetObject, which is why ResourceId must read it.
            function global:Invoke-PSRule {
                [CmdletBinding()]
                param([string]$Module, [string]$InputPath, [hashtable]$Option)
                return @([PSCustomObject]@{
                        RuleName     = 'Azure.Storage.SoftDelete'
                        RuleId       = 'AZR-000001'
                        Outcome      = 'Fail'
                        Level        = 'Error'
                        TargetName   = 'stprod001'
                        TargetObject = [PSCustomObject]@{ id = '/subscriptions/00000000-0000-0000-0000-000000000009/resourceGroups/rg/providers/Microsoft.Storage/storageAccounts/stprod001' }
                        Detail       = [PSCustomObject]@{ Reason = @('no soft delete') }
                        Info         = [PSCustomObject]@{ DisplayName = 'Soft delete'; Recommendation = ''; Baseline = @('Azure.Default'); Annotations = $null }
                    })
            }
            $script:ExportResult = & $script:Wrapper -SubscriptionId '00000000-0000-0000-0000-000000000009'
        }

        It 'scans the exported data instead of returning nothing' {
            $script:ExportResult.Status | Should -Be 'Success'
            @($script:ExportResult.Findings).Count | Should -Be 1
        }

        It 'reads ResourceId from TargetObject when TargetName is not an ARM id' {
            $script:ExportResult.Findings[0].ResourceId | Should -Be '/subscriptions/00000000-0000-0000-0000-000000000009/resourceGroups/rg/providers/Microsoft.Storage/storageAccounts/stprod001'
        }

        It 'scopes the export to the tenant that owns the target subscription' {
            $global:ExportArgs.Subscription | Should -Be '00000000-0000-0000-0000-000000000009'
            $global:ExportArgs.Tenant | Should -Be '00000000-0000-0000-0000-0000000000bb'
        }
    }

    Context 'when the export produces no resource data' {
        BeforeAll {
            function global:Export-AzRuleData {
                param($Subscription, $OutputPath, $Tenant, $ErrorAction, $WarningAction)
                $null = New-Item -ItemType Directory -Path $OutputPath -Force
            }
            function global:Invoke-PSRule {
                [CmdletBinding()]
                param([string]$Module, [string]$InputPath, [hashtable]$Option)
                return @()
            }
            $script:EmptyResult = & $script:Wrapper -SubscriptionId '00000000-0000-0000-0000-000000000008'
        }

        It 'fails loudly rather than reporting a clean empty scan' {
            $script:EmptyResult.Status | Should -Be 'Failed'
            $script:EmptyResult.Message | Should -Match 'no resource data'
        }
    }
}
