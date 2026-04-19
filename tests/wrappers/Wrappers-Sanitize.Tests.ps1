#Requires -Version 7.4
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

BeforeAll {
    $script:Here = Split-Path $PSCommandPath -Parent
    $script:RepoRoot = Resolve-Path (Join-Path $script:Here '..' '..')
    $script:Token = 'Bearer eyJhbGciOiJIUzI1NiJ9.fake_payload.fake_sig'
}

Describe 'Wrapper raw output disk-write sanitization' {
    It 'sanitizes Invoke-AzureCost raw JSON output' {
        $wrapper = Join-Path $script:RepoRoot 'modules' 'Invoke-AzureCost.ps1'
        $outDir = Join-Path $TestDrive 'cost-sanitize'
        $null = New-Item -ItemType Directory -Path $outDir -Force

        Mock Get-Module { [PSCustomObject]@{ Name = 'Az.Accounts' } }
        Mock Get-AzContext { [PSCustomObject]@{ Account = 'user@test.com' } }
        Mock Invoke-AzRestMethod {
            [PSCustomObject]@{
                StatusCode = 200
                Content    = (@{
                    value    = @(@{
                        properties = @{
                            instanceId            = '/subscriptions/00000000/resourceGroups/rg/providers/Microsoft.Storage/storageAccounts/sa'
                            resourceName          = 'sa'
                            resourceType          = 'Microsoft.Storage/storageAccounts'
                            consumedService       = $null
                            resourceLocation      = 'eastus'
                            cost                  = $null
                            costInBillingCurrency = 42.0
                            billingCurrency       = 'Bearer eyJhbGciOiJIUzI1NiJ9.fake_payload.fake_sig'
                        }
                    })
                    nextLink = $null
                } | ConvertTo-Json -Depth 10)
            }
        }

        $result = & $wrapper -SubscriptionId '00000000-0000-0000-0000-000000000000' -OutputPath $outDir
        if ($result.Status -ne 'Success') { throw "Invoke-AzureCost failed: $($result.Message)" }

        $file = Get-ChildItem -Path $outDir -Filter 'cost-*.json' | Select-Object -First 1
        $file | Should -Not -BeNullOrEmpty
        (Get-Content -Path $file.FullName -Raw) | Should -Not -Match [regex]::Escape($script:Token)
    }

    It 'sanitizes Invoke-DefenderForCloud raw JSON output' {
        $wrapper = Join-Path $script:RepoRoot 'modules' 'Invoke-DefenderForCloud.ps1'
        $outDir = Join-Path $TestDrive 'defender-sanitize'
        $null = New-Item -ItemType Directory -Path $outDir -Force
        $global:WrappersSanitizeCallCount = 0

        Mock Get-Module { [PSCustomObject]@{ Name = 'Az.Accounts' } }
        Mock Get-AzContext { [PSCustomObject]@{ Account = 'user@test.com' } }
        Mock Invoke-AzRestMethod {
            $global:WrappersSanitizeCallCount++
            if ($global:WrappersSanitizeCallCount -eq 1) {
                return [PSCustomObject]@{
                    StatusCode = 200
                    Content    = (@{
                        properties = @{ score = @{ current = 80; max = 100; percentage = 0.80 } }
                    } | ConvertTo-Json -Depth 10)
                }
            }

            return [PSCustomObject]@{
                StatusCode = 200
                Content    = (@{
                    value    = @(@{
                        id         = '/subscriptions/00000000/providers/Microsoft.Security/assessments/a1'
                        name       = 'a1'
                        properties = @{
                            displayName     = 'Synthetic token Bearer eyJhbGciOiJIUzI1NiJ9.fake_payload.fake_sig'
                            status          = @{ code = 'Unhealthy' }
                            resourceDetails = @{ id = '/subscriptions/00000000/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/vm1' }
                            metadata        = @{ severity = 'High' }
                        }
                    })
                    nextLink = $null
                } | ConvertTo-Json -Depth 10)
            }
        }

        $result = & $wrapper -SubscriptionId '00000000-0000-0000-0000-000000000000' -OutputPath $outDir
        if ($result.Status -ne 'Success') { throw "Invoke-DefenderForCloud failed: $($result.Message)" }

        $file = Get-ChildItem -Path $outDir -Filter 'defender-*.json' | Select-Object -First 1
        $file | Should -Not -BeNullOrEmpty
        (Get-Content -Path $file.FullName -Raw) | Should -Not -Match [regex]::Escape($script:Token)
    }

    It 'sanitizes Invoke-SentinelIncidents raw JSON output' {
        $wrapper = Join-Path $script:RepoRoot 'modules' 'Invoke-SentinelIncidents.ps1'
        $outDir = Join-Path $TestDrive 'sentinel-sanitize'
        $null = New-Item -ItemType Directory -Path $outDir -Force

        Mock Get-Module { [PSCustomObject]@{ Name = 'Az.Accounts' } }
        Mock Get-AzContext { [PSCustomObject]@{ Account = 'user@test.com' } }
        Mock Invoke-AzRestMethod {
            $tabular = @{
                tables = @(
                    @{
                        columns = @(
                            @{ name = 'IncidentNumber'; type = 'int' }
                            @{ name = 'Title'; type = 'string' }
                            @{ name = 'Severity'; type = 'string' }
                            @{ name = 'Status'; type = 'string' }
                            @{ name = 'Classification'; type = 'string' }
                            @{ name = 'Owner'; type = 'string' }
                            @{ name = 'IncidentUrl'; type = 'string' }
                            @{ name = 'ProviderName'; type = 'string' }
                            @{ name = 'CreatedTime'; type = 'datetime' }
                            @{ name = 'LastModifiedTime'; type = 'datetime' }
                            @{ name = 'Description'; type = 'string' }
                            @{ name = 'AlertCount'; type = 'int' }
                        )
                        rows = @(
                            @(42, 'Synthetic token Bearer eyJhbGciOiJIUzI1NiJ9.fake_payload.fake_sig', 'High', 'Active', 'TruePositive', 'analyst@test.com', 'https://portal.azure.com', 'Azure Sentinel', '2024-12-01T08:00:00Z', '2024-12-02T10:00:00Z', 'Desc', 5),
                            @(43, 'Another incident', 'Medium', 'New', '', 'analyst@test.com', 'https://portal.azure.com', 'Azure Sentinel', '2024-12-01T08:00:00Z', '2024-12-02T10:00:00Z', 'Desc', 1)
                        )
                    }
                )
            } | ConvertTo-Json -Depth 10
            [PSCustomObject]@{ StatusCode = 200; Content = $tabular }
        }

        $workspaceId = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.OperationalInsights/workspaces/ws'
        $result = & $wrapper -WorkspaceResourceId $workspaceId -OutputPath $outDir
        if ($result.Status -ne 'Success') { throw "Invoke-SentinelIncidents failed: $($result.Message)" }

        $file = Get-ChildItem -Path $outDir -Filter 'sentinel-incidents-*.json' | Select-Object -First 1
        $file | Should -Not -BeNullOrEmpty
        (Get-Content -Path $file.FullName -Raw) | Should -Not -Match [regex]::Escape($script:Token)
    }
}
