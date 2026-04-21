#Requires -Version 7.4
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

BeforeAll {
    $script:Here = Split-Path $PSCommandPath -Parent
    $script:RepoRoot = Resolve-Path (Join-Path $script:Here '..' '..')
    $script:Wrapper = Join-Path $script:RepoRoot 'modules' 'Invoke-AppInsights.ps1'
    $script:SubId = '00000000-0000-0000-0000-000000000000'
    $script:AppId = "/subscriptions/$($script:SubId)/resourceGroups/perf-rg/providers/Microsoft.Insights/components/appi-prod"
}

Describe 'Invoke-AppInsights' {
    BeforeEach {
        $global:TestAppId = $script:AppId
        $global:TestSubId = $script:SubId
        $global:CapturedUris = [System.Collections.Generic.List[string]]::new()
        $global:CapturedTimeSpans = [System.Collections.Generic.List[double]]::new()
        $global:RequestQueryCalls = 0

        function global:Get-Module {
            [CmdletBinding()]
            param([string] $Name, [switch] $ListAvailable)
            switch ($Name) {
                'Az.ApplicationInsights' { return [pscustomobject]@{ Name = 'Az.ApplicationInsights'; Version = [version]'2.5.0' } }
                default { return [pscustomobject]@{ Name = 'Az.Accounts'; Version = [version]'2.17.1' } }
            }
        }
        function global:Get-AzContext {
            [CmdletBinding()]
            param()
            [pscustomobject]@{ Account = 'user@test.com' }
        }
        function global:Import-Module {
            [CmdletBinding()]
            param([string] $Name)
        }
        function global:Start-Sleep { param([int] $Seconds) }
    }

    AfterEach {
        foreach ($fn in @('Get-Module', 'Get-AzContext', 'Import-Module', 'Invoke-AzRestMethod', 'Invoke-AzApplicationInsightsQuery', 'Invoke-AzOperationalInsightsQuery', 'Start-Sleep')) {
            if (Test-Path "Function:\global:$fn") {
                Remove-Item "Function:\global:$fn" -ErrorAction SilentlyContinue
            }
        }
        foreach ($v in @('CapturedUris', 'CapturedTimeSpans', 'RequestQueryCalls')) {
            Remove-Variable -Name $v -Scope Global -ErrorAction SilentlyContinue
        }
        Remove-Variable -Name TestAppId -Scope Global -ErrorAction SilentlyContinue
        Remove-Variable -Name TestSubId -Scope Global -ErrorAction SilentlyContinue
    }

    It 'returns Skipped when Az.Accounts module is missing' {
        function global:Get-Module {
            [CmdletBinding()]
            param([string] $Name, [switch] $ListAvailable)
            $null
        }
        $result = & $script:Wrapper -SubscriptionId $script:SubId
        $result.Status | Should -Be 'Skipped'
        $result.Message | Should -Match 'Az.Accounts'
    }

    It 'discovers resources and emits all three query finding types' {
        function global:Invoke-AzRestMethod {
            [CmdletBinding()]
            param($Method, $Uri)
            $global:CapturedUris.Add([string]$Uri) | Out-Null
            [pscustomobject]@{
                StatusCode = 200
                Content    = (@{
                        value = @(
                            @{
                                id = $global:TestAppId
                                name = 'appi-prod'
                                tags = @{
                                    "hidden-link:/subscriptions/$($global:TestSubId)/resourceGroups/perf-rg/providers/Microsoft.Web/sites/orders-api" = 'Resource'
                                }
                                properties = @{
                                    WorkspaceResourceId = "/subscriptions/$($global:TestSubId)/resourceGroups/perf-rg/providers/Microsoft.OperationalInsights/workspaces/ws1"
                                }
                            }
                        )
                    } | ConvertTo-Json -Depth 10)
            }
        }

        function global:Invoke-AzApplicationInsightsQuery {
            [CmdletBinding()]
            param(
                [string] $ResourceGroupName,
                [string] $Name,
                [string] $Query,
                [timespan] $TimeSpan
            )
            $global:CapturedTimeSpans.Add($TimeSpan.TotalHours) | Out-Null

            if ($Query -match '^requests') {
                return [pscustomobject]@{
                    Results = @(
                        [pscustomobject]@{ name = 'GET /orders'; count_ = 12; avg_duration = '00:00:06' }
                    )
                }
            }
            if ($Query -match '^dependencies') {
                return [pscustomobject]@{
                    Results = @(
                        [pscustomobject]@{ name = 'sql-prod'; type = 'SQL'; count_ = 6 }
                    )
                }
            }
            if ($Query -match '^exceptions') {
                return [pscustomobject]@{
                    Results = @(
                        [pscustomobject]@{ problemId = 'NullReferenceException'; count_ = 75 }
                    )
                }
            }
            return [pscustomobject]@{ Results = @() }
        }

        $result = & $script:Wrapper -SubscriptionId $script:SubId -TimeRangeHours 24
        if ($result.Status -eq 'Failed') { throw $result.Message }

        $result.Status | Should -Be 'Success'
        $result.Findings.Count | Should -Be 3
        @($result.Findings | Where-Object { $_.QueryType -eq 'requests' }).Count | Should -Be 1
        @($result.Findings | Where-Object { $_.QueryType -eq 'dependencies' }).Count | Should -Be 1
        @($result.Findings | Where-Object { $_.QueryType -eq 'exceptions' }).Count | Should -Be 1
        @($global:CapturedTimeSpans | Select-Object -Unique) | Should -Be @(24)

        $requestFinding = @($result.Findings | Where-Object { $_.QueryType -eq 'requests' })[0]
        $requestFinding.Pillar | Should -Be 'PerformanceEfficiency'
        $requestFinding.DeepLinkUrl | Should -Match '^https://portal\.azure\.com/#blade/Microsoft_OperationsManagementSuite_Workspace/AnalyticsBlade/'
        $requestFinding.EvidenceUris | Should -Contain $requestFinding.DeepLinkUrl
        $requestFinding.BaselineTags | Should -Contain 'AppInsights-SlowRequests'
        $requestFinding.ScoreDelta | Should -Be 6
        $requestFinding.ToolVersion | Should -Be 'Az.ApplicationInsights/2.5.0'
        $requestFinding.EntityRefs | Should -Contain $script:AppId
        @($requestFinding.EntityRefs | Where-Object { $_ -match '/providers/Microsoft\.Web/sites/orders-api$' }).Count | Should -Be 1
    }

    It 'uses resource group and app name filters in discovery URI' {
        function global:Invoke-AzRestMethod {
            [CmdletBinding()]
            param($Method, $Uri)
            $global:CapturedUris.Add([string]$Uri) | Out-Null
            [pscustomobject]@{
                StatusCode = 200
                Content    = (@{
                        id   = $global:TestAppId
                        name = 'appi-prod'
                    } | ConvertTo-Json -Depth 10)
            }
        }

        function global:Invoke-AzApplicationInsightsQuery {
            [CmdletBinding()]
            param([string] $ResourceGroupName, [string] $Name, [string] $Query, [timespan] $TimeSpan)
            [pscustomobject]@{ Results = @() }
        }

        $result = & $script:Wrapper -SubscriptionId $script:SubId -ResourceGroup 'perf-rg' -AppInsightsName 'appi-prod'
        if ($result.Status -eq 'Failed') { throw $result.Message }

        $global:CapturedUris.Count | Should -BeGreaterThan 0
        $global:CapturedUris[0] | Should -Match '/resourceGroups/perf-rg/providers/Microsoft\.Insights/components/appi-prod'
    }

    It 'retries query on transient throttling' {
        function global:Invoke-AzRestMethod {
            [CmdletBinding()]
            param($Method, $Uri)
            [pscustomobject]@{
                StatusCode = 200
                Content    = (@{
                        value = @(
                            @{
                                id = $global:TestAppId
                                name = 'appi-prod'
                            }
                        )
                    } | ConvertTo-Json -Depth 10)
            }
        }

        function global:Invoke-AzApplicationInsightsQuery {
            [CmdletBinding()]
            param([string] $ResourceGroupName, [string] $Name, [string] $Query, [timespan] $TimeSpan)
            if ($Query -match '^requests') {
                $global:RequestQueryCalls++
                if ($global:RequestQueryCalls -eq 1) {
                    throw '429 Too Many Requests'
                }
                return [pscustomobject]@{
                    Results = @([pscustomobject]@{ name = 'GET /health'; count_ = 11; avg_duration = '00:00:07' })
                }
            }
            return [pscustomobject]@{ Results = @() }
        }

        $result = & $script:Wrapper -SubscriptionId $script:SubId
        if ($result.Status -eq 'Failed') { throw $result.Message }

        $result.Status | Should -Be 'Success'
        $global:RequestQueryCalls | Should -BeGreaterThan 1
    }
}
