#Requires -Version 7.4
Set-StrictMode -Version Latest

BeforeAll {
    $repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..')
    . (Join-Path $repoRoot 'modules\shared\Canonicalize.ps1')
    . (Join-Path $repoRoot 'modules\shared\Schema.ps1')
    . (Join-Path $repoRoot 'modules\shared\EntityStore.ps1')
    . (Join-Path $repoRoot 'modules\normalizers\Normalize-AzGovViz.ps1')
}

Describe 'Normalize-AzGovViz' {
    BeforeAll {
        $fixture = Get-Content (Join-Path $PSScriptRoot '..\fixtures\azgovviz-output.json') -Raw | ConvertFrom-Json
        $failedFixture = Get-Content (Join-Path $PSScriptRoot '..\fixtures\failed-output.json') -Raw | ConvertFrom-Json
    }

    Context 'v3 schema conversion' {
        BeforeAll {
            $results = Normalize-AzGovViz -ToolResult $fixture
        }

        It 'returns the correct number of findings' {
            @($results).Count | Should -Be 7
        }

        It 'sets SchemaVersion to 2.0' {
            foreach ($r in $results) {
                $r.SchemaVersion | Should -Be '2.2'
            }
        }

        It 'sets Source to azgovviz' {
            foreach ($r in $results) {
                $r.Source | Should -Be 'azgovviz'
            }
        }

        It 'sets Platform to Azure for AzGovViz findings including RBAC identities' {
            foreach ($r in $results) {
                $r.Platform | Should -Be 'Azure'
            }
        }
    }

    Context 'entity type mapping' {
        BeforeAll {
            $results = Normalize-AzGovViz -ToolResult $fixture
        }

        It 'maps subscription-scoped findings to Subscription EntityType' {
            $subFinding = $results | Where-Object { $_.Title -eq 'Subscription has no resource locks configured' }
            $subFinding | Should -Not -BeNullOrEmpty
            $subFinding.EntityType | Should -Be 'Subscription'
        }

        It 'maps governance findings without ResourceId to ManagementGroup EntityType' {
            $mgFinding = $results | Where-Object { $_.Title -eq 'Management group has orphaned custom policy definitions' }
            $mgFinding | Should -Not -BeNullOrEmpty
            $mgFinding.EntityType | Should -Be 'ManagementGroup'
            $mgFinding.EntityId | Should -Be '/providers/microsoft.management/managementgroups/mg-platform'
        }

        It 'maps RBAC user findings to User EntityType with canonical objectId format' {
            $rbacFinding = $results | Where-Object { $_.Category -eq 'Identity' -and $_.Title -eq 'Role assignment: Owner' } | Select-Object -First 1
            $rbacFinding | Should -Not -BeNullOrEmpty
            $rbacFinding.EntityType | Should -Be 'User'
            $rbacFinding.EntityId | Should -Be 'objectId:11111111-1111-1111-1111-111111111111'
        }

        It 'maps diagnostics and tag findings to AzureResource EntityType' {
            $resourceFindings = $results | Where-Object { $_.Category -in @('Operations', 'Governance') -and $_.Title -match 'Resource (diagnostics settings configured|missing required tags)' }
            $resourceFindings | Should -Not -BeNullOrEmpty
            foreach ($finding in $resourceFindings) {
                $finding.EntityType | Should -Be 'AzureResource'
            }
        }

        It 'uses stable canonical IDs for MG findings (not random GUIDs)' {
            $mgFinding = $results | Where-Object { $_.EntityType -eq 'ManagementGroup' }
            $mgFinding | Should -Not -BeNullOrEmpty
            $mgFinding.EntityId | Should -Match '^/providers/microsoft\.management/managementgroups/'
            $mgFinding.EntityId | Should -Not -Match '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'
        }
    }

    Context 'CanonicalId normalization' {
        BeforeAll {
            $results = Normalize-AzGovViz -ToolResult $fixture
        }

        It 'keeps EntityId canonical per entity type' {
            foreach ($r in $results) {
                $canonical = (ConvertTo-CanonicalEntityId -RawId $r.EntityId -EntityType $r.EntityType).CanonicalId
                $r.EntityId | Should -BeExactly $canonical
            }
        }
    }

    Context 'subscription parsing' {
        BeforeAll {
            $results = Normalize-AzGovViz -ToolResult $fixture
        }

        It 'parses SubscriptionId for subscription-scoped findings' {
            $withSub = @($results | Where-Object { $_.SubscriptionId })
            $withSub.Count | Should -BeGreaterThan 0
            $withSub[0].SubscriptionId | Should -Be '00000000-0000-0000-0000-000000000001'
        }
    }

    Context 'field preservation' {
        BeforeAll {
            $results = Normalize-AzGovViz -ToolResult $fixture
        }

        It 'preserves Compliant boolean correctly' {
            foreach ($r in $results) {
                $r.Compliant | Should -BeFalse
            }
        }

        It 'preserves Severity values' {
            ($results | Where-Object { $_.Title -eq 'Subscription has no resource locks configured' }).Severity | Should -Be 'Medium'
            ($results | Where-Object { $_.Title -eq 'Management group has orphaned custom policy definitions' }).Severity | Should -Be 'Low'
            ($results | Where-Object { $_.Title -eq 'Role assignment: Owner' }).Severity | Should -Be 'High'
            ($results | Where-Object { $_.Title -eq 'Resource diagnostics settings not configured' }).Severity | Should -Be 'Medium'
            ($results | Where-Object { $_.Title -eq 'Subscription missing monthly budget alert' }).Severity | Should -Be 'Medium'
        }

        It 'preserves Category values' {
            ($results | Where-Object { $_.Title -eq 'Subscription has no resource locks configured' }).Category | Should -Be 'Governance'
            ($results | Where-Object { $_.Title -eq 'Management group has orphaned custom policy definitions' }).Category | Should -Be 'Policy'
            ($results | Where-Object { $_.Title -eq 'Role assignment: Owner' }).Category | Should -Be 'Identity'
            ($results | Where-Object { $_.Title -eq 'Resource diagnostics settings not configured' }).Category | Should -Be 'Operations'
            ($results | Where-Object { $_.Title -eq 'Subscription missing monthly budget alert' }).Category | Should -Be 'Cost'
        }

        It 'preserves Title' {
            $results[0].Title | Should -Not -BeNullOrEmpty
        }

        It 'emits schema 2.2 fields through New-FindingRow' {
            $policyFinding = $results | Where-Object { $_.Title -eq 'Policy compliance state: Deny public IP on workloads' } | Select-Object -First 1
            $policyFinding | Should -Not -BeNullOrEmpty
            $policyFinding.Pillar | Should -Be 'Security'
            @($policyFinding.Frameworks).Count | Should -BeGreaterThan 0
            @($policyFinding.BaselineTags).Count | Should -BeGreaterThan 0
            @($policyFinding.EvidenceUris).Count | Should -BeGreaterThan 0
            $policyFinding.DeepLinkUrl | Should -Match '^https://portal\.azure\.com/'
            $policyFinding.ToolVersion | Should -Be '9.9.9'
        }

        It 'maps schema 2.2 impact, effort, remediation snippets and MITRE context' {
            $policyFinding = $results | Where-Object { $_.Title -eq 'Management group has orphaned custom policy definitions' } | Select-Object -First 1
            $policyFinding | Should -Not -BeNullOrEmpty
            $policyFinding.Impact | Should -Be 'High'
            $policyFinding.Effort | Should -Be 'Medium'
            @($policyFinding.RemediationSnippets).Count | Should -BeGreaterThan 0
            $policyFinding.RemediationSnippets[0].language | Should -Be 'text'
            $policyFinding.ScoreDelta | Should -Be (-1.5)
            @($policyFinding.MitreTactics) | Should -Contain 'Defense Evasion'
            @($policyFinding.MitreTechniques) | Should -Contain 'T1562'
            @($policyFinding.EntityRefs).Count | Should -BeGreaterThan 0
            @($policyFinding.BaselineTags) | Should -Contain 'initiative:category-policy'
        }

        It 'derives pillar values across azgovviz categories' {
            ($results | Where-Object { $_.Category -eq 'Governance' } | Select-Object -First 1).Pillar | Should -Be 'Operational Excellence'
            ($results | Where-Object { $_.Category -eq 'Policy' } | Select-Object -First 1).Pillar | Should -Be 'Security'
            ($results | Where-Object { $_.Category -eq 'Cost' } | Select-Object -First 1).Pillar | Should -Be 'Cost'
            ($results | Where-Object { $_.Category -eq 'Identity' } | Select-Object -First 1).Pillar | Should -Be 'Security'
        }
    }

    Context 'entity dedup through EntityStore' {
        It 'merges subscription and management-group entities across repeated findings' {
            $results = Normalize-AzGovViz -ToolResult $fixture
            $storePath = Join-Path $TestDrive 'entity-dedup'
            $store = [EntityStore]::new(1000, $storePath)
            try {
                foreach ($finding in $results) {
                    $store.AddFinding($finding)
                }

                $entities = @($store.GetEntities())
                @($entities | Where-Object { $_.EntityType -eq 'Subscription' -and $_.EntityId -eq '00000000-0000-0000-0000-000000000001' }).Count | Should -Be 1
                @($entities | Where-Object { $_.EntityType -eq 'ManagementGroup' -and $_.EntityId -eq '/providers/microsoft.management/managementgroups/mg-platform' }).Count | Should -Be 1
            } finally {
                if ($null -ne $store) {
                    $store.CleanupSpillFiles()
                }
            }
        }
    }

    Context 'error handling' {
        It 'returns empty array for failed tool output' {
            $results = Normalize-AzGovViz -ToolResult $failedFixture
            @($results).Count | Should -Be 0
        }

        It 'returns empty array for null Findings' {
            $emptyResult = [PSCustomObject]@{ Source = 'azgovviz'; Status = 'Success'; Findings = $null }
            $results = Normalize-AzGovViz -ToolResult $emptyResult
            @($results).Count | Should -Be 0
        }

        It 'returns empty array for empty Findings' {
            $emptyResult = [PSCustomObject]@{ Source = 'azgovviz'; Status = 'Success'; Findings = @() }
            $results = Normalize-AzGovViz -ToolResult $emptyResult
            @($results).Count | Should -Be 0
        }

        It 'handles missing optional fields gracefully' {
            $minimalInput = [PSCustomObject]@{
                Source   = 'azgovviz'
                Status   = 'Success'
                Findings = @(
                    [PSCustomObject]@{
                        Source       = 'azgovviz'
                        ResourceId   = '/subscriptions/00000000-0000-0000-0000-000000000001'
                        Category     = 'Governance'
                        Title        = 'Test governance finding'
                        Compliant    = $false
                        Severity     = 'Medium'
                        Detail       = 'Test detail'
                        SchemaVersion = '1.0'
                    }
                )
            }
            $results = Normalize-AzGovViz -ToolResult $minimalInput
            @($results).Count | Should -Be 1
        }

        It 'maps service principal RBAC findings to ServicePrincipal EntityType' {
            $spInput = [PSCustomObject]@{
                Source   = 'azgovviz'
                Status   = 'Success'
                Findings = @(
                    [PSCustomObject]@{
                        Source        = 'azgovviz'
                        ResourceId    = '/subscriptions/00000000-0000-0000-0000-000000000001'
                        Category      = 'Identity'
                        Title         = 'Role assignment: Contributor'
                        Compliant     = $false
                        Severity      = 'High'
                        PrincipalId   = '22222222-2222-2222-2222-222222222222'
                        PrincipalType = 'ServicePrincipal'
                        SchemaVersion = '1.0'
                    }
                )
            }

            $results = Normalize-AzGovViz -ToolResult $spInput
            @($results).Count | Should -Be 1
            $results[0].EntityType | Should -Be 'ServicePrincipal'
            $results[0].EntityId | Should -Be 'objectId:22222222-2222-2222-2222-222222222222'
        }
    }

    Context 'policy edge emission via EdgeCollector' {
        It 'emits PolicyAssignedTo, PolicyEnforces, ExemptedFrom and InheritsFrom edges' {
            $edgeCollector = [System.Collections.Generic.List[psobject]]::new()
            $input = [pscustomobject]@{
                Source = 'azgovviz'
                Status = 'Success'
                Findings = @(
                    [pscustomobject]@{
                        Source = 'azgovviz'
                        ResourceId = '/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/rg-prod/providers/Microsoft.Compute/virtualMachines/vm1'
                        Scope = '/subscriptions/00000000-0000-0000-0000-000000000001'
                        ParentScopeId = '/providers/Microsoft.Management/managementGroups/mg-platform'
                        Category = 'Policy'
                        Title = 'Policy compliance state'
                        Compliant = $false
                        Severity = 'High'
                        PolicyAssignmentId = '/providers/Microsoft.Authorization/policyAssignments/pa-demo'
                        PolicyDefinitionId = '/providers/Microsoft.Authorization/policyDefinitions/pd-demo'
                        PolicyExemptionId = '/providers/Microsoft.Authorization/policyExemptions/pe-demo'
                        SchemaVersion = '1.0'
                    }
                )
            }

            $rows = Normalize-AzGovViz -ToolResult $input -EdgeCollector $edgeCollector
            @($rows).Count | Should -Be 1
            @($edgeCollector).Count | Should -BeGreaterThan 0

            $relations = @($edgeCollector | Select-Object -ExpandProperty Relation -Unique)
            $relations | Should -Contain 'PolicyAssignedTo'
            $relations | Should -Contain 'PolicyEnforces'
            $relations | Should -Contain 'ExemptedFrom'
            $relations | Should -Contain 'InheritsFrom'

            $assignmentLower = '/providers/microsoft.authorization/policyassignments/pa-demo'
            $definitionLower = '/providers/microsoft.authorization/policydefinitions/pd-demo'
            $resourceLower = '/subscriptions/00000000-0000-0000-0000-000000000001/resourcegroups/rg-prod/providers/microsoft.compute/virtualmachines/vm1'
            $parentScopeLower = '/providers/microsoft.management/managementgroups/mg-platform'

            $policyAssignedToEdge = @($edgeCollector | Where-Object { $_.Relation -eq 'PolicyAssignedTo' })
            $policyAssignedToEdge.Count | Should -Be 1
            $policyAssignedToEdge[0].Source | Should -Be $assignmentLower

            $policyEnforcesEdge = @($edgeCollector | Where-Object { $_.Relation -eq 'PolicyEnforces' })
            $policyEnforcesEdge.Count | Should -Be 1
            $policyEnforcesEdge[0].Source | Should -Be $assignmentLower
            $policyEnforcesEdge[0].Target | Should -Be $definitionLower

            $exemptedFromEdge = @($edgeCollector | Where-Object { $_.Relation -eq 'ExemptedFrom' })
            $exemptedFromEdge.Count | Should -Be 1
            $exemptedFromEdge[0].Source | Should -Be '00000000-0000-0000-0000-000000000001'
            $exemptedFromEdge[0].Target | Should -Be $assignmentLower

            $inheritsFromEdge = @($edgeCollector | Where-Object { $_.Relation -eq 'InheritsFrom' })
            $inheritsFromEdge.Count | Should -BeGreaterOrEqual 1
            $inheritsFromEdge[0].Source | Should -Be '00000000-0000-0000-0000-000000000001'
            $inheritsFromEdge[0].Target | Should -Be $parentScopeLower
        }
    }
}
