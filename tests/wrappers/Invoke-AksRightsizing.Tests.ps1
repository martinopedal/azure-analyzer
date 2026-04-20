#Requires -Version 7.4
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

BeforeAll {
    $script:Here = Split-Path $PSCommandPath -Parent
    $script:RepoRoot = Resolve-Path (Join-Path $script:Here '..' '..')
    $script:Wrapper = Join-Path $script:RepoRoot 'modules' 'Invoke-AksRightsizing.ps1'
    $script:SubId = '00000000-0000-0000-0000-000000000000'
    $script:ClusterId = "/subscriptions/$($script:SubId)/resourceGroups/rg-aks/providers/Microsoft.ContainerService/managedClusters/aks-prod"
}

Describe 'Invoke-AksRightsizing' {
    AfterAll {
        foreach ($fn in @('Get-Module', 'Import-Module', 'Get-AzContext', 'Get-AksClustersInScope', 'Invoke-LogAnalyticsQuery', 'Invoke-AzOperationalInsightsQuery', 'Invoke-AzRestMethod', 'Invoke-WithTimeout', 'Start-Sleep')) {
            if (Test-Path "Function:global:$fn") {
                Remove-Item "Function:global:$fn" -ErrorAction SilentlyContinue
            }
            if (Test-Path "Function:$fn") {
                Remove-Item "Function:$fn" -ErrorAction SilentlyContinue
            }
        }
        Remove-Variable -Name TestClusterId -Scope Global -ErrorAction SilentlyContinue
        Remove-Variable -Name CapturedQueries -Scope Global -ErrorAction SilentlyContinue
        Remove-Variable -Name KqlCalls -Scope Global -ErrorAction SilentlyContinue
    }

    BeforeEach {
        $global:TestClusterId = "/subscriptions/$($script:SubId)/resourceGroups/rg-aks/providers/Microsoft.ContainerService/managedClusters/aks-prod"
        $global:CapturedQueries = [System.Collections.Generic.List[string]]::new()
        function global:Get-Module {
            [CmdletBinding()]
            param([string] $Name, [switch] $ListAvailable)
            if ($ListAvailable -and $Name -in @('Az.Accounts', 'Az.OperationalInsights', 'Az.ResourceGraph')) {
                return [PSCustomObject]@{ Name = $Name }
            }
            return $null
        }
        function global:Import-Module {
            [CmdletBinding()]
            param([string] $Name)
        }
        function global:Get-AzContext {
            [CmdletBinding()]
            param()
            [PSCustomObject]@{ Subscription = $script:SubId }
        }
        function global:Invoke-WithTimeout {
            [CmdletBinding()]
            param([string] $Command, [string[]] $Arguments, [int] $TimeoutSec)
            [PSCustomObject]@{ ExitCode = 0; Output = '' }
        }
        function global:Invoke-AzOperationalInsightsQuery {
            [CmdletBinding()]
            param([string] $WorkspaceId, [string] $Query, [int] $Wait)
            $global:CapturedQueries.Add($Query) | Out-Null
            [PSCustomObject]@{ Results = @() }
        }
        function global:Invoke-LogAnalyticsQuery {
            [CmdletBinding()]
            param([string] $WorkspaceId, [string] $Query, [int] $TimeoutSeconds)
            $global:CapturedQueries.Add($Query) | Out-Null
            [PSCustomObject]@{ Results = @() }
        }
        function global:Get-AksClustersInScope {
            [CmdletBinding()]
            param([string] $SubscriptionId, [string] $ResourceGroup, [string] $ClusterName, [string[]] $ClusterArmIds)
            @(
                [PSCustomObject]@{
                    id = $global:TestClusterId
                    name = 'aks-prod'
                    resourceGroup = 'rg-aks'
                    subscriptionId = $SubscriptionId
                    workspaceResourceId = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-law/providers/Microsoft.OperationalInsights/workspaces/law-prod'
                }
            )
        }
    }

    AfterEach {
        foreach ($fn in @('Get-Module', 'Import-Module', 'Get-AzContext', 'Get-AksClustersInScope', 'Invoke-LogAnalyticsQuery', 'Invoke-AzOperationalInsightsQuery', 'Invoke-AzRestMethod', 'Invoke-WithTimeout', 'Start-Sleep')) {
            if (Test-Path "Function:global:$fn") {
                Remove-Item "Function:global:$fn" -ErrorAction SilentlyContinue
            }
        }
        Remove-Variable -Name TestClusterId -Scope Global -ErrorAction SilentlyContinue
        Remove-Variable -Name CapturedQueries -Scope Global -ErrorAction SilentlyContinue
        Remove-Variable -Name KqlCalls -Scope Global -ErrorAction SilentlyContinue
    }

    It 'emits all four rightsizing categories from KQL rows' {
        function global:Invoke-LogAnalyticsQuery {
            [CmdletBinding()]
            param([string] $WorkspaceId, [string] $Query, [int] $TimeoutSeconds)
            if ($Query -match 'p95_cpu < cpuLimitNano \* 0.2') {
                return [PSCustomObject]@{ Results = @([PSCustomObject]@{ Namespace = 'prod'; WorkloadName = 'api'; ContainerName = 'api'; observedPct = 12.0; recommendedMillicores = 120.0 }) }
            }
            if ($Query -match 'p95_cpu >= cpuLimitNano \* 0.95') {
                return [PSCustomObject]@{ Results = @([PSCustomObject]@{ Namespace = 'prod'; WorkloadName = 'api'; ContainerName = 'api'; observedPct = 98.0 }) }
            }
            if ($Query -match 'p95_mem < memoryLimitBytes \* 0.2') {
                return [PSCustomObject]@{ Results = @([PSCustomObject]@{ Namespace = 'prod'; WorkloadName = 'api'; ContainerName = 'api'; observedPct = 15.0; recommendedMemoryMiB = 256.0 }) }
            }
            if ($Query -match 'p95_mem >= memoryLimitBytes \* 0.95') {
                return [PSCustomObject]@{ Results = @([PSCustomObject]@{ Namespace = 'prod'; WorkloadName = 'worker'; ContainerName = 'worker'; observedPct = 99.4 }) }
            }
            if ($Query -match 'replicasMin == replicasMax') {
                return [PSCustomObject]@{ Results = @([PSCustomObject]@{ Namespace = 'prod'; ControllerName = 'api'; replicasMin = 3; replicasMax = 3 }) }
            }
            if ($Query -match "ContainerStatusReason =~ 'OOMKilled'") {
                return [PSCustomObject]@{ Results = @([PSCustomObject]@{ Namespace = 'prod'; WorkloadName = 'api'; ContainerName = 'api'; ContainerStatusReason = 'OOMKilled'; PodStatus = 'Failed' }) }
            }
            return [PSCustomObject]@{ Results = @() }
        }

        $result = & $script:Wrapper -SubscriptionId $script:SubId -LookbackDays 7
        $result.Status | Should -Be 'Success'
        @($result.Findings | Where-Object { $_.FindingCategory -eq 'OverProvisionedCpu' }).Count | Should -Be 1
        @($result.Findings | Where-Object { $_.FindingCategory -eq 'UnderProvisionedCpu' }).Count | Should -Be 1
        @($result.Findings | Where-Object { $_.FindingCategory -eq 'OverProvisionedMemory' }).Count | Should -Be 1
        @($result.Findings | Where-Object { $_.FindingCategory -eq 'UnderProvisionedMemory' }).Count | Should -Be 1
        @($result.Findings | Where-Object { $_.FindingCategory -eq 'MissingHpa' }).Count | Should -Be 1
        @($result.Findings | Where-Object { $_.FindingCategory -eq 'OomKilled' }).Count | Should -Be 1
    }

    It 'passes LookbackDays into generated KQL' {
        function global:Invoke-LogAnalyticsQuery {
            [CmdletBinding()]
            param([string] $WorkspaceId, [string] $Query, [int] $TimeoutSeconds)
            $global:CapturedQueries.Add($Query) | Out-Null
            [PSCustomObject]@{ Results = @() }
        }

        $null = & $script:Wrapper -SubscriptionId $script:SubId -LookbackDays 11
        ($global:CapturedQueries -join "`n") | Should -Match 'ago\(11d\)'
    }

    It 'returns Success with empty findings when no KQL rows are returned' {
        function global:Invoke-LogAnalyticsQuery {
            [CmdletBinding()]
            param([string] $WorkspaceId, [string] $Query, [int] $TimeoutSeconds)
            [PSCustomObject]@{ Results = @() }
        }

        $result = & $script:Wrapper -SubscriptionId $script:SubId
        $result.Status | Should -Be 'Success'
        @($result.Findings).Count | Should -Be 0
    }

    It 'retries transient throttling from KQL query calls' {
        $global:KqlCalls = 0
        function global:Start-Sleep { param([int] $Seconds) }
        function global:Invoke-LogAnalyticsQuery {
            [CmdletBinding()]
            param([string] $WorkspaceId, [string] $Query, [int] $TimeoutSeconds)
            $global:KqlCalls++
            if ($global:KqlCalls -eq 1) {
                throw '429 Too Many Requests'
            }
            [PSCustomObject]@{ Results = @() }
        }

        $result = & $script:Wrapper -SubscriptionId $script:SubId
        $result.Status | Should -Be 'Success'
        $global:KqlCalls | Should -BeGreaterThan 1
    }

    It 'returns Skipped when no AKS clusters are discovered' {
        function global:Get-AksClustersInScope {
            [CmdletBinding()]
            param([string] $SubscriptionId, [string] $ResourceGroup, [string] $ClusterName, [string[]] $ClusterArmIds)
            @()
        }
        function global:Invoke-LogAnalyticsQuery {
            [CmdletBinding()]
            param([string] $WorkspaceId, [string] $Query, [int] $TimeoutSeconds)
            [PSCustomObject]@{ Results = @() }
        }

        $result = & $script:Wrapper -SubscriptionId $script:SubId
        $result.Status | Should -Be 'Skipped'
        $result.Message | Should -Match 'No AKS managed clusters'
    }

    It 'returns Failed when workspace cannot be resolved for any cluster' {
        function global:Get-AksClustersInScope {
            [CmdletBinding()]
            param([string] $SubscriptionId, [string] $ResourceGroup, [string] $ClusterName, [string[]] $ClusterArmIds)
            @(
                [PSCustomObject]@{
                    id = $global:TestClusterId
                    name = 'aks-prod'
                    resourceGroup = 'rg-aks'
                    subscriptionId = $SubscriptionId
                    workspaceResourceId = ''
                }
            )
        }
        function global:Invoke-AzRestMethod {
            [CmdletBinding()]
            param([string] $Method, [string] $Uri)
            [PSCustomObject]@{ StatusCode = 200; Content = '{"value":[]}' }
        }
        function global:Invoke-LogAnalyticsQuery {
            [CmdletBinding()]
            param([string] $WorkspaceId, [string] $Query, [int] $TimeoutSeconds)
            [PSCustomObject]@{ Results = @() }
        }

        $result = & $script:Wrapper -SubscriptionId $script:SubId
        $result.Status | Should -Be 'Failed'
        $result.Message | Should -Match 'workspace'
    }
}
