#Requires -Version 7.4

BeforeAll {
    $repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..')
    . (Join-Path $repoRoot 'modules\shared\Canonicalize.ps1')
    . (Join-Path $repoRoot 'modules\shared\Schema.ps1')
    . (Join-Path $repoRoot 'modules\shared\Sanitize.ps1')
    . (Join-Path $repoRoot 'modules\shared\Retry.ps1')
    . (Join-Path $repoRoot 'modules\shared\IdentityCorrelator.ps1')
}

Describe 'Invoke-IdentityCorrelation -PortfolioMode' {
    It 'emits one Medium-severity finding when an app is reused across four subscriptions' {
        $appId = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'
        $subscriptionIds = @(
            '11111111-1111-1111-1111-111111111111',
            '22222222-2222-2222-2222-222222222222',
            '33333333-3333-3333-3333-333333333333',
            '44444444-4444-4444-4444-444444444444'
        )
        $entities = for ($i = 0; $i -lt $subscriptionIds.Count; $i++) {
            [pscustomobject]@{
                EntityId            = "spn/$appId/$i"
                EntityType          = 'ServicePrincipal'
                Platform            = 'Entra'
                DisplayName         = 'shared-deploy-bot'
                SubscriptionId      = $subscriptionIds[$i]
                SubscriptionName    = "sub-$($i + 1)"
                TenantId            = 'tenant-a'
                ManagementGroupPath = @('Tenant Root', 'Platform', 'Connectivity')
                ExternalIds         = @([pscustomobject]@{ Platform = 'EntraApp'; Id = $appId })
                Observations        = @()
            }
        }

        $results = @(Invoke-IdentityCorrelation -EntityStore $entities -TenantId 'tenant-a' -PortfolioMode)
        $portfolioFindings = @($results | Where-Object { $_.Category -eq 'CrossSubscriptionCorrelation' })

        $portfolioFindings.Count | Should -Be 1
        $portfolioFindings[0].Severity | Should -Be 'Medium'
        $portfolioFindings[0].Compliant | Should -BeFalse
        $portfolioFindings[0].EvidenceCount | Should -Be 4
        $portfolioFindings[0].Title | Should -Match 'reused across 4 subscriptions'
    }

    It 'escalates to High severity when the same app appears across tenants' {
        $appId = 'ffffffff-eeee-dddd-cccc-bbbbbbbbbbbb'
        $entities = @(
            [pscustomobject]@{
                EntityId            = "spn/$appId/a"
                EntityType          = 'ServicePrincipal'
                Platform            = 'Entra'
                DisplayName         = 'cross-tenant-app'
                SubscriptionId      = '44444444-4444-4444-4444-444444444444'
                SubscriptionName    = 'sub-a'
                TenantId            = 'tenant-a'
                ManagementGroupPath = @('Tenant Root', 'Platform', 'Identity')
                ExternalIds         = @([pscustomobject]@{ Platform = 'EntraApp'; Id = $appId })
                Observations        = @()
            },
            [pscustomobject]@{
                EntityId            = "spn/$appId/b"
                EntityType          = 'ServicePrincipal'
                Platform            = 'Entra'
                DisplayName         = 'cross-tenant-app'
                SubscriptionId      = '55555555-5555-5555-5555-555555555555'
                SubscriptionName    = 'sub-b'
                TenantId            = 'tenant-b'
                ManagementGroupPath = @('Tenant Root', 'Platform', 'Identity')
                ExternalIds         = @([pscustomobject]@{ Platform = 'EntraApp'; Id = $appId })
                Observations        = @()
            }
        )

        $results = @(Invoke-IdentityCorrelation -EntityStore $entities -TenantId 'tenant-a' -PortfolioMode)
        $portfolioFinding = @($results | Where-Object { $_.Category -eq 'CrossSubscriptionCorrelation' })[0]

        $portfolioFinding.Severity | Should -Be 'High'
        $portfolioFinding.Confidence | Should -BeIn @('Likely', 'Unconfirmed')
        $portfolioFinding.Detail | Should -Match 'Tenants: tenant-a, tenant-b'
    }
}
