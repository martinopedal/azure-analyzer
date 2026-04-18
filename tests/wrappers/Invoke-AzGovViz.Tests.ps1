#Requires -Version 7.4
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

BeforeAll {
    $script:Here = Split-Path $PSCommandPath -Parent
    $script:RepoRoot = Resolve-Path (Join-Path $script:Here '..' '..')
    $script:Wrapper = Join-Path $script:RepoRoot 'modules' 'Invoke-AzGovViz.ps1'
}

Describe 'Invoke-AzGovViz: error paths' {
    Context 'when AzGovVizParallel.ps1 script is not found' {
        BeforeAll {
            # Mock environment vars and location to avoid null Join-Path
            Mock Get-Location { 'C:\NonExistent' }
            $oldUserProfile = $env:USERPROFILE
            $oldHome = $env:HOME
            $env:USERPROFILE = 'C:\NonExistent'
            $env:HOME = 'C:\NonExistent'
            
            $result = & $script:Wrapper -ManagementGroupId 'mg-test'
            
            # Restore
            $env:USERPROFILE = $oldUserProfile
            $env:HOME = $oldHome
        }

        It 'returns Status = Skipped' {
            $result.Status | Should -Be 'Skipped'
        }

        It 'returns empty Findings' {
            @($result.Findings).Count | Should -Be 0
        }

        It 'includes message about AzGovViz not found' {
            $result.Message | Should -Match 'not found'
        }

        It 'sets Source to azgovviz' {
            $result.Source | Should -Be 'azgovviz'
        }
    }
}

Describe 'Invoke-AzGovViz: CSV ingestion' {
    Context 'when summary and supported CSV outputs are present' {
        BeforeAll {
            $workRoot = Join-Path $TestDrive 'azgovviz'
            $outputPath = Join-Path $workRoot 'output'
            $null = New-Item -ItemType Directory -Path $outputPath -Force
            $oldUserProfile = $env:USERPROFILE
            $oldHome = $env:HOME
            $env:USERPROFILE = $workRoot
            $env:HOME = $workRoot

            $summary = @(
                @{
                    Source        = 'azgovviz'
                    ResourceId    = '/subscriptions/00000000-0000-0000-0000-000000000001'
                    Category      = 'Governance'
                    Title         = 'Summary finding'
                    Compliant     = $false
                    Severity      = 'Medium'
                    SchemaVersion = '1.0'
                }
            ) | ConvertTo-Json
            Set-Content -Path (Join-Path $outputPath 'tenantSummary.json') -Value $summary

            @"
ComplianceState,PolicyEffect,PolicyAssignmentName,Scope,ResourceId
NonCompliant,Deny,Deny public IP,/subscriptions/00000000-0000-0000-0000-000000000001,/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/rg1/providers/Microsoft.Compute/virtualMachines/vm1
Compliant,Audit,Audit vnet flow logs,/subscriptions/00000000-0000-0000-0000-000000000001,/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/rg1/providers/Microsoft.Network/networkSecurityGroups/nsg1
"@ | Set-Content -Path (Join-Path $outputPath 'tenant_PolicyComplianceStates.csv')

            @"
ObjectId,PrincipalType,RoleDefinitionName,Scope
11111111-1111-1111-1111-111111111111,User,Owner,/subscriptions/00000000-0000-0000-0000-000000000001
33333333-3333-3333-3333-333333333333,ServicePrincipal,Reader,/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/rg1
"@ | Set-Content -Path (Join-Path $outputPath 'tenant_RoleAssignments.csv')

            @"
ResourceId,DiagnosticsCapable,DiagnosticsConfigured
/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/rg1/providers/Microsoft.Storage/storageAccounts/stprod01,true,false
/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/rg1/providers/Microsoft.Compute/virtualMachines/vm2,true,true
"@ | Set-Content -Path (Join-Path $outputPath 'tenant_ResourceDiagnosticsCapabilities.csv')

            @"
ResourceId,MissingTags
/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/rg1/providers/Microsoft.Network/publicIPAddresses/pip1,Owner;Environment
"@ | Set-Content -Path (Join-Path $outputPath 'tenant_ResourcesWithoutTags.csv')

            Set-Content -Path (Join-Path $workRoot 'AzGovVizParallel.ps1') -Value "Write-Output 'ok'"

            Mock Get-Location { $workRoot }

            $result = & $script:Wrapper -ManagementGroupId 'mg-test' -OutputPath $outputPath

            $env:USERPROFILE = $oldUserProfile
            $env:HOME = $oldHome
        }

        It 'returns success' {
            $result.Status | Should -Be 'Success'
        }

        It 'ingests summary and CSV findings' {
            @($result.Findings).Count | Should -Be 5
        }

        It 'maps policy effect Deny to High severity' {
            $policy = $result.Findings | Where-Object { $_.Category -eq 'Policy' } | Select-Object -First 1
            $policy | Should -Not -BeNullOrEmpty
            $policy.Severity | Should -Be 'High'
            $policy.Compliant | Should -BeFalse
        }

        It 'emits identity findings with principal metadata' {
            $rbac = $result.Findings | Where-Object { $_.Category -eq 'Identity' } | Select-Object -First 1
            $rbac | Should -Not -BeNullOrEmpty
            $rbac.PrincipalId | Should -Be '11111111-1111-1111-1111-111111111111'
            $rbac.PrincipalType | Should -Be 'User'
        }

        It 'filters compliant CSV rows' {
            ($result.Findings | Where-Object { $_.Category -eq 'Policy' }).Count | Should -Be 1
            ($result.Findings | Where-Object { $_.Category -eq 'Identity' }).Count | Should -Be 1
            ($result.Findings | Where-Object { $_.Category -eq 'Operations' }).Count | Should -Be 1
        }
    }
}
