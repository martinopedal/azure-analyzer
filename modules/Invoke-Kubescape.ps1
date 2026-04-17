#requires -Version 7.0
<#
.SYNOPSIS
    Wrapper for kubescape — Kubernetes posture scanning against CIS K8s Benchmark + NSA/CISA hardening.

.DESCRIPTION
    Discovers AKS managed clusters in scope via Azure Resource Graph, fetches kubeconfig
    for each with `az aks get-credentials --overwrite-existing`, and runs
    `kubescape scan --format json --output <tempfile>` against each cluster context.

    Returns a standardized v1 tool-result shape. The Normalize-Kubescape normalizer
    downstream converts the per-control output into v2 FindingRows with ResourceId set
    to the AKS cluster's ARM ID, so each finding folds onto the existing AzureResource
    entity (next to azqr/PSRule/Defender findings on the same cluster).

    Gracefully skips when:
      - kubectl or kubescape is not installed
      - no AKS clusters are in scope
      - `az aks get-credentials` fails (cluster-read permission missing / RBAC denied)

.PARAMETER SubscriptionId
    Azure subscription ID (GUID). Required.

.PARAMETER ClusterArmIds
    Optional pre-filtered list of AKS cluster ARM IDs (overrides ARG discovery).

.PARAMETER OutputPath
    Optional directory for per-cluster raw kubescape JSON (for audit).
#>
[CmdletBinding()]
param (
    [Parameter(Mandatory)] [string] $SubscriptionId,
    [string[]] $ClusterArmIds,
    [string] $OutputPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$retryPath = Join-Path $PSScriptRoot 'shared' 'Retry.ps1'
if (Test-Path $retryPath) { . $retryPath }
if (-not (Get-Command Invoke-WithRetry -ErrorAction SilentlyContinue)) {
    function Invoke-WithRetry { param([scriptblock]$ScriptBlock, [int]$MaxAttempts = 3) & $ScriptBlock }
}

$result = [ordered]@{
    SchemaVersion = '1.0'
    Source        = 'kubescape'
    Status        = 'Success'
    Message       = ''
    Findings      = @()
    Subscription  = $SubscriptionId
    Timestamp     = (Get-Date).ToUniversalTime().ToString('o')
}

# --- Tool prereqs ---
if (-not (Get-Command kubescape -ErrorAction SilentlyContinue)) {
    $result.Status  = 'Skipped'
    $result.Message = 'kubescape CLI not installed. Install via: winget install ARMO.kubescape  |  brew install kubescape  |  curl -s https://raw.githubusercontent.com/kubescape/kubescape/master/install.sh | /bin/bash'
    return [pscustomobject]$result
}
if (-not (Get-Command kubectl -ErrorAction SilentlyContinue)) {
    $result.Status  = 'Skipped'
    $result.Message = 'kubectl not installed. kubescape requires kubectl to reach cluster API.'
    return [pscustomobject]$result
}
if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    $result.Status  = 'Skipped'
    $result.Message = 'az CLI not installed. Required to populate AKS kubeconfig context.'
    return [pscustomobject]$result
}

# --- Discover AKS clusters via ARG (unless explicit list provided) ---
$clusters = @()
if ($ClusterArmIds -and $ClusterArmIds.Count -gt 0) {
    foreach ($id in $ClusterArmIds) {
        $rg    = if ($id -match '/resourceGroups/([^/]+)') { $Matches[1] } else { '' }
        $name  = Split-Path $id -Leaf
        $clusters += [pscustomobject]@{ id = $id; resourceGroup = $rg; name = $name }
    }
} else {
    if (-not (Get-Module -ListAvailable -Name Az.ResourceGraph)) {
        $result.Status  = 'Skipped'
        $result.Message = 'Az.ResourceGraph module not installed; cannot discover AKS clusters.'
        return [pscustomobject]$result
    }
    Import-Module Az.ResourceGraph -ErrorAction SilentlyContinue
    try {
        $query = "Resources | where type =~ 'Microsoft.ContainerService/managedClusters' | where subscriptionId == '$SubscriptionId' | project id, name, resourceGroup"
        $argResp = Invoke-WithRetry -MaxAttempts 3 -ScriptBlock {
            Search-AzGraph -Query $using:query -First 200 -ErrorAction Stop
        }
        $clusters = @($argResp)
    } catch {
        $result.Status  = 'Failed'
        $result.Message = "ARG discovery failed: $(Remove-Credentials $_.Exception.Message)"
        return [pscustomobject]$result
    }
}

if (-not $clusters -or @($clusters).Count -eq 0) {
    $result.Status  = 'Skipped'
    $result.Message = 'No AKS managed clusters in scope.'
    return [pscustomobject]$result
}

$findings = [System.Collections.Generic.List[object]]::new()
$scanned  = 0
$failed   = 0

if ($OutputPath -and -not (Test-Path $OutputPath)) {
    try { New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null } catch {}
}

foreach ($cluster in $clusters) {
    $context = "ks-$($cluster.name)-$([guid]::NewGuid().ToString('N').Substring(0,8))"
    try {
        # Isolated kubeconfig context per cluster — avoid cross-cluster pollution.
        $tmpKubeconfig = Join-Path ([System.IO.Path]::GetTempPath()) "kubeconfig-$context.yaml"
        $azArgs = @('aks', 'get-credentials',
                    '--subscription', $SubscriptionId,
                    '--resource-group', $cluster.resourceGroup,
                    '--name', $cluster.name,
                    '--file', $tmpKubeconfig,
                    '--context', $context,
                    '--overwrite-existing',
                    '--only-show-errors')
        & az @azArgs 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) {
            $failed++
            continue
        }

        $rawFile = if ($OutputPath) {
            Join-Path $OutputPath "kubescape-$($cluster.name)-$(Get-Date -Format yyyyMMddHHmmss).json"
        } else {
            Join-Path ([System.IO.Path]::GetTempPath()) "kubescape-$context.json"
        }

        $env:KUBECONFIG = $tmpKubeconfig
        & kubescape scan --kube-context $context --format json --output $rawFile --format-version v2 2>&1 | Out-Null
        $scanExit = $LASTEXITCODE

        if ((Test-Path $rawFile) -and ((Get-Item $rawFile).Length -gt 0)) {
            $raw = Get-Content $rawFile -Raw | ConvertFrom-Json -Depth 30
            if ($raw.summaryDetails -and $raw.summaryDetails.controls) {
                $controls = $raw.summaryDetails.controls
                foreach ($ctrlProp in $controls.PSObject.Properties) {
                    $c = $ctrlProp.Value
                    $status = ''
                    try { $status = [string]$c.status.status } catch {}
                    if ($status -eq 'passed' -or $status -eq 'skipped') { continue }
                    $sev = 'Medium'
                    try { $sev = switch ([int]$c.scoreFactor) {
                        { $_ -ge 9 } { 'Critical' }
                        { $_ -ge 7 } { 'High' }
                        { $_ -ge 4 } { 'Medium' }
                        default      { 'Low' }
                    } } catch {}
                    $ctrlId = $ctrlProp.Name
                    $ctrlName = ''
                    try { $ctrlName = [string]$c.name } catch {}
                    $findings.Add([pscustomobject]@{
                        Id           = "kubescape/$($cluster.id)/$ctrlId"
                        Source       = 'kubescape'
                        Category     = 'KubernetesPosture'
                        Severity     = $sev
                        Compliant    = $false
                        Title        = "${ctrlId}: $ctrlName"
                        Detail       = "kubescape control failed on AKS cluster $($cluster.name). status=$status"
                        Remediation  = "Review kubescape raw output for control $ctrlId and follow CIS K8s Benchmark guidance."
                        ResourceId   = $cluster.id
                        ControlId    = $ctrlId
                        LearnMoreUrl = "https://hub.armosec.io/docs/$($ctrlId.ToLower())"
                    }) | Out-Null
                }
            }
            $scanned++
        } else {
            $failed++
        }
    } catch {
        $failed++
        Write-Warning "kubescape scan failed for cluster $($cluster.name): $(Remove-Credentials $_.Exception.Message)"
    } finally {
        # Remove the isolated kubeconfig to avoid leaking cluster auth.
        if ($tmpKubeconfig -and (Test-Path $tmpKubeconfig)) {
            try { Remove-Item $tmpKubeconfig -Force -ErrorAction SilentlyContinue } catch {}
        }
        if ($env:KUBECONFIG) { Remove-Item Env:\KUBECONFIG -ErrorAction SilentlyContinue }
    }
}

$result.Findings = @($findings)
$result.Message  = "Scanned $scanned AKS cluster(s); $failed failed; emitted $($findings.Count) non-passing control findings."
if ($scanned -eq 0 -and $failed -gt 0) {
    $result.Status = 'Failed'
}

return [pscustomobject]$result
