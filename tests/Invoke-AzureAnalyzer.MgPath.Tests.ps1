#Requires -Version 7.4

BeforeAll {
    $script:RepoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
    . (Join-Path $script:RepoRoot 'modules\shared\Schema.ps1')
    . (Join-Path $script:RepoRoot 'modules\shared\WorkerPool.ps1')
    . (Join-Path $script:RepoRoot 'modules\normalizers\Normalize-Azqr.ps1')
}

Describe 'Invoke-AzureAnalyzer management-group path backfill' {
    It 'stamps ManagementGroupPath on emitted findings during an MG scan' {
        $scriptPath = Join-Path $script:RepoRoot 'Invoke-AzureAnalyzer.ps1'
        $outputPath = Join-Path $script:RepoRoot 'output-test\mg-path'
        if (Test-Path $outputPath) {
            Remove-Item -Path $outputPath -Recurse -Force
        }

        $subId = '11111111-1111-1111-1111-111111111111'
        $mgChain = @(
            [pscustomobject]@{ displayName = 'Connectivity' },
            [pscustomobject]@{ displayName = 'Platform' },
            [pscustomobject]@{ displayName = 'Tenant Root' }
        )

        Mock Search-AzGraph {
            @([pscustomobject]@{
                    subscriptionId   = $subId
                    subscriptionName = 'sub-one'
                    mgChain          = $mgChain
                })
        }

        Mock Invoke-ParallelTools {
            @([pscustomobject]@{
                    Tool   = "azqr|$subId"
                    Status = 'Success'
                    Result = [pscustomobject]@{
                        Source   = 'azqr'
                        Status   = 'Success'
                        Findings = @()
                    }
                })
        }

        Mock Normalize-Azqr {
            @(
                (New-FindingRow `
                    -Id 'mg-path-test-1' `
                    -Source 'azqr' `
                    -EntityId "/subscriptions/$subId/resourcegroups/rg/providers/microsoft.storage/storageaccounts/sa1" `
                    -EntityType 'AzureResource' `
                    -Title 'storage account finding' `
                    -Compliant $false `
                    -ProvenanceRunId 'run-mg-1' `
                    -Platform 'Azure' `
                    -Category 'Security' `
                    -Severity 'High' `
                    -ResourceId "/subscriptions/$subId/resourcegroups/rg/providers/microsoft.storage/storageaccounts/sa1")
            )
        }

        try {
            & $scriptPath -ManagementGroupId 'connectivity' -IncludeTools 'azqr' -OutputPath $outputPath -SkipPrereqCheck | Out-Null

            $results = @(Get-Content (Join-Path $outputPath 'results.json') -Raw | ConvertFrom-Json -ErrorAction Stop)
            $results.Count | Should -BeGreaterThan 0
            $results[0].SubscriptionId | Should -Be $subId
            @($results[0].ManagementGroupPath) | Should -Be @('Tenant Root', 'Platform', 'Connectivity')

            $entities = @(Get-Content (Join-Path $outputPath 'entities.json') -Raw | ConvertFrom-Json -ErrorAction Stop)
            @($entities[0].ManagementGroupPath) | Should -Be @('Tenant Root', 'Platform', 'Connectivity')
        } finally {
            if (Test-Path $outputPath) {
                Remove-Item -Path $outputPath -Recurse -Force
            }
        }
    }
}
