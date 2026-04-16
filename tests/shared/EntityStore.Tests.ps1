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
}

Describe 'EntityStore cost metadata merge' {
    It 'updates existing entity monthly cost and currency from later findings without duplicating entity records' {
        $outputPath = Join-Path $PSScriptRoot '..\..\output-test\entitystore-cost'
        if (Test-Path $outputPath) {
            Remove-Item -Path $outputPath -Recurse -Force
        }
        $null = New-Item -Path $outputPath -ItemType Directory -Force

        try {
            $store = [EntityStore]::new(50000, $outputPath)
            $entityId = '/subscriptions/00000000-0000-0000-0000-000000000001/resourcegroups/rg/providers/microsoft.compute/virtualmachines/vm-1'
            $store.AddFinding([pscustomobject]@{
                Source      = 'azqr'
                EntityId    = $entityId
                EntityType  = 'AzureResource'
                Platform    = 'Azure'
                Title       = 'config finding'
                Severity    = 'Medium'
                Compliant   = $false
            })

            $store.AddFinding([pscustomobject]@{
                Source      = 'azure-cost'
                EntityId    = $entityId
                EntityType  = 'AzureResource'
                Platform    = 'Azure'
                Title       = 'Resource spend: vm-1'
                Severity    = 'Info'
                Compliant   = $true
                MonthlyCost = 321.09
                Currency    = 'USD'
            })

            $entities = @($store.GetEntities() | Where-Object { $_.EntityId -eq $entityId })
            $entities.Count | Should -Be 1
            $entities[0].MonthlyCost | Should -Be 321.09
            $entities[0].Currency | Should -Be 'USD'
            @($entities[0].Observations).Count | Should -Be 2
        } finally {
            if ($null -ne $store) {
                $store.CleanupSpillFiles()
            }
            if (Test-Path $outputPath) {
                Remove-Item -Path $outputPath -Recurse -Force
            }
        }
    }
}
