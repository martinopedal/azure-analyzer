#Requires -Version 7.4

BeforeAll {
    $script:RepoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
    . (Join-Path $script:RepoRoot 'modules\shared\Schema.ps1')
    . (Join-Path $script:RepoRoot 'modules\shared\WorkerPool.ps1')
    . (Join-Path $script:RepoRoot 'modules\normalizers\Normalize-Azqr.ps1')
}

Describe 'Invoke-AzureAnalyzer management-group path backfill' {
    It 'preserves repeated management-group display names when stamping findings during an MG scan' {
        $scriptPath = Join-Path $script:RepoRoot 'Invoke-AzureAnalyzer.ps1'
        $outputPath = Join-Path $script:RepoRoot 'output-test\mg-path'
        if (Test-Path $outputPath) {
            Remove-Item -Path $outputPath -Recurse -Force
        }

        $subId = '11111111-1111-1111-1111-111111111111'
        $mgChain = @(
            [pscustomobject]@{ displayName = 'Connectivity' },
            [pscustomobject]@{ displayName = 'Platform' },
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
            @($results[0].ManagementGroupPath) | Should -Be @('Tenant Root', 'Platform', 'Platform', 'Connectivity')

            $entitiesFile = Get-Content (Join-Path $outputPath 'entities.json') -Raw | ConvertFrom-Json -ErrorAction Stop
            $entities = if ($entitiesFile.PSObject.Properties['Entities']) { @($entitiesFile.Entities) } else { @($entitiesFile) }
            @($entities[0].ManagementGroupPath) | Should -Be @('Tenant Root', 'Platform', 'Platform', 'Connectivity')
        } finally {
            if (Test-Path $outputPath) {
                Remove-Item -Path $outputPath -Recurse -Force
            }
        }
    }

    It 'does not attribute an out-of-subtree explicit subscription to the requested management-group rollup' {
        $scriptPath = Join-Path $script:RepoRoot 'Invoke-AzureAnalyzer.ps1'
        $outputPath = Join-Path $script:RepoRoot 'output-test\mg-outside-subtree'
        if (Test-Path $outputPath) {
            Remove-Item -Path $outputPath -Recurse -Force
        }

        $insideSub = '11111111-1111-1111-1111-111111111111'
        $outsideSub = '22222222-2222-2222-2222-222222222222'
        $global:normalizeInvocation = 0

        Mock Search-AzGraph {
            param([string] $Query)

            if ($Query -match 'project subscriptionId, subscriptionName = name, mgChain = properties.managementGroupAncestorsChain') {
                return @(
                    [pscustomobject]@{
                        subscriptionId   = $insideSub
                        subscriptionName = 'sub-inside'
                        mgChain          = @(
                            [pscustomobject]@{ displayName = 'Connectivity' },
                            [pscustomobject]@{ displayName = 'Tenant Root' }
                        )
                    }
                )
            }

            return @([pscustomobject]@{ subscriptionId = $insideSub })
        }

        Mock Invoke-ParallelTools {
            @(
                [pscustomobject]@{
                    Tool   = "azqr|$insideSub"
                    Status = 'Success'
                    Result = [pscustomobject]@{
                        Source   = 'azqr'
                        Status   = 'Success'
                        Findings = @()
                    }
                },
                [pscustomobject]@{
                    Tool   = "azqr|$outsideSub"
                    Status = 'Success'
                    Result = [pscustomobject]@{
                        Source   = 'azqr'
                        Status   = 'Success'
                        Findings = @()
                    }
                }
            )
        }

        Mock Normalize-Azqr {
            $global:normalizeInvocation++
            @(
                (New-FindingRow `
                    -Id "mg-path-test-out-$global:normalizeInvocation" `
                    -Source 'azqr' `
                    -EntityId "tenant:00000000-0000-0000-0000-00000000000$global:normalizeInvocation" `
                    -EntityType 'Tenant' `
                    -Title 'tenant finding' `
                    -Compliant $false `
                    -ProvenanceRunId "run-mg-out-$global:normalizeInvocation" `
                    -Platform 'Azure' `
                    -Category 'Security' `
                    -Severity 'High')
            )
        }

        try {
            & $scriptPath -ManagementGroupId 'connectivity' -SubscriptionId $outsideSub -IncludeTools 'azqr' -OutputPath $outputPath -SkipPrereqCheck | Out-Null

            $results = @(Get-Content (Join-Path $outputPath 'results.json') -Raw | ConvertFrom-Json -ErrorAction Stop)
            $results.Count | Should -Be 2

            $outsideResult = @($results | Where-Object { $_.SubscriptionId -eq $outsideSub })[0]
            $insideResult = @($results | Where-Object { $_.SubscriptionId -eq $insideSub })[0]

            $outsideResult | Should -Not -BeNullOrEmpty
            $insideResult | Should -Not -BeNullOrEmpty
            @($outsideResult.ManagementGroupPath) | Should -Be @()
            @($insideResult.ManagementGroupPath) | Should -Be @('Tenant Root', 'Connectivity')

            $portfolio = Get-Content (Join-Path $outputPath 'portfolio.json') -Raw | ConvertFrom-Json -ErrorAction Stop
            @($portfolio.ManagementGroups).Count | Should -Be 1
            $portfolio.ManagementGroups[0].SubscriptionCount | Should -Be 1
            $portfolio.ManagementGroups[0].ManagementGroupPath | Should -Be @('Tenant Root', 'Connectivity')
        } finally {
            if (Test-Path $outputPath) {
                Remove-Item -Path $outputPath -Recurse -Force
            }
        }
    }
}
