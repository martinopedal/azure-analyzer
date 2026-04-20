#Requires -Version 7.4
[CmdletBinding()]
param ()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-AksClustersInScope {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $SubscriptionId,

        [string] $ResourceGroup,
        [string] $ClusterName,
        [string[]] $ClusterArmIds
    )

    $normalizedIds = @()
    if ($ClusterArmIds -and $ClusterArmIds.Count -gt 0) {
        $normalizedIds = @(
            $ClusterArmIds |
                Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } |
                ForEach-Object { ([string]$_).Trim().ToLowerInvariant() }
        )
        if ([string]::IsNullOrWhiteSpace($ResourceGroup) -and [string]::IsNullOrWhiteSpace($ClusterName)) {
            $direct = [System.Collections.Generic.List[object]]::new()
            foreach ($clusterId in $ClusterArmIds) {
                $idText = [string]$clusterId
                if ([string]::IsNullOrWhiteSpace($idText)) { continue }
                $resourceGroupFromId = if ($idText -match '/resourceGroups/([^/]+)') { [string]$Matches[1] } else { '' }
                $nameFromId = if ($idText -match '/managedClusters/([^/]+)$') { [string]$Matches[1] } else { (Split-Path $idText -Leaf) }
                $direct.Add([PSCustomObject]@{
                        id                  = $idText
                        name                = $nameFromId
                        resourceGroup       = $resourceGroupFromId
                        subscriptionId      = $SubscriptionId
                        location            = ''
                        workspaceResourceId = ''
                    }) | Out-Null
            }
            return @($direct)
        }
    }

    if (-not (Get-Module -ListAvailable -Name Az.ResourceGraph)) {
        throw 'Az.ResourceGraph module not installed; cannot discover AKS clusters.'
    }

    Import-Module Az.ResourceGraph -ErrorAction SilentlyContinue -WarningAction SilentlyContinue

    $baseQuery = @"
Resources
| where type =~ 'Microsoft.ContainerService/managedClusters'
| where subscriptionId == '$SubscriptionId'
| project
    id,
    name,
    resourceGroup,
    subscriptionId,
    location,
    workspaceResourceId = tostring(properties.addonProfiles.omsagent.config.logAnalyticsWorkspaceResourceID)
"@

    if (-not [string]::IsNullOrWhiteSpace($ResourceGroup)) {
        $escapedRg = $ResourceGroup.Replace("'", "''")
        $baseQuery += "`n| where resourceGroup =~ '$escapedRg'"
    }
    if (-not [string]::IsNullOrWhiteSpace($ClusterName)) {
        $escapedCluster = $ClusterName.Replace("'", "''")
        $baseQuery += "`n| where name =~ '$escapedCluster'"
    }

    $clusters = @(
        Invoke-WithRetry -MaxAttempts 3 -InitialDelaySeconds 2 -MaxDelaySeconds 20 -ScriptBlock {
            Search-AzGraph -Query $baseQuery -First 1000 -ErrorAction Stop
        }
    )

    $filtered = [System.Collections.Generic.List[object]]::new()
    foreach ($cluster in $clusters) {
        if (-not $cluster) { continue }

        $clusterId = [string]$cluster.id
        if ([string]::IsNullOrWhiteSpace($clusterId)) { continue }
        $normalizedId = $clusterId.Trim().ToLowerInvariant()

        if ($normalizedIds.Count -gt 0 -and ($normalizedIds -notcontains $normalizedId)) {
            continue
        }

        $workspaceResourceId = ''
        if ($cluster.PSObject.Properties['workspaceResourceId'] -and $cluster.workspaceResourceId) {
            $workspaceResourceId = [string]$cluster.workspaceResourceId
        }

        $filtered.Add([PSCustomObject]@{
                id                  = $clusterId
                name                = [string]$cluster.name
                resourceGroup       = [string]$cluster.resourceGroup
                subscriptionId      = [string]$cluster.subscriptionId
                location            = [string]$cluster.location
                workspaceResourceId = $workspaceResourceId
            }) | Out-Null
    }

    return @($filtered)
}
