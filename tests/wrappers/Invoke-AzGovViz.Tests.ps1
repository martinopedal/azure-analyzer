#Requires -Version 7.4
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# See tests/wrappers/Invoke-AlzQueries.Tests.ps1 header -- single-file run guard.
$env:AZURE_ANALYZER_TEST_PRIOR_SUPPRESS = if ($null -eq $env:AZURE_ANALYZER_SUPPRESS_TOOL_MISSING_WARNINGS) { '__unset__' } else { $env:AZURE_ANALYZER_SUPPRESS_TOOL_MISSING_WARNINGS }
$env:AZURE_ANALYZER_SUPPRESS_TOOL_MISSING_WARNINGS = '1'

BeforeAll {
    $script:Here = Split-Path $PSCommandPath -Parent
    $script:RepoRoot = Resolve-Path (Join-Path $script:Here '..' '..')
    $script:Wrapper = Join-Path $script:RepoRoot 'modules' 'Invoke-AzGovViz.ps1'
}

Describe 'Invoke-AzGovViz: error paths' {
    Context 'when AzGovVizParallel.ps1 script is not found' {
        BeforeAll {
            $nonexistentPath = Join-Path ([System.IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString())
            # Mock environment vars and location to avoid null Join-Path
            Mock Get-Location { $nonexistentPath }
            $oldUserProfile = $env:USERPROFILE
            $oldHome = $env:HOME
            $env:USERPROFILE = $nonexistentPath
            $env:HOME = $nonexistentPath
            
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
ComplianceState,PolicyEffect,PolicyAssignmentName,PolicySetDefinitionId,PolicySetDefinitionName,MCSBControls,Scope,ResourceId
NonCompliant,Deny,Deny public IP,/providers/Microsoft.Authorization/policySetDefinitions/alz-security,Baseline Security Initiative,MCSB-NS-1;MCSB-IM-3,/subscriptions/00000000-0000-0000-0000-000000000001,/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/rg1/providers/Microsoft.Compute/virtualMachines/vm1
Compliant,Audit,Audit vnet flow logs,/providers/Microsoft.Authorization/policySetDefinitions/alz-network,Baseline Network Initiative,MCSB-NS-2,/subscriptions/00000000-0000-0000-0000-000000000001,/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/rg1/providers/Microsoft.Network/networkSecurityGroups/nsg1
"@ | Set-Content -Path (Join-Path $outputPath 'tenant_PolicyComplianceStates.csv')

            @"
RoleAssignmentIdentityObjectId,RoleAssignmentIdentityObjectType,RoleDefinitionName,RoleAssignmentScopeType,RoleAssignmentScope
11111111-1111-1111-1111-111111111111,User,Owner,Subscription,/subscriptions/00000000-0000-0000-0000-000000000001
33333333-3333-3333-3333-333333333333,ServicePrincipal,Reader,ResourceGroup,/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/rg1
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

            @"
ResourceId,EstimatedMonthlyCost
/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/rg1/providers/Microsoft.Storage/storageAccounts/orphanst01,37.50
"@ | Set-Content -Path (Join-Path $outputPath 'tenant_OrphanedResources.csv')

            @'
$script:Version = "9.9.9"
Write-Output "ok"
'@ | Set-Content -Path (Join-Path $workRoot 'AzGovVizParallel.ps1')
            Set-Content -Path (Join-Path $outputPath 'tenant-summary.html') -Value '<html><body>AzGovViz report</body></html>'

            Mock Get-Location { $workRoot }

            $result = & $script:Wrapper -ManagementGroupId 'mg-test' -OutputPath $outputPath

            $env:USERPROFILE = $oldUserProfile
            $env:HOME = $oldHome
        }

        It 'returns success' {
            $result.Status | Should -Be 'Success'
        }

        It 'ingests summary and CSV findings' {
            @($result.Findings).Count | Should -Be 6
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

        It 'adds schema 2.2 metadata for policy findings' {
            $policy = $result.Findings | Where-Object { $_.Category -eq 'Policy' } | Select-Object -First 1
            $policy.Pillar | Should -Be 'Security'
            @($policy.Frameworks).Count | Should -Be 2
            ($policy.Frameworks | Where-Object { $_.Name -eq 'ALZ' }).Count | Should -BeGreaterThan 0
            ($policy.Frameworks | Where-Object { $_.Name -eq 'CAF' }).Count | Should -BeGreaterThan 0
            $policy.BaselineTags | Should -Contain 'initiative:baseline-security-initiative'
            $policy.BaselineTags | Should -Contain 'initiative:category-policy'
            $policy.ToolVersion | Should -Be '9.9.9'
            $policy.DeepLinkUrl | Should -Match '^(https://www\.azadvertizer\.net/|https://portal\.azure\.com/)'
            @($policy.EvidenceUris).Count | Should -BeGreaterThan 0
            $policy.EvidenceUris[0] | Should -Match '#policy$'
            $policy.Impact | Should -Be 'High'
            $policy.Effort | Should -Be 'Medium'
            @($policy.RemediationSnippets).Count | Should -BeGreaterThan 0
        }

        It 'derives pillar values for governance, identity, operations and cost categories' {
            ($result.Findings | Where-Object { $_.Category -eq 'Governance' } | Select-Object -First 1).Pillar | Should -Be 'Operational Excellence'
            ($result.Findings | Where-Object { $_.Category -eq 'Identity' } | Select-Object -First 1).Pillar | Should -Be 'Security'
            ($result.Findings | Where-Object { $_.Category -eq 'Operations' } | Select-Object -First 1).Pillar | Should -Be 'Operational Excellence'
            ($result.Findings | Where-Object { $_.Category -eq 'Cost' } | Select-Object -First 1).Pillar | Should -Be 'Cost'
        }
    }

    Context 'when role assignments use legacy alias column names' {
        BeforeAll {
            $workRoot = Join-Path $TestDrive 'azgovviz-legacy'
            $outputPath = Join-Path $workRoot 'output'
            $null = New-Item -ItemType Directory -Path $outputPath -Force
            $oldUserProfile = $env:USERPROFILE
            $oldHome = $env:HOME
            $env:USERPROFILE = $workRoot
            $env:HOME = $workRoot

            @"
ObjectId,PrincipalType,RoleDefinitionName,Scope
aaaaaaaa-1111-1111-1111-111111111111,User,Owner,/subscriptions/00000000-0000-0000-0000-000000000001
"@ | Set-Content -Path (Join-Path $outputPath 'tenant_RoleAssignments.csv')
            Set-Content -Path (Join-Path $workRoot 'AzGovVizParallel.ps1') -Value "Write-Output 'ok'"

            Mock Get-Location { $workRoot }
            $result = & $script:Wrapper -ManagementGroupId 'mg-test' -OutputPath $outputPath

            $env:USERPROFILE = $oldUserProfile
            $env:HOME = $oldHome
        }

        It 'still parses legacy principal aliases' {
            ($result.Findings | Where-Object { $_.Category -eq 'Identity' }).Count | Should -Be 1
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
