#Requires -Version 7.4
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$env:AZURE_ANALYZER_TEST_PRIOR_SUPPRESS = if ($null -eq $env:AZURE_ANALYZER_SUPPRESS_TOOL_MISSING_WARNINGS) { '__unset__' } else { $env:AZURE_ANALYZER_SUPPRESS_TOOL_MISSING_WARNINGS }
$env:AZURE_ANALYZER_SUPPRESS_TOOL_MISSING_WARNINGS = '1'

BeforeAll {
    $script:Here     = Split-Path $PSCommandPath -Parent
    $script:RepoRoot = (Resolve-Path (Join-Path $script:Here '..' '..')).Path
    $script:Wrapper  = Join-Path $script:RepoRoot 'modules' 'Invoke-ConditionalAccessGraph.ps1'
}

AfterAll {
    if ($env:AZURE_ANALYZER_TEST_PRIOR_SUPPRESS -eq '__unset__') {
        Remove-Item Env:AZURE_ANALYZER_SUPPRESS_TOOL_MISSING_WARNINGS -ErrorAction SilentlyContinue
    } else {
        $env:AZURE_ANALYZER_SUPPRESS_TOOL_MISSING_WARNINGS = $env:AZURE_ANALYZER_TEST_PRIOR_SUPPRESS
    }
    Remove-Item Env:AZURE_ANALYZER_TEST_PRIOR_SUPPRESS -ErrorAction SilentlyContinue
}

Describe 'Invoke-ConditionalAccessGraph' {

    Context 'when Microsoft.Graph is not connected and no PreFetchedData supplied' {
        BeforeAll {
            $script:Result = & $script:Wrapper -WarningAction SilentlyContinue
        }

        It 'returns Status = Skipped' {
            $script:Result.Status | Should -Be 'Skipped'
        }

        It 'attaches a MissingDependency error' {
            @($script:Result.Errors).Count | Should -BeGreaterThan 0
            $script:Result.Errors[0].Category | Should -Be 'MissingDependency'
        }

        It 'sets Source = conditional-access-graph' {
            $script:Result.Source | Should -Be 'conditional-access-graph'
        }

        It 'returns SchemaVersion = 1.0' {
            $script:Result.SchemaVersion | Should -Be '1.0'
        }
    }

    Context 'when PreFetchedData is supplied with a privileged-MFA gap' {
        BeforeAll {
            # Single policy that requires MFA but excludes the Global
            # Administrator role - the most expensive CA gap and the one
            # the Critical-severity rubric exists for.
            $policy = [PSCustomObject]@{
                id          = '11111111-1111-1111-1111-111111111111'
                displayName = 'Require MFA - all users'
                state       = 'enabled'
                conditions = [PSCustomObject]@{
                    users = [PSCustomObject]@{
                        includeUsers  = @('All')
                        excludeUsers  = @()
                        includeGroups = @()
                        excludeGroups = @()
                        includeRoles  = @()
                        excludeRoles  = @('62e90394-69f5-4237-9190-012177145e10')
                    }
                    applications = [PSCustomObject]@{
                        includeApplications = @('All')
                        excludeApplications = @()
                    }
                    locations = [PSCustomObject]@{
                        includeLocations = @()
                        excludeLocations = @()
                    }
                }
                grantControls = [PSCustomObject]@{
                    operator        = 'AND'
                    builtInControls = @('mfa')
                }
            }
            $pre = [PSCustomObject]@{ Policies = @($policy) }
            $script:GapResult = & $script:Wrapper -PreFetchedData $pre -WarningAction SilentlyContinue
        }

        It 'returns Status = Success' {
            $script:GapResult.Status | Should -Be 'Success'
        }

        It 'emits a Critical finding for GA excluded from MFA' {
            $crit = @($script:GapResult.Findings | Where-Object { $_.Severity -eq 'Critical' })
            $crit.Count | Should -Be 1
            $crit[0].RuleId | Should -Be 'ca-ga-excluded-from-mfa'
        }

        It 'projects one Policies entry per input policy' {
            @($script:GapResult.Policies).Count | Should -Be 1
            $script:GapResult.Policies[0].Id | Should -Be '11111111-1111-1111-1111-111111111111'
        }

        It 'preserves Findings = @() / Errors = @() envelope shape' {
            $script:GapResult.PSObject.Properties['Findings'] | Should -Not -BeNullOrEmpty
            $script:GapResult.PSObject.Properties['Errors']   | Should -Not -BeNullOrEmpty
        }
    }

    Context 'when PreFetchedData has a disabled policy covering Global Administrator' {
        BeforeAll {
            $policy = [PSCustomObject]@{
                id          = '22222222-2222-2222-2222-222222222222'
                displayName = 'Block legacy auth (disabled)'
                state       = 'disabled'
                conditions = [PSCustomObject]@{
                    users = [PSCustomObject]@{
                        includeUsers = @()
                        includeRoles = @('62e90394-69f5-4237-9190-012177145e10')
                    }
                    applications = [PSCustomObject]@{ includeApplications = @('All') }
                    locations    = [PSCustomObject]@{ includeLocations = @() }
                }
                grantControls = [PSCustomObject]@{ builtInControls = @('block') }
            }
            $script:DisabledResult = & $script:Wrapper -PreFetchedData ([PSCustomObject]@{ Policies = @($policy) }) -WarningAction SilentlyContinue
        }

        It 'emits a High finding for disabled-covers-privileged' {
            $hi = @($script:DisabledResult.Findings | Where-Object { $_.RuleId -eq 'ca-disabled-covers-privileged' })
            $hi.Count | Should -Be 1
            $hi[0].Severity | Should -Be 'High'
        }
    }

    Context 'when PreFetchedData is empty' {
        BeforeAll {
            $script:EmptyResult = & $script:Wrapper -PreFetchedData ([PSCustomObject]@{ Policies = @() }) -WarningAction SilentlyContinue
        }

        It 'returns Status = Success with zero findings' {
            $script:EmptyResult.Status | Should -Be 'Success'
            @($script:EmptyResult.Findings).Count | Should -Be 0
        }
    }
}
