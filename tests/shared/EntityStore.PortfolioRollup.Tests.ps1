#Requires -Version 7.4

BeforeAll {
    $repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..')
    . (Join-Path $repoRoot 'modules\shared\EntityStore.ps1')
    . (Join-Path $repoRoot 'modules\shared\Schema.ps1')
}

Describe 'Get-PortfolioRollup' {
    It 'returns subscription and management-group rollups with severity and cost totals' {
        $outputPath = Join-Path $PSScriptRoot '..\..\output-test\portfolio-rollup'
        if (Test-Path $outputPath) {
            Remove-Item -Path $outputPath -Recurse -Force
        }
        $null = New-Item -ItemType Directory -Path $outputPath -Force

        try {
            $store = [EntityStore]::new(50000, $outputPath)
            $mgPath = @('Tenant Root', 'Platform', 'Connectivity')

            $subscriptions = @(
                @{ Id = '11111111-1111-1111-1111-111111111111'; Name = 'sub-one'; Cost = 10.25; Severities = @('Critical', 'High', 'Low', 'Info') },
                @{ Id = '22222222-2222-2222-2222-222222222222'; Name = 'sub-two'; Cost = 20.50; Severities = @('High', 'Medium', 'Low', 'Info') },
                @{ Id = '33333333-3333-3333-3333-333333333333'; Name = 'sub-three'; Cost = 30.75; Severities = @('High', 'Medium', 'Medium', 'Info') }
            )

            foreach ($sub in $subscriptions) {
                $entityId = "/subscriptions/$($sub.Id)/resourceGroups/rg-$($sub.Name)/providers/Microsoft.Storage/storageAccounts/$($sub.Name)-sa"
                $store.MergeEntityMetadata([pscustomobject]@{
                        EntityId            = $entityId
                        EntityType          = 'AzureResource'
                        Platform            = 'Azure'
                        DisplayName         = "$($sub.Name)-sa"
                        SubscriptionId      = $sub.Id
                        SubscriptionName    = $sub.Name
                        ManagementGroupPath = $mgPath
                        MonthlyCost         = [double]$sub.Cost
                        Currency            = 'USD'
                        Observations        = @()
                    })

                for ($i = 0; $i -lt $sub.Severities.Count; $i++) {
                    $store.AddFinding((New-FindingRow `
                            -Id "$($sub.Name)-$i" `
                            -Source 'azqr' `
                            -EntityId $entityId `
                            -EntityType 'AzureResource' `
                            -Title "finding-$($sub.Name)-$i" `
                            -Compliant $false `
                            -ProvenanceRunId 'run-portfolio-1' `
                            -Platform 'Azure' `
                            -Category 'Security' `
                            -Severity $sub.Severities[$i] `
                            -SubscriptionId $sub.Id `
                            -SubscriptionName $sub.Name `
                            -ManagementGroupPath $mgPath))
                }
            }

            $portfolio = Get-PortfolioRollup -Store $store -ManagementGroupId 'connectivity'

            $portfolio.SchemaVersion | Should -Be '1.0'
            @($portfolio.Subscriptions).Count | Should -Be 3
            @($portfolio.ManagementGroups).Count | Should -Be 1
            @($portfolio.Correlations).Count | Should -Be 0

            $subOne = @($portfolio.Subscriptions | Where-Object { $_.SubscriptionId -eq '11111111-1111-1111-1111-111111111111' })[0]
            $subOne.SeverityCounts.Critical | Should -Be 1
            $subOne.SeverityCounts.High | Should -Be 1
            $subOne.SeverityCounts.Low | Should -Be 1
            $subOne.SeverityCounts.Info | Should -Be 1
            $subOne.MonthlyCost | Should -Be 10.25

            $mgRow = $portfolio.ManagementGroups[0]
            $mgRow.ManagementGroupName | Should -Be 'Connectivity'
            $mgRow.SubscriptionCount | Should -Be 3
            $mgRow.SeverityCounts.Critical | Should -Be 1
            $mgRow.SeverityCounts.High | Should -Be 3
            $mgRow.SeverityCounts.Medium | Should -Be 3
            $mgRow.MonthlyCost | Should -Be 61.5
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
