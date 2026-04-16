#Requires -Version 7.4
<#
.SYNOPSIS
    Wrapper for kubescape CLI (AKS runtime posture scanning).
.DESCRIPTION
    Discovers AKS clusters via Azure Resource Graph (unless a specific cluster is provided),
    obtains kubeconfig context with `az aks get-credentials`, runs kubescape per cluster,
    and returns unified findings.

    Never throws -- designed for graceful degradation in the orchestrator.
.PARAMETER SubscriptionId
    Optional subscription scope used for AKS cluster discovery.
.PARAMETER ManagementGroupId
    Optional management group scope used for AKS cluster discovery.
.PARAMETER ClusterName
    Optional explicit AKS cluster name for a single-cluster scan.
.PARAMETER ResourceGroupName
    Optional resource group for explicit AKS cluster targeting.
.PARAMETER ClusterResourceId
    Optional explicit AKS ARM resource ID.
.PARAMETER Kubeconfig
    Optional kubeconfig path. If omitted, a temporary per-cluster kubeconfig is created.
#>
[CmdletBinding()]
param (
    [string] $SubscriptionId,
    [string] $ManagementGroupId,
    [string] $ClusterName,
    [string] $ResourceGroupName,
    [string] $ClusterResourceId,
    [string] $Kubeconfig
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Test-RequiredCommand {
    param ([Parameter(Mandatory)][string] $Name)
    return ($null -ne (Get-Command $Name -ErrorAction SilentlyContinue))
}

function Get-AksTargets {
    param (
        [string] $ScopeSubscriptionId,
        [string] $ScopeManagementGroupId
    )

    $query = @'
resources
| where type =~ "microsoft.containerservice/managedclusters"
| project id, name, subscriptionId, resourceGroup, location
'@

    try {
        if ($ScopeSubscriptionId) {
            return @(Search-AzGraph -Query $query -Subscription $ScopeSubscriptionId -First 1000 -ErrorAction Stop)
        }
        if ($ScopeManagementGroupId) {
            return @(Search-AzGraph -Query $query -ManagementGroup $ScopeManagementGroupId -First 1000 -ErrorAction Stop)
        }

        $ctx = Get-AzContext -ErrorAction SilentlyContinue
        if ($ctx -and $ctx.Subscription -and $ctx.Subscription.Id) {
            return @(Search-AzGraph -Query $query -Subscription $ctx.Subscription.Id -First 1000 -ErrorAction Stop)
        }
    } catch {
        Write-Warning "AKS discovery via ARG failed: $_"
    }

    return @()
}

function Get-CisControlIds {
    param ([object] $Control)

    $ids = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    function Get-PropValue {
        param ([object] $Obj, [string] $Name)
        if ($null -eq $Obj) { return $null }
        $prop = $Obj.PSObject.Properties[$Name]
        if ($null -eq $prop) { return $null }
        return $prop.Value
    }

    $candidateArrays = @(
        @(Get-PropValue -Obj $Control -Name 'CisIds'),
        @(Get-PropValue -Obj $Control -Name 'controls'),
        @(Get-PropValue -Obj $Control -Name 'controlIDs'),
        @(Get-PropValue -Obj $Control -Name 'frameworkMappings')
    ) | Where-Object { $_ }

    foreach ($arr in $candidateArrays) {
        foreach ($item in @($arr)) {
            if ($null -eq $item) { continue }
            if ($item -is [string]) {
                if ($item -match '([0-9]+(?:\.[0-9]+)+)') { $null = $ids.Add("CIS-$($Matches[1])") }
                continue
            }

            foreach ($propName in @('id', 'ID', 'controlId', 'controlID', 'name', 'title')) {
                $prop = $item.PSObject.Properties[$propName]
                if ($prop -and $prop.Value -and ($prop.Value -match '([0-9]+(?:\.[0-9]+)+)')) {
                    $null = $ids.Add("CIS-$($Matches[1])")
                }
            }
        }
    }

    foreach ($textProp in @('name', 'description', 'detail', 'framework', 'frameworkName', 'controlID', 'controlId')) {
        $value = Get-PropValue -Obj $Control -Name $textProp
        if (-not $value) { continue }
        foreach ($m in [regex]::Matches([string]$value, '([0-9]+(?:\.[0-9]+)+)')) {
            $null = $ids.Add("CIS-$($m.Groups[1].Value)")
        }
    }

    return @($ids | Sort-Object)
}

if (-not (Test-RequiredCommand -Name 'kubescape')) {
    Write-Warning "kubescape is not installed. Skipping kubescape scan. Install from https://github.com/kubescape/kubescape"
    return [PSCustomObject]@{
        Source   = 'kubescape'
        Status   = 'Skipped'
        Message  = 'kubescape CLI not installed'
        Findings = @()
    }
}

if (-not (Test-RequiredCommand -Name 'kubectl')) {
    Write-Warning "kubectl is not installed. Skipping kubescape scan."
    return [PSCustomObject]@{
        Source   = 'kubescape'
        Status   = 'Skipped'
        Message  = 'kubectl CLI not installed'
        Findings = @()
    }
}

$targets = @()
if ($ClusterName -and $ResourceGroupName -and $SubscriptionId) {
    $targets = @(
        [PSCustomObject]@{
            id             = $ClusterResourceId
            name           = $ClusterName
            subscriptionId = $SubscriptionId
            resourceGroup  = $ResourceGroupName
        }
    )
} else {
    $targets = Get-AksTargets -ScopeSubscriptionId $SubscriptionId -ScopeManagementGroupId $ManagementGroupId
}

if (-not $targets -or $targets.Count -eq 0) {
    return [PSCustomObject]@{
        Source   = 'kubescape'
        Status   = 'Skipped'
        Message  = 'No AKS clusters found in scope'
        Findings = @()
    }
}

$findings = [System.Collections.Generic.List[PSCustomObject]]::new()
$messages = [System.Collections.Generic.List[string]]::new()
$successfulClusterScans = 0

foreach ($cluster in $targets) {
    $clusterSubId = [string]$cluster.subscriptionId
    $clusterRg = [string]$cluster.resourceGroup
    $clusterNameValue = [string]$cluster.name
    $clusterArmId = if ($cluster.id) { [string]$cluster.id } elseif ($ClusterResourceId) { [string]$ClusterResourceId } else { '' }

    $usingTempKubeconfig = $false
    $kubeconfigPath = $Kubeconfig
    if (-not $kubeconfigPath) {
        $kubeconfigPath = Join-Path ([System.IO.Path]::GetTempPath()) "azure-analyzer-kubeconfig-$([guid]::NewGuid().ToString('N')).yaml"
        $usingTempKubeconfig = $true
    }

    try {
        if (-not $Kubeconfig) {
            if (-not (Test-RequiredCommand -Name 'az')) {
                $messages.Add("[$clusterNameValue] Azure CLI (az) not installed") | Out-Null
                continue
            }

            $getCredsArgs = @(
                'aks', 'get-credentials',
                '--subscription', $clusterSubId,
                '--resource-group', $clusterRg,
                '--name', $clusterNameValue,
                '--overwrite-existing',
                '--file', $kubeconfigPath,
                '--only-show-errors'
            )

            $null = & az @getCredsArgs 2>&1
            if ($LASTEXITCODE -ne 0) {
                $messages.Add("[$clusterNameValue] Unable to get AKS credentials (cluster-reader permissions may be missing)") | Out-Null
                continue
            }
        }

        $contextName = (& kubectl config current-context --kubeconfig $kubeconfigPath 2>$null | Select-Object -First 1)
        if (-not $contextName) {
            $messages.Add("[$clusterNameValue] kubeconfig context not found") | Out-Null
            continue
        }

        $reportFile = Join-Path ([System.IO.Path]::GetTempPath()) "kubescape-report-$([guid]::NewGuid().ToString('N')).json"
        try {
            $scanArgs = @(
                'scan',
                '--kubeconfig', $kubeconfigPath,
                '--kube-context', $contextName,
                '--format', 'json',
                '--output', $reportFile
            )
            $null = & kubescape @scanArgs 2>&1

            if ($LASTEXITCODE -ne 0 -and -not (Test-Path $reportFile)) {
                $messages.Add("[$clusterNameValue] kubescape scan failed with exit code $LASTEXITCODE") | Out-Null
                continue
            }

            if (-not (Test-Path $reportFile)) {
                $successfulClusterScans++
                continue
            }

            $jsonText = Get-Content -Path $reportFile -Raw -ErrorAction SilentlyContinue
            if (-not $jsonText) {
                $successfulClusterScans++
                continue
            }

            $parsed = $jsonText | ConvertFrom-Json -ErrorAction Stop
            $controls = @()
            if ($parsed.PSObject.Properties['controls'] -and $parsed.controls) {
                $controls = @($parsed.controls)
            } elseif ($parsed.PSObject.Properties['resultsDetails'] -and $parsed.resultsDetails -and $parsed.resultsDetails.PSObject.Properties['controls']) {
                $controls = @($parsed.resultsDetails.controls)
            } elseif ($parsed.PSObject.Properties['controlsReports'] -and $parsed.controlsReports) {
                foreach ($report in @($parsed.controlsReports)) {
                    if ($report.PSObject.Properties['controls'] -and $report.controls) {
                        $controls += @($report.controls)
                    }
                }
            }

            foreach ($control in @($controls)) {
                $controlId = ''
                foreach ($idProp in @('controlID', 'controlId', 'id')) {
                    $idValue = $control.PSObject.Properties[$idProp]
                    if ($idValue -and $idValue.Value) { $controlId = [string]$idValue.Value; break }
                }
                $controlName = ''
                foreach ($nameProp in @('name', 'title')) {
                    $nameValue = $control.PSObject.Properties[$nameProp]
                    if ($nameValue -and $nameValue.Value) { $controlName = [string]$nameValue.Value; break }
                }
                if (-not $controlName) { $controlName = if ($controlId) { "Control $controlId" } else { 'Kubescape control finding' } }

                $status = 'failed'
                foreach ($statusProp in @('status', 'state')) {
                    $statusValue = $control.PSObject.Properties[$statusProp]
                    if ($statusValue -and $statusValue.Value) { $status = [string]$statusValue.Value; break }
                }
                $compliant = $status -match 'pass|compliant|success'

                $rawSev = 'Medium'
                $sevValue = $control.PSObject.Properties['severity']
                if ($sevValue -and $sevValue.Value) { $rawSev = [string]$sevValue.Value }
                $severity = switch -Regex ($rawSev.ToLowerInvariant()) {
                    'critical'         { 'Critical' }
                    'high'             { 'High' }
                    'medium|moderate'  { 'Medium' }
                    'low'              { 'Low' }
                    default            { 'Info' }
                }

                $detail = ''
                foreach ($detailProp in @('description', 'detail')) {
                    $detailValue = $control.PSObject.Properties[$detailProp]
                    if ($detailValue -and $detailValue.Value) { $detail = [string]$detailValue.Value; break }
                }
                $remediation = ''
                $remValue = $control.PSObject.Properties['remediation']
                if ($remValue -and $remValue.Value) { $remediation = [string]$remValue.Value }
                $learnMore = ''
                $urlValue = $control.PSObject.Properties['url']
                if ($urlValue -and $urlValue.Value) { $learnMore = [string]$urlValue.Value }
                $cisIds = Get-CisControlIds -Control $control

                $findings.Add([PSCustomObject]@{
                    Id           = [guid]::NewGuid().ToString()
                    Category     = 'Kubernetes Runtime'
                    Title        = $controlName
                    Severity     = $severity
                    Compliant    = [bool]$compliant
                    Detail       = $detail
                    Remediation  = $remediation
                    ResourceId   = $clusterArmId
                    LearnMoreUrl = $learnMore
                    ControlId    = $controlId
                    CisIds       = @($cisIds)
                    ClusterName  = $clusterNameValue
                }) | Out-Null
            }

            $successfulClusterScans++
        } finally {
            Remove-Item -Path $reportFile -Force -ErrorAction SilentlyContinue
        }
    } catch {
        $messages.Add("[$clusterNameValue] $_") | Out-Null
    } finally {
        if ($usingTempKubeconfig) {
            Remove-Item -Path $kubeconfigPath -Force -ErrorAction SilentlyContinue
        }
    }
}

if ($successfulClusterScans -eq 0) {
    $msg = if ($messages.Count -gt 0) { ($messages -join '; ') } else { 'No AKS clusters could be scanned' }
    return [PSCustomObject]@{
        Source   = 'kubescape'
        Status   = 'Skipped'
        Message  = $msg
        Findings = @()
    }
}

return [PSCustomObject]@{
    Source   = 'kubescape'
    Status   = 'Success'
    Message  = if ($messages.Count -gt 0) { $messages -join '; ' } else { '' }
    Findings = $findings
}
