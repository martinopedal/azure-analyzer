#Requires -Version 7.4
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

BeforeAll {
    $script:Here = Split-Path $PSCommandPath -Parent
    $script:RepoRoot = Resolve-Path (Join-Path $script:Here '..' '..')
    $script:Wrapper = Join-Path $script:RepoRoot 'modules' 'Invoke-AksKarpenterCost.ps1'
    $script:SubId           = '11111111-1111-1111-1111-111111111111'
    $global:AaTestSubId     = $script:SubId
    $global:AaTestClusterId = "/subscriptions/$($global:AaTestSubId)/resourceGroups/rg-aks/providers/Microsoft.ContainerService/managedClusters/aks-prod"
    $global:AaTestWsId      = '/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-law/providers/Microsoft.OperationalInsights/workspaces/law-prod'
    $global:AaTestRepoRoot  = $script:RepoRoot
}

Describe 'Invoke-AksKarpenterCost' {
    AfterAll {
        foreach ($fn in @(
                'Get-Module', 'Import-Module', 'Get-AzContext',
                'Get-AksClustersInScope', 'Invoke-LogAnalyticsQuery',
                'Invoke-AzOperationalInsightsQuery', 'Invoke-AzRestMethod',
                'Invoke-WithTimeout', 'Initialize-KubeAuth',
                'Start-Sleep', 'kubectl'
            )) {
            if (Test-Path "Function:global:$fn") { Remove-Item "Function:global:$fn" -ErrorAction SilentlyContinue }
        }
        Remove-Variable -Name KqlCalls -Scope Global -ErrorAction SilentlyContinue
        Remove-Variable -Name KubectlCalls -Scope Global -ErrorAction SilentlyContinue
        Remove-Variable -Name KubeAuthCalls -Scope Global -ErrorAction SilentlyContinue
    }

    BeforeEach {
        $global:KqlCalls = 0
        $global:KubectlCalls = 0
        $global:KubeAuthCalls = 0

        function global:Get-Module {
            [CmdletBinding()]
            param([string] $Name, [switch] $ListAvailable)
            if ($ListAvailable -and $Name -in @('Az.Accounts', 'Az.OperationalInsights', 'Az.ResourceGraph')) {
                return [PSCustomObject]@{ Name = $Name }
            }
            return $null
        }
        function global:Import-Module { param([string] $Name) }
        function global:Get-AzContext { [PSCustomObject]@{ Subscription = $global:AaTestSubId } }
        function global:Get-AksClustersInScope {
            param([string] $SubscriptionId, [string] $ResourceGroup, [string] $ClusterName, [string[]] $ClusterArmIds)
            @(
                [PSCustomObject]@{
                    id = $global:AaTestClusterId
                    name = 'aks-prod'
                    resourceGroup = 'rg-aks'
                    subscriptionId = $SubscriptionId
                    workspaceResourceId = $global:AaTestWsId
                }
            )
        }
        function global:Invoke-LogAnalyticsQuery {
            param([string] $WorkspaceId, [string] $Query, [int] $TimeoutSeconds)
            $global:KqlCalls++
            if ($Query -match 'KubeNodeInventory[\s\S]*summarize firstSeen') {
                return [PSCustomObject]@{ Results = @([PSCustomObject]@{ nodes = 5; totalNodeHours = 840.0 }) }
            }
            if ($Query -match "ObjectName == 'K8SNode'[\s\S]*pct < 10\.0") {
                return [PSCustomObject]@{ Results = @([PSCustomObject]@{ Computer = 'aks-node-1'; observedPct = 4.5; avg_cpu = 100 }) }
            }
            if ($Query -match 'avgPct < 50\.0') {
                return [PSCustomObject]@{ Results = @([PSCustomObject]@{ avgPct = 22.0; nodeCount = 4 }) }
            }
            return [PSCustomObject]@{ Results = @() }
        }
        function global:Invoke-WithTimeout {
            param([string] $Command, [string[]] $Arguments, [int] $TimeoutSec)
            if ($Command -eq 'kubectl') {
                $global:KubectlCalls++
                if (($Arguments -join ' ') -match 'version') {
                    return [PSCustomObject]@{
                        ExitCode = 0
                        Output   = "clientVersion:`n  gitVersion: v1.31.0"
                    }
                }
                $fixturePath = Join-Path $global:AaTestRepoRoot 'tests' 'fixtures' 'aks-karpenter-cost' 'kubectl-provisioners.json'
                $body = Get-Content $fixturePath -Raw
                return [PSCustomObject]@{ ExitCode = 0; Output = $body }
            }
            return [PSCustomObject]@{ ExitCode = 0; Output = '' }
        }
        function global:kubectl { param() }
        function global:Initialize-KubeAuth {
            param(
                [string] $Mode, [string] $KubeconfigPath, [switch] $KubeconfigOwned, [string] $KubeContext,
                [string] $KubeloginServerId, [string] $KubeloginClientId, [string] $KubeloginTenantId,
                [string] $WorkloadIdentityClientId, [string] $WorkloadIdentityTenantId, [string] $WorkloadIdentityServiceAccountToken
            )
            $global:KubeAuthCalls++
            [PSCustomObject]@{
                KubeconfigPath = $KubeconfigPath
                Cleanup        = { }.GetNewClosure()
            }
        }
    }

    AfterEach {
        foreach ($fn in @(
                'Get-Module', 'Import-Module', 'Get-AzContext',
                'Get-AksClustersInScope', 'Invoke-LogAnalyticsQuery',
                'Invoke-AzOperationalInsightsQuery', 'Invoke-AzRestMethod',
                'Invoke-WithTimeout', 'Initialize-KubeAuth', 'Start-Sleep', 'kubectl'
            )) {
            if (Test-Path "Function:global:$fn") { Remove-Item "Function:global:$fn" -ErrorAction SilentlyContinue }
        }
        Remove-Variable -Name KqlCalls -Scope Global -ErrorAction SilentlyContinue
        Remove-Variable -Name KubectlCalls -Scope Global -ErrorAction SilentlyContinue
        Remove-Variable -Name KubeAuthCalls -Scope Global -ErrorAction SilentlyContinue
    }

    Context 'Reader-only tier (default; -EnableElevatedRbac NOT set)' {
        It 'declares WhatIf common parameter for ShouldProcess support' {
            $cmd = Get-Command -Name $script:Wrapper
            $cmd.Parameters.Keys | Should -Contain 'WhatIf'
        }

        It 'emits cost rollup + idle node findings and never invokes kubectl' {
            $result = & $script:Wrapper -SubscriptionId $script:SubId -LookbackDays 7
            $result.Status   | Should -Be 'Success'
            $result.RbacTier | Should -Be 'Reader'
            @($result.Findings | Where-Object { $_.RuleId -eq 'aks.node-cost-rollup' }).Count | Should -Be 1
            @($result.Findings | Where-Object { $_.RuleId -eq 'aks.idle-node' }).Count        | Should -Be 1
            @($result.Findings | Where-Object { $_.RuleId -like 'karpenter.*' }).Count        | Should -Be 0
            $global:KubectlCalls  | Should -Be 0
            $global:KubeAuthCalls | Should -Be 0
        }

        It 'cost rollup math reflects KubeNodeInventory result rows' {
            $result = & $script:Wrapper -SubscriptionId $script:SubId
            $cost = $result.Findings | Where-Object { $_.RuleId -eq 'aks.node-cost-rollup' } | Select-Object -First 1
            $cost.NodeCount | Should -Be 5
            $cost.NodeHours | Should -Be 840.0
            $cost.Pillar | Should -Be 'Cost Optimization'
            $cost.Impact | Should -Be 'High'
            $cost.Effort | Should -Be 'Low'
            $cost.BaselineTags | Should -Contain 'Karpenter-NodeHours'
            $cost.BaselineTags | Should -Contain 'RBAC-Reader'
            $cost.ScoreDelta | Should -Be 840.0
            $cost.DeepLinkUrl | Should -Match 'Microsoft_Azure_ContainerService'
            @($cost.EntityRefs) | Should -Contain $global:AaTestClusterId
            @($cost.EvidenceUris).Count | Should -BeGreaterThan 0
        }

        It 'passes LookbackDays into generated KQL' {
            $captured = [System.Collections.Generic.List[string]]::new()
            function global:Invoke-LogAnalyticsQuery {
                param([string] $WorkspaceId, [string] $Query, [int] $TimeoutSeconds)
                $captured.Add($Query) | Out-Null
                [PSCustomObject]@{ Results = @() }
            }
            $null = & $script:Wrapper -SubscriptionId $script:SubId -LookbackDays 14
            ($captured -join "`n") | Should -Match 'ago\(14d\)'
        }

        It 'retries transient throttling from KQL calls' {
            $global:KqlCalls = 0
            function global:Start-Sleep { param([int] $Seconds) }
            function global:Invoke-LogAnalyticsQuery {
                param([string] $WorkspaceId, [string] $Query, [int] $TimeoutSeconds)
                $global:KqlCalls++
                if ($global:KqlCalls -eq 1) { throw '429 Too Many Requests' }
                [PSCustomObject]@{ Results = @() }
            }
            $result = & $script:Wrapper -SubscriptionId $script:SubId
            $result.Status   | Should -BeIn @('Success', 'PartialSuccess')
            $global:KqlCalls | Should -BeGreaterThan 1
        }

        It 'returns Skipped when no AKS clusters are discovered' {
            function global:Get-AksClustersInScope {
                param([string] $SubscriptionId, [string] $ResourceGroup, [string] $ClusterName, [string[]] $ClusterArmIds)
                @()
            }
            $result = & $script:Wrapper -SubscriptionId $script:SubId
            $result.Status  | Should -Be 'Skipped'
            $result.Message | Should -Match 'No AKS managed clusters'
        }
    }

    Context 'Elevated tier (-EnableElevatedRbac)' {
        It 'skips kubectl + kube-auth side effects when -WhatIf is set' {
            $tmpKube = Join-Path ([System.IO.Path]::GetTempPath()) ("aa-test-kube-{0}.yaml" -f ([guid]::NewGuid().ToString('N')))
            Set-Content -Path $tmpKube -Value 'apiVersion: v1' -Encoding UTF8
            try {
                $result = & $script:Wrapper -SubscriptionId $script:SubId -EnableElevatedRbac -KubeconfigPath $tmpKube -WhatIf
                $result.Status | Should -BeIn @('Success', 'PartialSuccess')
                $global:KubectlCalls  | Should -Be 0
                $global:KubeAuthCalls | Should -Be 0
            } finally {
                Remove-Item -LiteralPath $tmpKube -ErrorAction SilentlyContinue
            }
        }

        It 'invokes kubectl and emits Karpenter findings' {
            $tmpKube = Join-Path ([System.IO.Path]::GetTempPath()) ("aa-test-kube-{0}.yaml" -f ([guid]::NewGuid().ToString('N')))
            Set-Content -Path $tmpKube -Value 'apiVersion: v1' -Encoding UTF8
            try {
                $result = & $script:Wrapper -SubscriptionId $script:SubId -EnableElevatedRbac -KubeconfigPath $tmpKube -Confirm:$false
                $result.Status   | Should -BeIn @('Success', 'PartialSuccess')
                $result.RbacTier | Should -Be 'ClusterUser'
                @($result.Findings | Where-Object { $_.RuleId -eq 'karpenter.consolidation-disabled' }).Count | Should -Be 1
                @($result.Findings | Where-Object { $_.RuleId -eq 'karpenter.no-node-limit' }).Count          | Should -Be 1
                @($result.Findings | Where-Object { $_.RuleId -eq 'karpenter.over-provisioned' }).Count       | Should -BeGreaterThan 0
                $result.ToolVersion | Should -Match 'kubectl=v1.31.0'
                $result.ToolVersion | Should -Match 'karpenter='
                $global:KubectlCalls  | Should -BeGreaterThan 0
                $global:KubeAuthCalls | Should -Be 1
            } finally {
                Remove-Item -LiteralPath $tmpKube -ErrorAction SilentlyContinue
            }
        }

        It 'records ClusterUser tier on every emitted finding' {
            $tmpKube = Join-Path ([System.IO.Path]::GetTempPath()) ("aa-test-kube-{0}.yaml" -f ([guid]::NewGuid().ToString('N')))
            Set-Content -Path $tmpKube -Value 'apiVersion: v1' -Encoding UTF8
            try {
                $result = & $script:Wrapper -SubscriptionId $script:SubId -EnableElevatedRbac -KubeconfigPath $tmpKube -Confirm:$false
                foreach ($f in $result.Findings) {
                    $f.RbacTier | Should -Be 'ClusterUser'
                }
            } finally {
                Remove-Item -LiteralPath $tmpKube -ErrorAction SilentlyContinue
            }
        }

        It 'fails the elevated branch with workspace error when KubeconfigPath is absent' {
            $result = & $script:Wrapper -SubscriptionId $script:SubId -EnableElevatedRbac
            $result.Status   | Should -BeIn @('PartialSuccess', 'Failed', 'Success')
            $result.Message  | Should -Match 'KubeconfigPath required'
            @($result.Findings | Where-Object { $_.RuleId -like 'karpenter.*' }).Count | Should -Be 0
            $global:KubectlCalls  | Should -Be 0
            $global:KubeAuthCalls | Should -Be 0
        }

        It 'detects only the un-consolidated provisioner from the kubectl fixture' {
            $tmpKube = Join-Path ([System.IO.Path]::GetTempPath()) ("aa-test-kube-{0}.yaml" -f ([guid]::NewGuid().ToString('N')))
            Set-Content -Path $tmpKube -Value 'apiVersion: v1' -Encoding UTF8
            try {
                $result = & $script:Wrapper -SubscriptionId $script:SubId -EnableElevatedRbac -KubeconfigPath $tmpKube -Confirm:$false
                # Fixture has provisioner 'default' (no consolidation, no limits) and 'spot' (both set).
                $consolidationFindings = @($result.Findings | Where-Object { $_.RuleId -eq 'karpenter.consolidation-disabled' })
                $consolidationFindings.Count               | Should -Be 1
                $consolidationFindings[0].ProvisionerName  | Should -Be 'default'

                $limitFindings = @($result.Findings | Where-Object { $_.RuleId -eq 'karpenter.no-node-limit' })
                $limitFindings.Count               | Should -Be 1
                $limitFindings[0].ProvisionerName  | Should -Be 'default'
            } finally {
                Remove-Item -LiteralPath $tmpKube -ErrorAction SilentlyContinue
            }
        }
    }
}
