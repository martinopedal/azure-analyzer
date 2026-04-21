#Requires -Version 7.4
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

BeforeAll {
    $script:Here = Split-Path $PSCommandPath -Parent
    $script:RepoRoot = Resolve-Path (Join-Path $script:Here '..' '..')
    $script:Wrapper = Join-Path $script:RepoRoot 'modules' 'Invoke-DefenderForCloud.ps1'
}

Describe 'Invoke-DefenderForCloud: error paths' {
    Context 'when Az.Accounts module is missing' {
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

        It 'includes message about Az.Accounts not installed' {
            $result.Message | Should -Match 'not installed'
        }
    }

    Context 'when not signed in to Azure' {
        BeforeAll {
            Mock Get-Module { [PSCustomObject]@{ Name = 'Az.Accounts' } }
            Mock Get-AzContext { return $null }
            $result = & $script:Wrapper -SubscriptionId '00000000-0000-0000-0000-000000000000'
        }

        It 'returns Status = Skipped' {
            $result.Status | Should -Be 'Skipped'
        }

        It 'includes message about signing in' {
            $result.Message | Should -Match 'Not signed in'
        }
    }

    Context 'when Defender API call fails' {
        BeforeAll {
            Mock Get-Module { [PSCustomObject]@{ Name = 'Az.Accounts' } }
            Mock Get-AzContext { [PSCustomObject]@{ Account = 'user@test.com' } }
            Mock Invoke-AzRestMethod { throw 'API call failed' }
            $result = & $script:Wrapper -SubscriptionId '00000000-0000-0000-0000-000000000000'
        }

        It 'returns Status = Failed' {
            $result.Status | Should -Be 'Failed'
        }

        It 'includes error message' {
            $result.Message | Should -Not -BeNullOrEmpty
        }
    }
}

Describe 'Invoke-DefenderForCloud: schema 2.2 capture' {
    BeforeAll {
        Mock Get-Module { [PSCustomObject]@{ Name = 'Az.Accounts' } }
        Mock Get-AzContext { [PSCustomObject]@{ Account = 'user@test.com' } }

        Mock Invoke-AzRestMethod -ParameterFilter { $Uri -like '*secureScores/ascScore*' } {
            [PSCustomObject]@{
                StatusCode = 200
                Content = '{"properties":{"score":{"current":42,"max":60}}}'
            }
        }
        Mock Invoke-AzRestMethod -ParameterFilter { $Uri -like '*providers/Microsoft.Security/assessments*' } {
            [PSCustomObject]@{
                StatusCode = 200
                Content = '{"value":[{"name":"assess-aad-mfa","properties":{"status":{"code":"Unhealthy"},"resourceDetails":{"id":"/subscriptions/11111111-1111-1111-1111-111111111111"},"displayName":"MFA check","metadata":{"severity":"High","description":"desc","remediationDescription":"fix","additionalData":{"standard":"MCSB LT-1, ISO27001"}},"links":{"azurePortal":"https://portal.azure.com/#assessment"}}}]}'
            }
        }
        Mock Invoke-AzRestMethod -ParameterFilter { $Uri -like '*providers/Microsoft.Security/alerts*' } {
            [PSCustomObject]@{
                StatusCode = 200
                Content = '{"value":[{"id":"/subscriptions/11111111-1111-1111-1111-111111111111/providers/Microsoft.Security/locations/westeurope/alerts/alert-1","name":"alert-1","properties":{"severity":"High","status":"Active","alertDisplayName":"Alert title","description":"Alert detail","resourceIdentifiers":{"AzureResourceId":"/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/prod/providers/Microsoft.Storage/storageAccounts/mystor"},"tactics":["InitialAccess"],"techniques":["T1078"],"extendedProperties":{"control":"MCSB DP-3","portal":"https://security.microsoft.com/alerts/alert-1","compliance":"PCI"}}}]}'
            }
        }
        $script:SuccessResult = & $script:Wrapper -SubscriptionId '11111111-1111-1111-1111-111111111111'
    }

    It 'returns success and includes assessment and alert findings' {
        $script:SuccessResult.Status | Should -Be 'Success'
        @($script:SuccessResult.Findings).Count | Should -Be 3
    }

    It 'captures Schema 2.2 fields on assessment findings' {
        $assessment = @($script:SuccessResult.Findings) | Where-Object { $_.AssessmentId -eq 'assess-aad-mfa' }
        $assessment.Pillar | Should -Be 'Security'
        $assessment.ToolVersion | Should -Be 'microsoft.security/rest-2020-01-01+2022-01-01-preview'
        @($assessment.Frameworks).Count | Should -BeGreaterThan 0
        @($assessment.EvidenceUris).Count | Should -BeGreaterThan 0
        $assessment.DeepLinkUrl | Should -Match 'portal.azure.com'
    }

    It 'captures MITRE and framework metadata on alert findings' {
        $alert = @($script:SuccessResult.Findings) | Where-Object { $_.AlertId -eq 'alert-1' }
        @($alert.MitreTactics) | Should -Contain 'InitialAccess'
        @($alert.MitreTechniques) | Should -Contain 'T1078'
        @($alert.Frameworks | ForEach-Object { $_.kind }) | Should -Contain 'MCSB'
        @($alert.Frameworks | ForEach-Object { $_.kind }) | Should -Contain 'PCI'
        $alert.DeepLinkUrl | Should -Match 'SecurityMenuBlade'
        @($alert.EvidenceUris) | Should -Contain 'https://security.microsoft.com/alerts/alert-1'
    }
}

