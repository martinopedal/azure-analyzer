#requires -Version 7.0
<#
.SYNOPSIS
    Wrapper for Falco runtime anomaly detection on AKS.

.DESCRIPTION
    Default mode is non-intrusive query mode: reads Falco-related alerts from Microsoft Security
    alerts already present in Azure (for example Defender alert pipeline).

    Optional install mode (-InstallFalco) is explicit opt-in: installs Falco via Helm into each
    AKS cluster in scope, waits briefly, collects daemonset logs, and optionally uninstalls.

.PARAMETER SubscriptionId
    Azure subscription ID (GUID). Required.

.PARAMETER ClusterArmIds
    Optional explicit AKS cluster ARM IDs to limit scope.

.PARAMETER InstallFalco
    Opt-in install mode. When omitted, query mode is used.

.PARAMETER UninstallFalco
    In install mode, uninstall the Falco Helm release after collection.
#>
[CmdletBinding()]
param (
    [Parameter(Mandatory)] [string] $SubscriptionId,
    [string[]] $ClusterArmIds,
    [switch] $InstallFalco,
    [switch] $UninstallFalco
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
    Source        = 'falco'
    Status        = 'Success'
    Message       = ''
    Findings      = @()
    Subscription  = $SubscriptionId
    Timestamp     = (Get-Date).ToUniversalTime().ToString('o')
}

if (-not (Get-Module -ListAvailable -Name Az.ResourceGraph)) {
    $result.Status  = 'Skipped'
    $result.Message = 'Az.ResourceGraph module not installed; cannot discover AKS clusters or query alerts.'
    return [pscustomobject]$result
}
Import-Module Az.ResourceGraph -ErrorAction SilentlyContinue

try {
    $null = Get-AzContext -ErrorAction Stop
} catch {
    $result.Status  = 'Skipped'
    $result.Message = 'Not signed in. Run Connect-AzAccount first.'
    return [pscustomobject]$result
}

$clusters = @()
if ($ClusterArmIds -and $ClusterArmIds.Count -gt 0) {
    foreach ($id in $ClusterArmIds) {
        $rg   = if ($id -match '/resourceGroups/([^/]+)') { $Matches[1] } else { '' }
        $name = Split-Path $id -Leaf
        $clusters += [pscustomobject]@{ id = $id; resourceGroup = $rg; name = $name }
    }
} else {
    try {
        $query = "Resources | where type =~ 'Microsoft.ContainerService/managedClusters' | where subscriptionId == '$SubscriptionId' | project id, name, resourceGroup"
        $argResp = Invoke-WithRetry -MaxAttempts 3 -ScriptBlock {
            Search-AzGraph -Query $using:query -First 200 -ErrorAction Stop
        }
        $clusters = @($argResp)
    } catch {
        $result.Status  = 'Failed'
        $result.Message = "AKS discovery failed: $($_.Exception.Message)"
        return [pscustomobject]$result
    }
}

if (-not $clusters -or @($clusters).Count -eq 0) {
    $result.Status  = 'Skipped'
    $result.Message = 'No AKS managed clusters in scope.'
    return [pscustomobject]$result
}

$clusterById = @{}
foreach ($c in $clusters) {
    if ($c.id) { $clusterById[[string]$c.id.ToLowerInvariant()] = $c }
}

function Get-MatchValue {
    param([string]$Text, [string]$Pattern)
    if (-not $Text) { return '' }
    if ($Text -match $Pattern) { return [string]$Matches[1] }
    return ''
}

function Resolve-AksResourceId {
    param([pscustomobject]$Alert, [hashtable]$ClusterMap)
    $candidates = [System.Collections.Generic.List[string]]::new()
    foreach ($p in @('resourceId', 'resourceID', 'ResourceId', 'CompromisedEntity')) {
        if ($Alert.PSObject.Properties[$p] -and $Alert.$p) { $candidates.Add([string]$Alert.$p) }
    }
    if ($Alert.PSObject.Properties['ExtendedProperties'] -and $Alert.ExtendedProperties) {
        $candidates.Add([string]$Alert.ExtendedProperties)
    }
    foreach ($raw in $candidates) {
        if (-not $raw) { continue }
        if ($raw -match '(?i)(/subscriptions/[^/\s]+/resourcegroups/[^/\s]+/providers/microsoft\.containerservice/managedclusters/[^/\s"''\\]+)') {
            $id = $Matches[1].ToLowerInvariant()
            if ($ClusterMap.ContainsKey($id)) { return $id }
        }
    }
    return ''
}

function Convert-PriorityToSeverity {
    param([string]$Priority)
    switch -Regex (($Priority ?? '').Trim()) {
        '^(?i)critical$' { return 'Critical' }
        '^(?i)error$'    { return 'High' }
        '^(?i)warning$'  { return 'Medium' }
        '^(?i)notice$'   { return 'Low' }
        default          { return 'Info' }
    }
}

$findings = [System.Collections.Generic.List[object]]::new()

if (-not $InstallFalco) {
    try {
        $alertsQuery = @"
Resources
| where type =~ 'Microsoft.Security/locations/alerts'
| where subscriptionId == '$SubscriptionId'
| extend alertName = tostring(properties.alertDisplayName),
         description = tostring(properties.description),
         severity = tostring(properties.severity),
         compromisedEntity = tostring(properties.compromisedEntity),
         resourceId = tostring(properties.resourceIdentifiers[0].azureResourceId),
         extendedProperties = tostring(properties.extendedProperties)
| where tolower(alertName) has 'falco' or tolower(description) has 'falco' or tolower(extendedProperties) has 'falco'
| project id, alertName, description, severity, compromisedEntity, resourceId, extendedProperties
"@
        $alerts = @(Invoke-WithRetry -MaxAttempts 3 -ScriptBlock {
            Search-AzGraph -Query $using:alertsQuery -First 1000 -ErrorAction Stop
        })
    } catch {
        $result.Status  = 'Failed'
        $result.Message = "Falco query mode failed: $($_.Exception.Message)"
        return [pscustomobject]$result
    }

    foreach ($a in $alerts) {
        $rid = Resolve-AksResourceId -Alert $a -ClusterMap $clusterById
        if (-not $rid) { continue }

        $priority = Get-MatchValue -Text ([string]$a.extendedProperties) -Pattern '(?i)"(?:priority|Priority)"\s*:\s*"([^"]+)"'
        if (-not $priority) { $priority = [string]$a.severity }
        if (-not $priority) { $priority = 'Notice' }
        $rule = Get-MatchValue -Text ([string]$a.extendedProperties) -Pattern '(?i)"(?:rule|Rule)"\s*:\s*"([^"]+)"'
        $pod = Get-MatchValue -Text ([string]$a.extendedProperties) -Pattern '(?i)"(?:pod|Pod|k8s\.pod\.name)"\s*:\s*"([^"]+)"'
        $proc = Get-MatchValue -Text ([string]$a.extendedProperties) -Pattern '(?i)"(?:proc|process|Process|proc\.name)"\s*:\s*"([^"]+)"'

        $sev = Convert-PriorityToSeverity -Priority $priority
        $ruleDisplay = if ($rule) { $rule } else { [string]$a.alertName }
        if (-not $ruleDisplay) { $ruleDisplay = 'Falco runtime alert' }

        $findings.Add([pscustomobject]@{
            Id          = if ($a.id) { "falco/$($a.id)" } else { "falco/$([guid]::NewGuid())" }
            Source      = 'falco'
            Category    = 'KubernetesRuntimeThreatDetection'
            Severity    = $sev
            Priority    = $priority
            Compliant   = $false
            Title       = "Falco: $ruleDisplay"
            Detail      = [string]$a.description
            Remediation = 'Investigate Falco runtime behavior and validate if process/pod activity is expected.'
            ResourceId  = $rid
            RuleName    = $rule
            Pod         = $pod
            Process     = $proc
            LearnMoreUrl = 'https://falco.org/docs/'
        }) | Out-Null
    }

    $result.Findings = @($findings)
    $result.Message = "Query mode: processed $($alerts.Count) Falco-related alert(s); emitted $($findings.Count) AKS finding(s)."
    return [pscustomobject]$result
}

if (-not (Get-Command helm -ErrorAction SilentlyContinue)) {
    $result.Status = 'Skipped'
    $result.Message = 'Install mode requested but helm is not installed.'
    return [pscustomobject]$result
}
if (-not (Get-Command kubectl -ErrorAction SilentlyContinue)) {
    $result.Status = 'Skipped'
    $result.Message = 'Install mode requested but kubectl is not installed.'
    return [pscustomobject]$result
}
if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    $result.Status = 'Skipped'
    $result.Message = 'Install mode requested but az CLI is not installed.'
    return [pscustomobject]$result
}

$captureMinutes = 5
$scanned = 0
$failed = 0
foreach ($cluster in $clusters) {
    $ctx = "falco-$($cluster.name)-$([guid]::NewGuid().ToString('N').Substring(0,8))"
    $tmpKubeconfig = Join-Path ([System.IO.Path]::GetTempPath()) "kubeconfig-$ctx.yaml"
    try {
        & az aks get-credentials --subscription $SubscriptionId --resource-group $cluster.resourceGroup --name $cluster.name --file $tmpKubeconfig --context $ctx --overwrite-existing --only-show-errors 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { $failed++; continue }

        $env:KUBECONFIG = $tmpKubeconfig
        & helm repo add falcosecurity https://falcosecurity.github.io/charts 2>&1 | Out-Null
        & helm repo update 2>&1 | Out-Null
        & helm upgrade --install falco falcosecurity/falco --namespace falco --create-namespace --wait --timeout 5m 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { $failed++; continue }

        Start-Sleep -Seconds ($captureMinutes * 60)
        $rawLogs = & kubectl --context $ctx -n falco logs daemonset/falco --since "$($captureMinutes)m" --tail 5000 2>$null
        foreach ($line in @($rawLogs)) {
            if (-not $line) { continue }
            $priority = Get-MatchValue -Text $line -Pattern '(?i)"priority"\s*:\s*"([^"]+)"'
            if (-not $priority) { continue }
            $rule = Get-MatchValue -Text $line -Pattern '(?i)"rule"\s*:\s*"([^"]+)"'
            $pod = Get-MatchValue -Text $line -Pattern '(?i)"k8s\.pod\.name"\s*:\s*"([^"]+)"'
            $proc = Get-MatchValue -Text $line -Pattern '(?i)"proc\.name"\s*:\s*"([^"]+)"'
            $sev = Convert-PriorityToSeverity -Priority $priority

            $findings.Add([pscustomobject]@{
                Id          = "falco/$($cluster.id)/$([guid]::NewGuid())"
                Source      = 'falco'
                Category    = 'KubernetesRuntimeThreatDetection'
                Severity    = $sev
                Priority    = $priority
                Compliant   = $false
                Title       = if ($rule) { "Falco: $rule" } else { 'Falco runtime alert' }
                Detail      = [string]$line
                Remediation = 'Investigate Falco runtime behavior and validate if process/pod activity is expected.'
                ResourceId  = [string]$cluster.id
                RuleName    = $rule
                Pod         = $pod
                Process     = $proc
                LearnMoreUrl = 'https://falco.org/docs/'
            }) | Out-Null
        }

        if ($UninstallFalco) {
            & helm uninstall falco -n falco 2>&1 | Out-Null
        }
        $scanned++
    } catch {
        $failed++
        Write-Warning "Falco install mode failed for cluster $($cluster.name): $($_.Exception.Message)"
    } finally {
        if ($env:KUBECONFIG) { Remove-Item Env:\KUBECONFIG -ErrorAction SilentlyContinue }
        if (Test-Path $tmpKubeconfig) {
            try { Remove-Item $tmpKubeconfig -Force -ErrorAction SilentlyContinue } catch {}
        }
    }
}

$result.Findings = @($findings)
$result.Message  = "Install mode: scanned $scanned AKS cluster(s); $failed failed; emitted $($findings.Count) Falco alert finding(s)."
if ($scanned -eq 0 -and $failed -gt 0) {
    $result.Status = 'Failed'
}

return [pscustomobject]$result
