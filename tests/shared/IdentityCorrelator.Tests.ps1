#Requires -Version 7.4

BeforeAll {
    $repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..')
    . (Join-Path $repoRoot 'modules\shared\Canonicalize.ps1')
    . (Join-Path $repoRoot 'modules\shared\Schema.ps1')
    . (Join-Path $repoRoot 'modules\shared\Sanitize.ps1')
    . (Join-Path $repoRoot 'modules\shared\Retry.ps1')
    . (Join-Path $repoRoot 'modules\shared\IdentityCorrelator.ps1')
}

Describe 'Get-IdentityCandidatesFromStore' {
    It 'extracts candidates from entities with ExternalIds' {
        $entities = @(
            [PSCustomObject]@{
                EntityId    = 'spn/11111111-2222-3333-4444-555555555555'
                EntityType  = 'ServicePrincipal'
                Platform    = 'Entra'
                DisplayName = 'deploy-bot'
                ExternalIds = @(
                    [PSCustomObject]@{ Platform = 'EntraApp'; Id = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee' }
                )
                Observations = @()
            },
            [PSCustomObject]@{
                EntityId    = '/subscriptions/abc12345-6789-4abc-8def-1234567890ab/resourcegroups/rg/providers/microsoft.authorization/roleassignments/ra1'
                EntityType  = 'AzureResource'
                Platform    = 'Azure'
                DisplayName = 'Role Assignment'
                ExternalIds = @(
                    [PSCustomObject]@{ Platform = 'EntraApp'; Id = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee' }
                )
                Observations = @()
            }
        )

        $candidates = Get-IdentityCandidatesFromStore -EntityStore $entities
        $candidates.Count | Should -BeGreaterOrEqual 1

        $appKey = 'app:aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'
        $candidates.ContainsKey($appKey) | Should -BeTrue
        $candidate = $candidates[$appKey]
        $candidate.AppId | Should -Be 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'
        $candidate.Dimensions.Count | Should -BeGreaterOrEqual 2
    }

    It 'extracts candidates from observation details containing appId' {
        $entities = @(
            [PSCustomObject]@{
                EntityId    = '/subscriptions/abc12345-6789-4abc-8def-1234567890ab/resourcegroups/rg/providers/microsoft.authorization/roleassignments/ra2'
                EntityType  = 'AzureResource'
                Platform    = 'Azure'
                DisplayName = 'RBAC finding'
                ExternalIds = @()
                Observations = @(
                    [PSCustomObject]@{
                        Title    = 'SPN has Contributor on subscription'
                        Detail   = 'appId: bbbbbbbb-cccc-dddd-eeee-ffffffffffff assigned Contributor'
                        Source   = 'alz-queries'
                        Platform = 'Azure'
                    }
                )
            },
            [PSCustomObject]@{
                EntityId    = 'github.com/contoso/app'
                EntityType  = 'Repository'
                Platform    = 'GitHub'
                DisplayName = 'contoso/app'
                ExternalIds = @(
                    [PSCustomObject]@{ Platform = 'EntraApp'; Id = 'bbbbbbbb-cccc-dddd-eeee-ffffffffffff' }
                )
                Observations = @()
            }
        )

        $candidates = Get-IdentityCandidatesFromStore -EntityStore $entities
        $appKey = 'app:bbbbbbbb-cccc-dddd-eeee-ffffffffffff'
        $candidates.ContainsKey($appKey) | Should -BeTrue
        $candidate = $candidates[$appKey]
        $candidate.Dimensions.Count | Should -BeGreaterOrEqual 2
    }

    It 'returns empty hashtable when no identity entities exist' {
        $entities = @(
            [PSCustomObject]@{
                EntityId     = '/subscriptions/abc12345-6789-4abc-8def-1234567890ab/resourcegroups/rg/providers/microsoft.storage/storageaccounts/foo'
                EntityType   = 'AzureResource'
                Platform     = 'Azure'
                DisplayName  = 'storage account'
                ExternalIds  = @()
                Observations = @()
            }
        )

        $candidates = Get-IdentityCandidatesFromStore -EntityStore $entities
        $candidates.Count | Should -Be 0
    }
}

Describe 'Get-ConfidenceLevel' {
    It 'returns Confirmed for 3+ dimensions with direct evidence' {
        Get-ConfidenceLevel -DimensionCount 3 -IsNameBasedOnly $false | Should -Be 'Confirmed'
        Get-ConfidenceLevel -DimensionCount 4 -IsNameBasedOnly $false | Should -Be 'Confirmed'
    }

    It 'returns Likely for 2 dimensions with direct evidence' {
        Get-ConfidenceLevel -DimensionCount 2 -IsNameBasedOnly $false | Should -Be 'Likely'
    }

    It 'returns Unconfirmed for 1 dimension' {
        Get-ConfidenceLevel -DimensionCount 1 -IsNameBasedOnly $false | Should -Be 'Unconfirmed'
    }

    It 'returns Unconfirmed for name-based correlation regardless of dimension count' {
        Get-ConfidenceLevel -DimensionCount 3 -IsNameBasedOnly $true | Should -Be 'Unconfirmed'
        Get-ConfidenceLevel -DimensionCount 2 -IsNameBasedOnly $true | Should -Be 'Unconfirmed'
    }
}

Describe 'Invoke-IdentityCorrelation' {
    It 'produces FindingRow objects for cross-dimensional SPNs' {
        $entities = @(
            [PSCustomObject]@{
                EntityId    = 'spn/11111111-2222-3333-4444-555555555555'
                EntityType  = 'ServicePrincipal'
                Platform    = 'Entra'
                DisplayName = 'deploy-bot'
                ExternalIds = @(
                    [PSCustomObject]@{ Platform = 'EntraApp'; Id = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee' }
                )
                Observations = @()
            },
            [PSCustomObject]@{
                EntityId    = '/subscriptions/abc12345-6789-4abc-8def-1234567890ab/resourcegroups/rg/providers/microsoft.authorization/roleassignments/ra1'
                EntityType  = 'AzureResource'
                Platform    = 'Azure'
                DisplayName = 'RBAC Assignment'
                ExternalIds = @(
                    [PSCustomObject]@{ Platform = 'EntraApp'; Id = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee' }
                )
                Observations = @()
            },
            [PSCustomObject]@{
                EntityId    = 'github.com/contoso/infra'
                EntityType  = 'Repository'
                Platform    = 'GitHub'
                DisplayName = 'contoso/infra'
                ExternalIds = @(
                    [PSCustomObject]@{ Platform = 'EntraApp'; Id = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee' }
                )
                Observations = @()
            }
        )

        $results = Invoke-IdentityCorrelation -EntityStore $entities -TenantId 'test-tenant-id'
        $results.Count | Should -BeGreaterOrEqual 1

        $row = $results[0]
        $row.Source | Should -Be 'identity-correlator'
        $row.EntityType | Should -Be 'ServicePrincipal'
        $row.Platform | Should -Be 'Entra'
        $row.Category | Should -Be 'Identity Correlation'
        $row.Severity | Should -Be 'Info'
        $row.Compliant | Should -BeTrue
        $row.SchemaVersion | Should -Be '2.2'
        $row.Title | Should -Match 'deploy-bot'
        $row.Title | Should -Match 'spans'
        $row.Confidence | Should -BeIn @('Confirmed', 'Likely')
        $row.EvidenceCount | Should -BeGreaterOrEqual 3
        $row.MissingDimensions | Should -Not -Contain 'Azure'
    }

    It 'emits Schema 2.2 identity attack-path metadata on correlated findings' {
        $entities = @(
            [PSCustomObject]@{
                EntityId    = 'spn/11111111-2222-3333-4444-555555555555'
                EntityType  = 'ServicePrincipal'
                Platform    = 'Entra'
                DisplayName = 'deploy-bot'
                ExternalIds = @(
                    [PSCustomObject]@{ Platform = 'EntraApp'; Id = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee' },
                    [PSCustomObject]@{ Platform = 'Entra'; Id = '11111111-2222-3333-4444-555555555555' }
                )
                Observations = @()
            },
            [PSCustomObject]@{
                EntityId    = '/subscriptions/abc12345-6789-4abc-8def-1234567890ab/resourcegroups/rg/providers/microsoft.authorization/roleassignments/ra1'
                EntityType  = 'AzureResource'
                Platform    = 'Azure'
                DisplayName = 'RBAC Assignment'
                ExternalIds = @(
                    [PSCustomObject]@{ Platform = 'EntraApp'; Id = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee' }
                )
                Observations = @(
                    [PSCustomObject]@{
                        Title    = 'SPN has Contributor on subscription'
                        Detail   = 'appId: aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee assigned Contributor role'
                        Source   = 'alz-queries'
                        Platform = 'Azure'
                    }
                )
            },
            [PSCustomObject]@{
                EntityId    = 'ado://contoso/proj/serviceconnection/sc1'
                EntityType  = 'ServiceConnection'
                Platform    = 'ADO'
                DisplayName = 'sc1'
                ExternalIds = @(
                    [PSCustomObject]@{ Platform = 'EntraApp'; Id = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee' }
                )
                Observations = @()
            }
        )

        $rows = @(Invoke-IdentityCorrelation -EntityStore $entities -TenantId 'test-tenant-id')
        $row = $rows | Where-Object { $_.Category -eq 'Identity Correlation' } | Select-Object -First 1
        $row | Should -Not -BeNullOrEmpty
        $row.Pillar | Should -Be 'Security'
        $row.Frameworks[0].Name | Should -Be 'NIST 800-53'
        $row.Frameworks[1].Name | Should -Be 'CIS Controls v8'
        $row.MitreTactics | Should -Contain 'TA0001'
        $row.MitreTactics | Should -Contain 'TA0006'
        $row.MitreTactics | Should -Contain 'TA0008'
        $row.MitreTechniques | Should -Contain 'T1078'
        $row.MitreTechniques | Should -Contain 'T1550'
        $row.MitreTechniques | Should -Contain 'T1021'
        $row.DeepLinkUrl | Should -Match 'entra\.microsoft\.com'
        $row.ToolVersion | Should -Be 'identity-correlator'
        $row.EntityRefs | Should -Contain $row.EntityId
        $row.EntityRefs | Should -Contain 'objectid:11111111-2222-3333-4444-555555555555'
    }

    It 'returns empty array when no cross-dimensional candidates exist' {
        $entities = @(
            [PSCustomObject]@{
                EntityId     = '/subscriptions/abc12345-6789-4abc-8def-1234567890ab/resourcegroups/rg/providers/microsoft.storage/storageaccounts/foo'
                EntityType   = 'AzureResource'
                Platform     = 'Azure'
                DisplayName  = 'plain resource'
                ExternalIds  = @()
                Observations = @()
            }
        )

        $results = @(Invoke-IdentityCorrelation -EntityStore $entities -TenantId 'test-tenant-id')
        $results.Count | Should -Be 0
    }

    It 'works without Graph connection (no -IncludeGraphLookup)' {
        $entities = @(
            [PSCustomObject]@{
                EntityId    = 'spn/22222222-3333-4444-5555-666666666666'
                EntityType  = 'ServicePrincipal'
                Platform    = 'Entra'
                DisplayName = 'ci-bot'
                ExternalIds = @(
                    [PSCustomObject]@{ Platform = 'EntraApp'; Id = 'cccccccc-dddd-eeee-ffff-111111111111' }
                )
                Observations = @()
            },
            [PSCustomObject]@{
                EntityId    = 'ado/contoso/project/sc-1'
                EntityType  = 'ServiceConnection'
                Platform    = 'ADO'
                DisplayName = 'ci-bot'
                ExternalIds = @(
                    [PSCustomObject]@{ Platform = 'EntraApp'; Id = 'cccccccc-dddd-eeee-ffff-111111111111' }
                )
                Observations = @()
            }
        )

        # Should work fine without -IncludeGraphLookup
        $results = Invoke-IdentityCorrelation -EntityStore $entities -TenantId 'test-tenant-id'
        $results.Count | Should -BeGreaterOrEqual 1
        $results[0].Confidence | Should -Be 'Likely'
    }

    It 'validates findings pass Test-FindingRow' {
        $entities = @(
            [PSCustomObject]@{
                EntityId    = 'spn/33333333-4444-5555-6666-777777777777'
                EntityType  = 'ServicePrincipal'
                Platform    = 'Entra'
                DisplayName = 'test-app'
                ExternalIds = @(
                    [PSCustomObject]@{ Platform = 'EntraApp'; Id = 'dddddddd-eeee-ffff-0000-111111111111' }
                )
                Observations = @()
            },
            [PSCustomObject]@{
                EntityId    = 'github.com/contoso/test'
                EntityType  = 'Repository'
                Platform    = 'GitHub'
                DisplayName = 'contoso/test'
                ExternalIds = @(
                    [PSCustomObject]@{ Platform = 'EntraApp'; Id = 'dddddddd-eeee-ffff-0000-111111111111' }
                )
                Observations = @()
            }
        )

        $results = Invoke-IdentityCorrelation -EntityStore $entities -TenantId 'test-tenant-id'
        $results.Count | Should -BeGreaterOrEqual 1

        foreach ($row in $results) {
            $errors = @()
            $valid = Test-FindingRow -Finding $row -ErrorDetails ([ref]$errors)
            $valid | Should -BeTrue -Because "Finding should pass validation: $($errors -join '; ')"
        }
    }

    It 'sets MissingDimensions correctly' {
        $entities = @(
            [PSCustomObject]@{
                EntityId    = 'spn/44444444-5555-6666-7777-888888888888'
                EntityType  = 'ServicePrincipal'
                Platform    = 'Entra'
                DisplayName = 'limited-spn'
                ExternalIds = @(
                    [PSCustomObject]@{ Platform = 'EntraApp'; Id = 'eeeeeeee-ffff-0000-1111-222222222222' }
                )
                Observations = @()
            },
            [PSCustomObject]@{
                EntityId    = '/subscriptions/abc12345-6789-4abc-8def-1234567890ab/resourcegroups/rg/providers/microsoft.authorization/roleassignments/ra3'
                EntityType  = 'AzureResource'
                Platform    = 'Azure'
                DisplayName = 'role-assignment'
                ExternalIds = @(
                    [PSCustomObject]@{ Platform = 'EntraApp'; Id = 'eeeeeeee-ffff-0000-1111-222222222222' }
                )
                Observations = @()
            }
        )

        $results = Invoke-IdentityCorrelation -EntityStore $entities -TenantId 'test-tenant-id'
        $results.Count | Should -Be 1
        $results[0].MissingDimensions | Should -Contain 'GitHub'
        $results[0].MissingDimensions | Should -Contain 'ADO'
    }

    It 'flags high risk when privileged Azure role is linked to CI/CD identity usage' {
        $entities = @(
            [PSCustomObject]@{
                EntityId    = 'spn/55555555-6666-7777-8888-999999999999'
                EntityType  = 'ServicePrincipal'
                Platform    = 'Entra'
                DisplayName = 'priv-spn'
                ExternalIds = @(
                    [PSCustomObject]@{ Platform = 'EntraApp'; Id = 'ffffffff-0000-1111-2222-333333333333' }
                )
                Observations = @()
            },
            [PSCustomObject]@{
                EntityId    = '/subscriptions/sub-1/providers/microsoft.authorization/roleassignments/ra1'
                EntityType  = 'AzureResource'
                Platform    = 'Azure'
                DisplayName = 'rbac-assignment'
                ExternalIds = @(
                    [PSCustomObject]@{ Platform = 'EntraApp'; Id = 'ffffffff-0000-1111-2222-333333333333' }
                )
                Observations = @(
                    [PSCustomObject]@{
                        Title    = 'SPN has Contributor on subscription'
                        Detail   = 'appId: ffffffff-0000-1111-2222-333333333333 assigned Contributor role'
                        Source   = 'alz-queries'
                        Platform = 'Azure'
                    }
                )
            },
            [PSCustomObject]@{
                EntityId    = 'ado://contoso/proj/serviceconnection/sc1'
                EntityType  = 'ServiceConnection'
                Platform    = 'ADO'
                DisplayName = 'sc1'
                ExternalIds = @(
                    [PSCustomObject]@{ Platform = 'EntraApp'; Id = 'ffffffff-0000-1111-2222-333333333333' }
                )
                Observations = @()
            }
        )

        $results = Invoke-IdentityCorrelation -EntityStore $entities -TenantId 'test-tenant-id'
        $highRisk = @($results | Where-Object { $_.Category -eq 'Identity Correlation Risk' -and $_.Severity -eq 'High' })
        $highRisk.Count | Should -Be 1
        $highRisk[0].Compliant | Should -BeFalse
    }

    It 'flags medium risk when PAT-based ADO authentication is detected' {
        $entities = @(
            [PSCustomObject]@{
                EntityId    = 'spn/66666666-7777-8888-9999-aaaaaaaaaaaa'
                EntityType  = 'ServicePrincipal'
                Platform    = 'Entra'
                DisplayName = 'pat-spn'
                ExternalIds = @(
                    [PSCustomObject]@{ Platform = 'EntraApp'; Id = '11111111-aaaa-bbbb-cccc-222222222222' }
                )
                Observations = @()
            },
            [PSCustomObject]@{
                EntityId    = 'ado://contoso/proj/serviceconnection/sc-pat'
                EntityType  = 'ServiceConnection'
                Platform    = 'ADO'
                DisplayName = 'sc-pat'
                ExternalIds = @(
                    [PSCustomObject]@{ Platform = 'EntraApp'; Id = '11111111-aaaa-bbbb-cccc-222222222222' }
                )
                Observations = @(
                    [PSCustomObject]@{
                        Title    = 'GitHub connection: sc-pat'
                        Detail   = 'Type=GitHub; AuthScheme=Token; AuthMechanism=Token; IsShared=False'
                        Source   = 'ado-connections'
                        Platform = 'ADO'
                    }
                )
            },
            [PSCustomObject]@{
                EntityId    = 'github.com/contoso/repo1'
                EntityType  = 'Repository'
                Platform    = 'GitHub'
                DisplayName = 'contoso/repo1'
                ExternalIds = @(
                    [PSCustomObject]@{ Platform = 'EntraApp'; Id = '11111111-aaaa-bbbb-cccc-222222222222' }
                )
                Observations = @()
            }
        )

        $results = Invoke-IdentityCorrelation -EntityStore $entities -TenantId 'test-tenant-id'
        $patRisk = @($results | Where-Object { $_.Category -eq 'Identity Correlation Risk' -and $_.Title -match 'PAT-based ADO service connection' })
        $patRisk.Count | Should -Be 1
        $patRisk[0].Severity | Should -Be 'Medium'
    }
}

Describe 'Normalize-IdentityCorrelation' {
    BeforeAll {
        . (Join-Path (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path 'modules\normalizers\Normalize-IdentityCorrelation.ps1')
    }

    It 'passes through valid findings' {
        $finding = New-FindingRow `
            -Id 'ic-001' `
            -Source 'identity-correlator' `
            -EntityId 'appId:11111111-aaaa-bbbb-cccc-222222222222' `
            -EntityType 'ServicePrincipal' `
            -Title 'SPN test spans Azure, Entra' `
            -Compliant $true `
            -ProvenanceRunId 'run-1' `
            -Platform 'Entra' `
            -Category 'Identity Correlation' `
            -Severity 'Info'

        $result = @(Normalize-IdentityCorrelation -ToolResult ([PSCustomObject]@{
            Status   = 'Success'
            Findings = @($finding)
        }))

        $result.Count | Should -Be 1
        $result[0].Source | Should -Be 'identity-correlator'
    }

    It 'returns empty for failed tool result' {
        $result = @(Normalize-IdentityCorrelation -ToolResult ([PSCustomObject]@{
            Status   = 'Failed'
            Findings = @()
        }))
        $result.Count | Should -Be 0
    }
}
