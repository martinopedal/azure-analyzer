Set-StrictMode -Version Latest

BeforeAll {
    . "$PSScriptRoot\..\..\modules\shared\EntityStore.ps1"
}

Describe 'EntityStore spill merge' {
    It 'sums aggregate counters when duplicate entities are merged from spill files' {
        $outputPath = Join-Path $PSScriptRoot '..\..\output-test\entitystore-dedup'
        if (Test-Path $outputPath) {
            Remove-Item -Path $outputPath -Recurse -Force
        }
        $null = New-Item -Path $outputPath -ItemType Directory -Force

        try {
            $store = [EntityStore]::new(1, $outputPath)
            $store.MergeEntityMetadata([pscustomobject]@{
                EntityId         = 'vm-1'
                EntityType       = 'microsoft.compute/virtualmachines'
                Platform         = 'azure'
                WorstSeverity    = 'Low'
                CompliantCount   = 1
                NonCompliantCount = 2
                Sources          = @('toolA')
                Observations     = @()
            })
            $store.AddFinding([pscustomobject]@{
                Source      = 'toolA'
                EntityId    = 'vm-1'
                EntityType  = 'microsoft.compute/virtualmachines'
                Platform    = 'azure'
                Title       = 'test finding'
                Severity    = 'Low'
                Compliant   = $false
            })

            $store.MergeEntityMetadata([pscustomobject]@{
                EntityId         = 'vm-1'
                EntityType       = 'microsoft.compute/virtualmachines'
                Platform         = 'azure'
                WorstSeverity    = 'High'
                CompliantCount   = 3
                NonCompliantCount = 4
                Sources          = @('toolB')
                Observations     = @()
            })

            $entities = $store.GetEntities()
            $entity = @($entities | Where-Object { $_.EntityId -eq 'vm-1' })[0]

            $entity.CompliantCount | Should -Be 4
            $entity.NonCompliantCount | Should -Be 7
            $entity.WorstSeverity | Should -Be 'High'
            $entity.Sources | Should -Contain 'toolA'
            $entity.Sources | Should -Contain 'toolB'
        } finally {
            if ($null -ne $store) {
                $store.CleanupSpillFiles()
            }
            if (Test-Path $outputPath) {
                Remove-Item -Path $outputPath -Recurse -Force
            }
        }
    }

    It 'merges correlation metadata for existing entities without duplicates' {
        $outputPath = Join-Path $PSScriptRoot '..\..\output-test\entitystore-correlations'
        if (Test-Path $outputPath) {
            Remove-Item -Path $outputPath -Recurse -Force
        }
        $null = New-Item -Path $outputPath -ItemType Directory -Force

        try {
            $store = [EntityStore]::new(50000, $outputPath)
            $entityId = '/subscriptions/00000000-0000-0000-0000-000000000001/resourcegroups/rg1/providers/microsoft.compute/virtualmachines/vm1'
            $store.MergeEntityMetadata([pscustomobject]@{
                EntityId     = $entityId
                EntityType   = 'AzureResource'
                Platform     = 'Azure'
                DisplayName  = ''
                SubscriptionName = ''
                ManagementGroupPath = @()
                SubscriptionId = ''
                ResourceGroup = ''
                ExternalIds = @()
                Frameworks = @()
                Policies = @()
                MissingDimensions = @()
                Currency = ''
                CostTrend = ''
                MonthlyCost = $null
                Observations = @()
                Correlations = @(
                    [pscustomobject]@{
                        Type             = 'DefenderRecommendation'
                        RecommendationId = 'rec-1'
                    }
                )
            })
            $store.MergeEntityMetadata([pscustomobject]@{
                EntityId     = $entityId
                EntityType   = 'AzureResource'
                Platform     = 'Azure'
                DisplayName  = ''
                SubscriptionName = ''
                ManagementGroupPath = @()
                SubscriptionId = ''
                ResourceGroup = ''
                ExternalIds = @()
                Frameworks = @()
                Policies = @()
                MissingDimensions = @()
                Currency = ''
                CostTrend = ''
                MonthlyCost = $null
                Observations = @()
                Correlations = @(
                    [pscustomobject]@{
                        Type             = 'DefenderRecommendation'
                        RecommendationId = 'rec-1'
                    },
                    [pscustomobject]@{
                        Type             = 'DefenderRecommendation'
                        RecommendationId = 'rec-2'
                    }
                )
            })

            $entities = $store.GetEntities()
            $entity = @($entities | Where-Object { $_.EntityId -eq $entityId })[0]
            @($entity.Correlations).Count | Should -Be 2
            @($entity.Correlations | ForEach-Object { $_.RecommendationId }) | Should -Contain 'rec-1'
            @($entity.Correlations | ForEach-Object { $_.RecommendationId }) | Should -Contain 'rec-2'
        } finally {
            if (Test-Path $outputPath) {
                Remove-Item -Path $outputPath -Recurse -Force
            }
        }
    }
}
