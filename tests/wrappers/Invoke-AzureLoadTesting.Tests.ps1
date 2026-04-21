#Requires -Version 7.4
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

BeforeAll {
    $script:Here = Split-Path $PSCommandPath -Parent
    $script:RepoRoot = Resolve-Path (Join-Path $script:Here '..' '..')
    $script:Wrapper = Join-Path $script:RepoRoot 'modules' 'Invoke-AzureLoadTesting.ps1'
    $script:SubId = '00000000-0000-0000-0000-000000000000'
    $script:ResourceId = "/subscriptions/$($script:SubId)/resourceGroups/perf-rg/providers/Microsoft.LoadTestService/loadTests/lt-prod"
}

Describe 'Invoke-AzureLoadTesting' {
    AfterAll {
        foreach ($fn in @('Get-Module', 'Get-AzContext', 'Import-Module', 'Invoke-AzRestMethod', 'Start-Sleep')) {
            if (Test-Path "Function:global:$fn") {
                Remove-Item "Function:global:$fn" -ErrorAction SilentlyContinue
            }
            if (Test-Path "Function:$fn") {
                Remove-Item "Function:$fn" -ErrorAction SilentlyContinue
            }
        }
        Remove-Variable -Name TestResourceId -Scope Global -ErrorAction SilentlyContinue
        Remove-Variable -Name TestCalls -Scope Global -ErrorAction SilentlyContinue
    }

    BeforeEach {
        $global:TestResourceId = $script:ResourceId
        $global:TestCalls = 0
        function global:Get-Module {
            [CmdletBinding()]
            param([string] $Name, [switch] $ListAvailable)
            if ($Name -eq 'Az.LoadTesting') {
                return [PSCustomObject]@{ Name = 'Az.LoadTesting'; Version = [version]'2.2.0' }
            }
            [PSCustomObject]@{ Name = 'Az.Accounts'; Version = [version]'3.0.0' }
        }
        function global:Get-AzContext {
            [CmdletBinding()]
            param()
            [PSCustomObject]@{ Account = 'user@test.com' }
        }
        function global:Import-Module {
            [CmdletBinding()]
            param([string] $Name)
        }
    }

    AfterEach {
        foreach ($fn in @('Get-Module', 'Get-AzContext', 'Import-Module', 'Invoke-AzRestMethod', 'Start-Sleep')) {
            if (Test-Path "Function:\global:$fn") {
                Remove-Item "Function:\global:$fn" -ErrorAction SilentlyContinue
            }
        }
        Remove-Variable -Name TestResourceId -Scope Global -ErrorAction SilentlyContinue
        Remove-Variable -Name TestCalls -Scope Global -ErrorAction SilentlyContinue
    }

    It 'returns Skipped when Az.Accounts module is missing' {
        function global:Get-Module {
            [CmdletBinding()]
            param([string]$Name, [switch]$ListAvailable)
            $null
        }
        $result = & $script:Wrapper -SubscriptionId $script:SubId
        $result.Status | Should -Be 'Skipped'
        $result.Message | Should -Match 'Az.Accounts'
    }

    It 'returns Skipped when not signed in' {
        function global:Get-AzContext {
            [CmdletBinding()]
            param()
            $null
        }
        $result = & $script:Wrapper -SubscriptionId $script:SubId
        $result.Status | Should -Be 'Skipped'
        $result.Message | Should -Match 'Not signed in'
    }

    It 'emits failed, regressed, and no-runs findings' {
        function global:Invoke-AzRestMethod {
            [CmdletBinding()]
            param($Method, $Uri)
            $u = [string]$Uri

            if ($u -match '/providers/Microsoft\.LoadTestService/loadTests\?') {
                return [PSCustomObject]@{
                    StatusCode = 200
                    Content    = (@{ value = @(@{ id = $global:TestResourceId; name = 'lt-prod' }) } | ConvertTo-Json -Depth 10)
                }
            }
            if ($u -match '/loadTests/lt-prod/tests\?') {
                return [PSCustomObject]@{
                    StatusCode = 200
                    Content    = (@{ value = @(
                                @{ name = 'checkout' },
                                @{ name = 'search' },
                                @{ name = 'inventory' }
                            ) } | ConvertTo-Json -Depth 10)
                }
            }
            if ($u -match '/tests/checkout/test-runs\?') {
                $runs = @{
                    value = @(
                        @{
                            name       = 'run-failed-001'
                            properties = @{
                                status            = 'FAILED'
                                endDateTime       = (Get-Date).ToUniversalTime().AddDays(-1).ToString('o')
                                message           = 'Dependency timeout'
                                testRunStatistics = @{ responseTimeP95 = 180; errorRate = 0.12; requestsPerSecond = 240 }
                                passFailCriteria  = @{ passFailMetrics = @(@{ status = 'FAILED' }) }
                            }
                        }
                    )
                }
                return [PSCustomObject]@{ StatusCode = 200; Content = ($runs | ConvertTo-Json -Depth 20) }
            }
            if ($u -match '/tests/search/test-runs\?') {
                $runs = @{
                    value = @(
                        @{
                            name       = 'run-search-new'
                            properties = @{
                                status            = 'DONE'
                                endDateTime       = (Get-Date).ToUniversalTime().AddHours(-1).ToString('o')
                                testRunStatistics = @{ responseTimeP95 = 130; errorRate = 0.01; requestsPerSecond = 300 }
                            }
                        },
                        @{
                            name       = 'run-search-old'
                            properties = @{
                                status            = 'DONE'
                                endDateTime       = (Get-Date).ToUniversalTime().AddDays(-3).ToString('o')
                                testRunStatistics = @{ responseTimeP95 = 100; errorRate = 0.01; requestsPerSecond = 310 }
                            }
                        }
                    )
                }
                return [PSCustomObject]@{ StatusCode = 200; Content = ($runs | ConvertTo-Json -Depth 20) }
            }
            if ($u -match '/tests/inventory/test-runs\?') {
                return [PSCustomObject]@{ StatusCode = 200; Content = '{"value":[]}' }
            }
            return [PSCustomObject]@{ StatusCode = 200; Content = '{"value":[]}' }
        }

        $result = & $script:Wrapper -SubscriptionId $script:SubId -DaysBack 30 -RegressionThresholdPercent 10
        if ($result.Status -eq 'Failed') { throw $result.Message }

        $result.Status | Should -Be 'Success'
        $result.ToolVersion | Should -Be 'Az.LoadTesting/2.2.0'
        @($result.Findings | Where-Object { $_.Id -like '*/failed' }).Count | Should -Be 1
        @($result.Findings | Where-Object { $_.Id -like '*/regression/*' }).Count | Should -Be 1
        @($result.Findings | Where-Object { $_.Id -like '*/no-runs' }).Count | Should -Be 1
        @($result.Findings | Where-Object { $_.Id -like '*/healthy' }).Count | Should -Be 0

        $failed = @($result.Findings | Where-Object { $_.Id -like '*/failed' })[0]
        $failed.Pillar | Should -Be 'Performance Efficiency'
        $failed.DeepLinkUrl | Should -Match 'Microsoft_Azure_LoadTesting'
        @($failed.EvidenceUris).Count | Should -BeGreaterThan 0
        @($failed.BaselineTags) | Should -Contain 'LoadTesting-PassFailCriteriaFailed'
        @($failed.EntityRefs) | Should -Contain $script:ResourceId
        @($failed.EntityRefs) | Should -Contain 'run-failed-001'
        $failed.ToolVersion | Should -Be 'Az.LoadTesting/2.2.0'

        $regressed = @($result.Findings | Where-Object { $_.Id -like '*/regression/*' })[0]
        $regressed.ScoreDelta | Should -Be 30
        $regressed.Impact | Should -Be 'High'
        $regressed.Effort | Should -Be 'Medium'
        @($regressed.BaselineTags) | Should -Contain 'LoadTesting-ResponseTimeP95'
        @($regressed.EvidenceUris).Count | Should -BeGreaterThan 1

        $stale = @($result.Findings | Where-Object { $_.Id -like '*/no-runs' })[0]
        $stale.Effort | Should -Be 'Low'
        $stale.Impact | Should -Be 'Low'
        @($stale.BaselineTags) | Should -Contain 'LoadTesting-StaleCadence'
    }

    It 'emits healthy finding only when IncludeHealthyRuns is set' {
        function global:Invoke-AzRestMethod {
            [CmdletBinding()]
            param($Method, $Uri)
            $u = [string]$Uri
            if ($u -match '/providers/Microsoft\.LoadTestService/loadTests\?') {
                return [PSCustomObject]@{
                    StatusCode = 200
                    Content    = (@{ value = @(@{ id = $global:TestResourceId; name = 'lt-prod' }) } | ConvertTo-Json -Depth 10)
                }
            }
            if ($u -match '/loadTests/lt-prod/tests\?') {
                return [PSCustomObject]@{
                    StatusCode = 200
                    Content    = (@{ value = @(@{ name = 'healthy-test' }) } | ConvertTo-Json -Depth 10)
                }
            }
            if ($u -match '/tests/healthy-test/test-runs\?') {
                $runs = @{
                    value = @(
                        @{
                            name       = 'run-new'
                            properties = @{
                                status            = 'DONE'
                                endDateTime       = (Get-Date).ToUniversalTime().AddHours(-1).ToString('o')
                                testRunStatistics = @{ responseTimeP95 = 102; requestsPerSecond = 300 }
                            }
                        },
                        @{
                            name       = 'run-old'
                            properties = @{
                                status            = 'DONE'
                                endDateTime       = (Get-Date).ToUniversalTime().AddDays(-1).ToString('o')
                                testRunStatistics = @{ responseTimeP95 = 100; requestsPerSecond = 300 }
                            }
                        }
                    )
                }
                return [PSCustomObject]@{ StatusCode = 200; Content = ($runs | ConvertTo-Json -Depth 20) }
            }
            return [PSCustomObject]@{ StatusCode = 200; Content = '{"value":[]}' }
        }

        $result = & $script:Wrapper -SubscriptionId $script:SubId -RegressionThresholdPercent 10 -IncludeHealthyRuns
        if ($result.Status -eq 'Failed') { throw $result.Message }
        $result.Status | Should -Be 'Success'
        $healthy = @($result.Findings | Where-Object { $_.Id -like '*/healthy' })
        $healthy.Count | Should -Be 1
        $healthy[0].Compliant | Should -BeTrue
    }

    It 'retries transient throttling and returns Skipped when no resources are found' {
        function global:Start-Sleep { param([int]$Seconds) }
        function global:Invoke-AzRestMethod {
            [CmdletBinding()]
            param($Method, $Uri)
            $global:TestCalls++
            if ($global:TestCalls -eq 1) {
                throw '429 Too Many Requests'
            }
            [PSCustomObject]@{ StatusCode = 200; Content = '{"value":[]}' }
        }

        $result = & $script:Wrapper -SubscriptionId $script:SubId
        if ($result.Status -eq 'Failed') { throw $result.Message }
        $result.Status | Should -Be 'Skipped'
        $global:TestCalls | Should -BeGreaterThan 1
    }
}
