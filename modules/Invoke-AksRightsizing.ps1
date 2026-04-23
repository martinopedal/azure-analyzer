#Requires -Version 7.4
<#
.SYNOPSIS
    AKS rightsizing signals from Container Insights (Log Analytics KQL).
.DESCRIPTION
    Discovers AKS clusters in the requested scope, resolves each cluster's
    Container Insights workspace, and executes KQL checks for:
      - over-provisioned pods (CPU and memory)
      - under-provisioned pods (CPU and memory)
      - missing HPA candidates (static replicas with variability)
      - OOMKilled pods
#>
[CmdletBinding()]
param (
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string] $SubscriptionId,

    [string] $ResourceGroup,
    [string] $ClusterName,
    [string] $LogAnalyticsWorkspaceId,

    [ValidateRange(1, 30)]
    [int] $LookbackDays = 7,

    [string] $OutputPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$retryPath = Join-Path $PSScriptRoot 'shared' 'Retry.ps1'
if (Test-Path $retryPath) { . $retryPath }
if (-not (Get-Command Invoke-WithRetry -ErrorAction SilentlyContinue)) {
    function Invoke-WithRetry { param([scriptblock]$ScriptBlock) & $ScriptBlock }
}

$sanitizePath = Join-Path $PSScriptRoot 'shared' 'Sanitize.ps1'
if (Test-Path $sanitizePath) { . $sanitizePath }
if (-not (Get-Command Remove-Credentials -ErrorAction SilentlyContinue)) {
    function Remove-Credentials { param([string]$Text) return $Text }
}

$errorsPath = Join-Path $PSScriptRoot 'shared' 'Errors.ps1'
if (Test-Path $errorsPath) { . $errorsPath }
if (-not (Get-Command New-FindingError -ErrorAction SilentlyContinue)) {
    function New-FindingError { param([string]$Source,[string]$Category,[string]$Reason,[string]$Remediation,[string]$Details) return [pscustomobject]@{ Source=$Source; Category=$Category; Reason=$Reason; Remediation=$Remediation; Details=$Details } }
}
if (-not (Get-Command Format-FindingErrorMessage -ErrorAction SilentlyContinue)) {
    function Format-FindingErrorMessage {
        param([Parameter(Mandatory)]$FindingError)
        $line = "[{0}] {1}: {2}" -f $FindingError.Source, $FindingError.Category, $FindingError.Reason
        if ($FindingError.Remediation) { $line += " Action: $($FindingError.Remediation)" }
        return $line
    }
}

$installerPath = Join-Path $PSScriptRoot 'shared' 'Installer.ps1'
if (Test-Path $installerPath) { . $installerPath }
if (-not (Get-Command Invoke-WithTimeout -ErrorAction SilentlyContinue)) {
    function Invoke-WithTimeout {
        param (
            [Parameter(Mandatory)][string]$Command,
            [Parameter(Mandatory)][string[]]$Arguments,
            [int]$TimeoutSec = 300
        )
        $output = & $Command @Arguments 2>&1 | Out-String
        return [PSCustomObject]@{ ExitCode = $LASTEXITCODE; Output = $output.Trim() }
    }
}

$aksDiscoveryPath = Join-Path $PSScriptRoot 'shared' 'AksDiscovery.ps1'
if (-not (Get-Command Get-AksClustersInScope -ErrorAction SilentlyContinue) -and (Test-Path $aksDiscoveryPath)) { . $aksDiscoveryPath }

$kqlPath = Join-Path $PSScriptRoot 'shared' 'KqlQuery.ps1'
if (-not (Get-Command Invoke-LogAnalyticsQuery -ErrorAction SilentlyContinue) -and (Test-Path $kqlPath)) { . $kqlPath }

$result = [ordered]@{
    SchemaVersion = '1.0'
    Source        = 'aks-rightsizing'
    Status        = 'Success'
    Message       = ''
    Findings      = @()
    Subscription  = $SubscriptionId
    Timestamp     = (Get-Date).ToUniversalTime().ToString('o')
}

if (-not (Get-Module -ListAvailable -Name Az.Accounts)) {
    $result.Status  = 'Skipped'
    $result.Message = 'Az.Accounts module not installed. Run: Install-Module Az.Accounts -Scope CurrentUser'
    return [PSCustomObject]$result
}

if (-not (Get-Module -ListAvailable -Name Az.OperationalInsights)) {
    $result.Status  = 'Skipped'
    $result.Message = 'Az.OperationalInsights module not installed. Run: Install-Module Az.OperationalInsights -Scope CurrentUser'
    return [PSCustomObject]$result
}

try {
    Import-Module Az.Accounts -ErrorAction SilentlyContinue -WarningAction SilentlyContinue
    $null = Get-AzContext -ErrorAction Stop
} catch {
    Write-Verbose "Az context probe failed; continuing and letting downstream calls report concrete auth errors."
}

function Resolve-WorkspaceIdFromCluster {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [pscustomobject] $Cluster
    )

    if ($Cluster.PSObject.Properties['workspaceResourceId'] -and $Cluster.workspaceResourceId) {
        return [string]$Cluster.workspaceResourceId
    }

    $clusterId = [string]$Cluster.id
    if ([string]::IsNullOrWhiteSpace($clusterId)) { return '' }

    $diagUri = "https://management.azure.com$clusterId/providers/Microsoft.Insights/diagnosticSettings?api-version=2021-05-01-preview"
    try {
        $resp = Invoke-WithRetry -MaxAttempts 3 -InitialDelaySeconds 2 -MaxDelaySeconds 20 -ScriptBlock {
            Invoke-AzRestMethod -Method GET -Uri $using:diagUri -ErrorAction Stop
        }
        if (-not $resp -or $resp.StatusCode -ge 400 -or -not $resp.Content) { return '' }
        $payload = $resp.Content | ConvertFrom-Json -Depth 20
        $entries = if ($payload.PSObject.Properties['value']) { @($payload.value) } else { @() }
        foreach ($entry in $entries) {
            if ($entry.PSObject.Properties['properties'] -and $entry.properties.workspaceId) {
                return [string]$entry.properties.workspaceId
            }
        }
    } catch {
        Write-Verbose ("Diagnostic settings lookup failed for {0}: {1}" -f $Cluster.name, (Remove-Credentials -Text ([string]$_.Exception.Message)))
    }

    return ''
}

function Get-WorkspaceNameFromArmId {
    param([string]$WorkspaceArmId)
    if (-not $WorkspaceArmId) { return '' }
    if ($WorkspaceArmId -match '/workspaces/([^/]+)$') { return [string]$Matches[1] }
    return ''
}

function Get-ClusterInsightsUrl {
    param([string]$ClusterId)
    if (-not $ClusterId) { return '' }
    return "https://portal.azure.com/#@/resource$ClusterId/insights"
}

function Get-AksWorkloadDeepLinkUrl {
    param(
        [string]$ClusterId,
        [string]$Namespace,
        [string]$WorkloadName
    )

    if (-not $ClusterId) { return '' }
    $encodedClusterId = [System.Uri]::EscapeDataString($ClusterId)
    $encodedNamespace = [System.Uri]::EscapeDataString(($Namespace ?? '').Trim())
    $encodedWorkload = [System.Uri]::EscapeDataString(($WorkloadName ?? '').Trim())
    return "https://portal.azure.com/#blade/Microsoft_Azure_Monitoring/AzureMonitoringBrowseBlade/overview/resourceId/$encodedClusterId/namespace/$encodedNamespace/workload/$encodedWorkload"
}

function Get-AksQueryEvidenceUri {
    param(
        [string]$WorkspaceId,
        [string]$QueryName,
        [string]$QueryText
    )

    if (-not $WorkspaceId -or -not $QueryText) { return '' }
    $encodedWorkspace = [System.Uri]::EscapeDataString($WorkspaceId)
    $encodedQuery = [System.Uri]::EscapeDataString($QueryText)
    $encodedName = [System.Uri]::EscapeDataString(($QueryName ?? 'aks-rightsizing'))
    return "https://portal.azure.com/#blade/Microsoft_Azure_Monitoring/LogsBlade/resourceId/$encodedWorkspace/source/LogsBlade/query/$encodedQuery/queryTimeRange/P7D/queryDisplayName/$encodedName"
}

function Resolve-RightsizingPillar {
    param([string]$Category)
    switch -Regex (($Category ?? '').ToLowerInvariant()) {
        'overprovisioned|idle' { return 'Cost Optimization' }
        'underprovisioned|oomkilled|missinghpa' { return 'Performance Efficiency' }
        default { return 'Performance Efficiency' }
    }
}

function Get-RightsizingSignalPercent {
    param(
        [string]$Category,
        [double]$ObservedPercent
    )

    if (($Category ?? '') -match '(?i)overprovisioned|idle') {
        return [math]::Round([math]::Max(0, (100.0 - $ObservedPercent)), 2)
    }
    return [math]::Round([math]::Max(0, $ObservedPercent), 2)
}

function Resolve-RightsizingImpact {
    param(
        [string]$Category,
        [double]$ObservedPercent
    )

    $signal = Get-RightsizingSignalPercent -Category $Category -ObservedPercent $ObservedPercent
    if (($Category ?? '') -match '(?i)overprovisioned|idle') {
        if ($signal -ge 80) { return 'High' }
        if ($signal -ge 50) { return 'Medium' }
        return 'Low'
    }
    if ($signal -ge 90) { return 'High' }
    if ($signal -ge 50) { return 'Medium' }
    return 'Low'
}

function Resolve-RightsizingEffort {
    param([string]$Category)
    switch -Regex (($Category ?? '').ToLowerInvariant()) {
        'missinghpa' { return 'Medium' }
        'oomkilled' { return 'High' }
        default { return 'Low' }
    }
}

function Resolve-RightsizingBaselineTags {
    param(
        [string]$Category,
        [string]$MetricType
    )

    $tags = [System.Collections.Generic.List[string]]::new()
    $normalizedCategory = ($Category ?? '').Trim()
    $metric = ($MetricType ?? '').Trim()
    switch -Regex ($normalizedCategory.ToLowerInvariant()) {
        'overprovisionedcpu|underprovisionedcpu' { $tags.Add('AKS-RightSizing-CPU') | Out-Null }
        'overprovisionedmemory|underprovisionedmemory' { $tags.Add('AKS-RightSizing-Memory') | Out-Null }
        'missinghpa' { $tags.Add('AKS-MissingHPA') | Out-Null }
        'oomkilled' { $tags.Add('AKS-OOMKilled') | Out-Null }
    }
    if (-not [string]::IsNullOrWhiteSpace($normalizedCategory)) { $tags.Add("AKS-$normalizedCategory") | Out-Null }
    if (-not [string]::IsNullOrWhiteSpace($metric)) { $tags.Add("AKS-RightSizing-$($metric.ToUpperInvariant())") | Out-Null }
    return @($tags | Select-Object -Unique)
}

function New-RightsizingRemediationSnippets {
    param(
        [string]$Category,
        [string]$Namespace,
        [string]$WorkloadName,
        [string]$MetricType,
        [double]$RecommendedMillicores,
        [double]$RecommendedMemoryMiB
    )

    $ns = if ([string]::IsNullOrWhiteSpace($Namespace)) { 'default' } else { $Namespace.Trim() }
    $workload = if ([string]::IsNullOrWhiteSpace($WorkloadName)) { 'workload-name' } else { $WorkloadName.Trim() }
    $yaml = ''
    switch -Regex (($Category ?? '').ToLowerInvariant()) {
        'missinghpa' {
            $yaml = @"
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: $workload
  namespace: $ns
spec:
  minReplicas: 2
  maxReplicas: 10
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: $workload
"@
        }
        'overprovisionedcpu|underprovisionedcpu' {
            $targetCpu = if ($RecommendedMillicores -gt 0) { [math]::Round($RecommendedMillicores, 0) } else { 250 }
            $yaml = @"
kubectl patch deployment $workload -n $ns --type merge -p:
  spec:
    template:
      spec:
        containers:
          - name: app
            resources:
              requests:
                cpu: "${targetCpu}m"
              limits:
                cpu: "${targetCpu}m"
"@
        }
        default {
            $targetMemory = if ($RecommendedMemoryMiB -gt 0) { [math]::Round($RecommendedMemoryMiB, 0) } else { 512 }
            $yaml = @"
resources:
  requests:
    memory: "${targetMemory}Mi"
  limits:
    memory: "${targetMemory}Mi"
"@
        }
    }

    if ([string]::IsNullOrWhiteSpace($yaml)) { return @() }
    return @(@{ language = 'yaml'; content = $yaml.Trim() })
}

function Get-KubectlVersionText {
    try {
        $versionResult = Invoke-WithTimeout -Command 'kubectl' -Arguments @('version', '--client', '--output=json') -TimeoutSec 300
        if ($versionResult.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($versionResult.Output)) { return '' }
        $payload = $versionResult.Output | ConvertFrom-Json -ErrorAction SilentlyContinue
        if ($payload -and $payload.clientVersion -and $payload.clientVersion.gitVersion) {
            return [string]$payload.clientVersion.gitVersion
        }
        return ''
    } catch {
        return ''
    }
}

function Get-AzAksModuleVersionText {
    try {
        $module = Get-Module -ListAvailable -Name Az.Aks | Sort-Object Version -Descending | Select-Object -First 1
        if ($module -and $module.Version) { return $module.Version.ToString() }
    } catch {
    }
    return ''
}

function Get-AksRightsizingToolVersion {
    $kubectlVersion = Get-KubectlVersionText
    $azAksVersion = Get-AzAksModuleVersionText
    if ($kubectlVersion -and $azAksVersion) { return "kubectl:$kubectlVersion; Az.Aks:$azAksVersion" }
    if ($kubectlVersion) { return "kubectl:$kubectlVersion" }
    if ($azAksVersion) { return "Az.Aks:$azAksVersion" }
    return ''
}

function Add-RightsizingFinding {
    param (
        [Parameter(Mandatory)][pscustomobject] $Cluster,
        [Parameter(Mandatory)][string] $Category,
        [Parameter(Mandatory)][string] $Severity,
        [Parameter(Mandatory)][string] $Title,
        [Parameter(Mandatory)][string] $Detail,
        [Parameter(Mandatory)][string] $Remediation,
        [Parameter(Mandatory)][bool] $Compliant,
        [string] $Namespace = '',
        [string] $WorkloadName = '',
        [string] $ContainerName = '',
        [string] $MetricType = '',
        [double] $ObservedPercent = 0,
        [double] $RecommendedMillicores = 0,
        [double] $RecommendedMemoryMiB = 0,
        [string] $WorkspaceId = '',
        [string] $QueryName = '',
        [string] $QueryText = '',
        [string] $ToolVersion = ''
    )

    $clusterId = [string]$Cluster.id
    $deepLinkUrl = Get-AksWorkloadDeepLinkUrl -ClusterId $clusterId -Namespace $Namespace -WorkloadName $WorkloadName
    $workloadInsightsUrl = Get-ClusterInsightsUrl -ClusterId $clusterId
    $queryEvidenceUrl = Get-AksQueryEvidenceUri -WorkspaceId $WorkspaceId -QueryName $QueryName -QueryText $QueryText
    $evidenceUris = [System.Collections.Generic.List[string]]::new()
    if (-not [string]::IsNullOrWhiteSpace($queryEvidenceUrl)) { $evidenceUris.Add($queryEvidenceUrl) | Out-Null }
    if (-not [string]::IsNullOrWhiteSpace($workloadInsightsUrl)) { $evidenceUris.Add($workloadInsightsUrl) | Out-Null }
    $baselineTags = @(Resolve-RightsizingBaselineTags -Category $Category -MetricType $MetricType)
    $scoreDelta = Get-RightsizingSignalPercent -Category $Category -ObservedPercent $ObservedPercent
    $entityRefs = @($clusterId, "namespace:$Namespace", "workload:$WorkloadName")
    $remediationSnippets = @(New-RightsizingRemediationSnippets -Category $Category -Namespace $Namespace -WorkloadName $WorkloadName -MetricType $MetricType -RecommendedMillicores $RecommendedMillicores -RecommendedMemoryMiB $RecommendedMemoryMiB)
    $findingId = "aks-rightsizing/$Category/$($cluster.name)/$([guid]::NewGuid().ToString('N'))"
    $finding = [ordered]@{
        Id                   = $findingId
        Source               = 'aks-rightsizing'
        Category             = 'Performance'
        Severity             = $Severity
        Compliant            = $Compliant
        Title                = $Title
        Detail               = $Detail
        Remediation          = $Remediation
        ResourceId           = $clusterId
        LearnMoreUrl         = (Get-ClusterInsightsUrl -ClusterId $clusterId)
        Pillar               = Resolve-RightsizingPillar -Category $Category
        Impact               = Resolve-RightsizingImpact -Category $Category -ObservedPercent $ObservedPercent
        Effort               = Resolve-RightsizingEffort -Category $Category
        DeepLinkUrl          = $deepLinkUrl
        RemediationSnippets  = $remediationSnippets
        EvidenceUris         = @($evidenceUris)
        BaselineTags         = @($baselineTags)
        ScoreDelta           = $scoreDelta
        EntityRefs           = @($entityRefs)
        ToolVersion          = $ToolVersion
        FindingCategory      = $Category
        ClusterName          = [string]$Cluster.name
        ClusterResourceGroup = [string]$Cluster.resourceGroup
        Namespace            = $Namespace
        WorkloadName         = $WorkloadName
        ContainerName        = $ContainerName
        MetricType           = $MetricType
        ObservedPercent      = [math]::Round($ObservedPercent, 2)
        RecommendedMillicores = [math]::Round($RecommendedMillicores, 2)
        RecommendedMemoryMiB = [math]::Round($RecommendedMemoryMiB, 2)
    }
    $script:findings.Add([PSCustomObject]$finding) | Out-Null
}

function Invoke-RightsizingKql {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $WorkspaceId,
        [Parameter(Mandatory)][string] $QueryName,
        [Parameter(Mandatory)][string] $QueryText
    )

    try {
        $ping = Invoke-WithTimeout -Command 'pwsh' -Arguments @('-NoProfile', '-NonInteractive', '-Command', 'exit 0') -TimeoutSec 300
        if ($ping.ExitCode -ne 0) {
            throw (Format-FindingErrorMessage (New-FindingError -Source 'wrapper:aks-rightsizing' -Category 'TimeoutExceeded' -Reason "Invoke-WithTimeout preflight failed for ${QueryName} (exit code $($ping.ExitCode))." -Remediation 'Verify pwsh can run non-interactive commands and that timeout helpers are functioning.' -Details ([string]$ping.Output)))
        }
    } catch {
        throw (Format-FindingErrorMessage (New-FindingError -Source 'wrapper:aks-rightsizing' -Category 'UnexpectedFailure' -Reason "Invoke-WithTimeout preflight failed for ${QueryName}." -Remediation 'Verify shared Installer.ps1 timeout helper availability and retry the rightsizing query.' -Details ([string]$_.Exception.Message)))
    }

    return Invoke-LogAnalyticsQuery -WorkspaceId $WorkspaceId -Query $QueryText -TimeoutSeconds 300
}

try {
    $clusters = @(Get-AksClustersInScope -SubscriptionId $SubscriptionId -ResourceGroup $ResourceGroup -ClusterName $ClusterName)
} catch {
    $result.Status  = 'Failed'
    $result.Message = "AKS discovery failed: $(Remove-Credentials -Text ([string]$_.Exception.Message))"
    return [PSCustomObject]$result
}

if (-not $clusters -or $clusters.Count -eq 0) {
    $result.Status  = 'Skipped'
    $result.Message = 'No AKS managed clusters in scope.'
    return [PSCustomObject]$result
}

$findings = [System.Collections.Generic.List[object]]::new()
$workspaceErrors = [System.Collections.Generic.List[string]]::new()
$clusterCount = 0
$toolVersion = Get-AksRightsizingToolVersion

foreach ($cluster in $clusters) {
    $clusterCount++
    $workspaceId = if ($LogAnalyticsWorkspaceId) { $LogAnalyticsWorkspaceId } else { Resolve-WorkspaceIdFromCluster -Cluster $cluster }
    if ([string]::IsNullOrWhiteSpace($workspaceId)) {
        $workspaceErrors.Add("Cluster $($cluster.name): Container Insights workspace not found.") | Out-Null
        continue
    }

    $workspaceName = Get-WorkspaceNameFromArmId -WorkspaceArmId $workspaceId
    $timeFilter = "ago(${LookbackDays}d)"

    $overCpuQuery = @"
let lookback = $timeFilter;
KubePodInventory
| where TimeGenerated >= lookback
| where ClusterName =~ '$($cluster.name)'
| where isnotempty(ContainerName)
| summarize cpuLimitNano = max(todouble(ContainerCpuLimitNanoCores)) by Namespace, Name, ContainerName
| join kind=inner (
    Perf
    | where TimeGenerated >= lookback
    | where ObjectName == 'K8SContainer'
    | where CounterName == 'cpuUsageNanoCores'
    | summarize p95_cpu = percentile(CounterValue, 95), avg_cpu = avg(CounterValue) by Namespace = InstanceName, ContainerName
) on Namespace, ContainerName
| where cpuLimitNano > 0 and p95_cpu < cpuLimitNano * 0.2
| project Namespace, WorkloadName = Name, ContainerName, p95_cpu, avg_cpu, cpuLimitNano, observedPct = (p95_cpu / cpuLimitNano) * 100.0, recommendedMillicores = round((p95_cpu * 1.25) / 1000000.0, 2)
"@

    $underCpuQuery = @"
let lookback = $timeFilter;
KubePodInventory
| where TimeGenerated >= lookback
| where ClusterName =~ '$($cluster.name)'
| where isnotempty(ContainerName)
| summarize cpuLimitNano = max(todouble(ContainerCpuLimitNanoCores)) by Namespace, Name, ContainerName
| join kind=inner (
    Perf
    | where TimeGenerated >= lookback
    | where ObjectName == 'K8SContainer'
    | where CounterName == 'cpuUsageNanoCores'
    | summarize p95_cpu = percentile(CounterValue, 95) by Namespace = InstanceName, ContainerName
) on Namespace, ContainerName
| where cpuLimitNano > 0 and p95_cpu >= cpuLimitNano * 0.95
| project Namespace, WorkloadName = Name, ContainerName, p95_cpu, cpuLimitNano, observedPct = (p95_cpu / cpuLimitNano) * 100.0
"@

    $overMemoryQuery = @"
let lookback = $timeFilter;
KubePodInventory
| where TimeGenerated >= lookback
| where ClusterName =~ '$($cluster.name)'
| where isnotempty(ContainerName)
| summarize memoryLimitBytes = max(todouble(ContainerMemoryLimitBytes)) by Namespace, Name, ContainerName
| join kind=inner (
    Perf
    | where TimeGenerated >= lookback
    | where ObjectName == 'K8SContainer'
    | where CounterName == 'memoryRssBytes'
    | summarize p95_mem = percentile(CounterValue, 95) by Namespace = InstanceName, ContainerName
) on Namespace, ContainerName
| where memoryLimitBytes > 0 and p95_mem < memoryLimitBytes * 0.2
| project Namespace, WorkloadName = Name, ContainerName, p95_mem, memoryLimitBytes, observedPct = (p95_mem / memoryLimitBytes) * 100.0, recommendedMemoryMiB = round((p95_mem * 1.25) / 1048576.0, 2)
"@

    $underMemoryQuery = @"
let lookback = $timeFilter;
KubePodInventory
| where TimeGenerated >= lookback
| where ClusterName =~ '$($cluster.name)'
| where isnotempty(ContainerName)
| summarize memoryLimitBytes = max(todouble(ContainerMemoryLimitBytes)) by Namespace, Name, ContainerName
| join kind=inner (
    Perf
    | where TimeGenerated >= lookback
    | where ObjectName == 'K8SContainer'
    | where CounterName == 'memoryRssBytes'
    | summarize p95_mem = percentile(CounterValue, 95) by Namespace = InstanceName, ContainerName
) on Namespace, ContainerName
| where memoryLimitBytes > 0 and p95_mem >= memoryLimitBytes * 0.95
| project Namespace, WorkloadName = Name, ContainerName, p95_mem, memoryLimitBytes, observedPct = (p95_mem / memoryLimitBytes) * 100.0
"@

    $missingHpaQuery = @"
let lookback = $timeFilter;
KubePodInventory
| where TimeGenerated >= lookback
| where ClusterName =~ '$($cluster.name)'
| summarize replicasMin = min(tolong(PodRestartCount)), replicasMax = max(tolong(PodRestartCount)) by Namespace, ControllerName
| where isnotempty(ControllerName)
| where replicasMin == replicasMax and replicasMin > 1
| project Namespace, ControllerName, replicasMin, replicasMax
"@

    $oomQuery = @"
let lookback = $timeFilter;
KubePodInventory
| where TimeGenerated >= lookback
| where ClusterName =~ '$($cluster.name)'
| where ContainerStatusReason =~ 'OOMKilled' or PodStatus =~ 'Failed'
| project Namespace, WorkloadName = Name, ContainerName, PodStatus, ContainerStatusReason
"@

    $querySet = @(
        @{ Name = 'over-cpu'; Query = $overCpuQuery },
        @{ Name = 'under-cpu'; Query = $underCpuQuery },
        @{ Name = 'over-memory'; Query = $overMemoryQuery },
        @{ Name = 'under-memory'; Query = $underMemoryQuery },
        @{ Name = 'missing-hpa'; Query = $missingHpaQuery },
        @{ Name = 'oomkilled'; Query = $oomQuery }
    )

    foreach ($entry in $querySet) {
        $queryResponse = $null
        try {
            $queryName = [string]$entry.Name
            $queryText = [string]$entry.Query
            $queryResponse = Invoke-WithRetry -MaxAttempts 4 -InitialDelaySeconds 2 -MaxDelaySeconds 20 -ScriptBlock {
                Invoke-RightsizingKql -WorkspaceId $workspaceId -QueryName $queryName -QueryText $queryText
            }
        } catch {
            $workspaceErrors.Add("Cluster $($cluster.name) query '$($entry.Name)' failed: $(Remove-Credentials -Text ([string]$_.Exception.Message))") | Out-Null
            continue
        }

        $rows = @()
        if ($queryResponse.PSObject.Properties['Results'] -and $queryResponse.Results) {
            $rows = @($queryResponse.Results)
        } elseif ($queryResponse.PSObject.Properties['Value'] -and $queryResponse.Value) {
            $rows = @($queryResponse.Value)
        }

        foreach ($row in $rows) {
            switch ($entry.Name) {
                'over-cpu' {
                    $pct = [double]($row.observedPct ?? 0)
                    $rec = [double]($row.recommendedMillicores ?? 0)
                    $title = "Over-provisioned pod $($row.Namespace)/$($row.WorkloadName): P95 CPU $([math]::Round($pct, 1))% of limit (recommend $([math]::Round($rec, 0))m)"
                    $detail = "Container '$($row.ContainerName)' in cluster '$($cluster.name)' has P95 CPU below 20% of limit over ${LookbackDays}d."
                    Add-RightsizingFinding -Cluster $cluster -Category 'OverProvisionedCpu' -Severity 'Medium' -Compliant $false -Title $title -Detail $detail -Remediation 'Reduce CPU limit/request for this workload or raise HPA target utilization.' -Namespace ([string]$row.Namespace) -WorkloadName ([string]$row.WorkloadName) -ContainerName ([string]$row.ContainerName) -MetricType 'cpu' -ObservedPercent $pct -RecommendedMillicores $rec -WorkspaceId $workspaceId -QueryName $queryName -QueryText $queryText -ToolVersion $toolVersion
                }
                'under-cpu' {
                    $pct = [double]($row.observedPct ?? 0)
                    $title = "Under-provisioned pod $($row.Namespace)/$($row.WorkloadName): P95 CPU $([math]::Round($pct, 1))% of limit"
                    $detail = "Container '$($row.ContainerName)' in cluster '$($cluster.name)' is at or above 95% CPU limit over ${LookbackDays}d."
                    Add-RightsizingFinding -Cluster $cluster -Category 'UnderProvisionedCpu' -Severity 'High' -Compliant $false -Title $title -Detail $detail -Remediation 'Increase CPU limit/request or reduce load with HPA.' -Namespace ([string]$row.Namespace) -WorkloadName ([string]$row.WorkloadName) -ContainerName ([string]$row.ContainerName) -MetricType 'cpu' -ObservedPercent $pct -WorkspaceId $workspaceId -QueryName $queryName -QueryText $queryText -ToolVersion $toolVersion
                }
                'over-memory' {
                    $pct = [double]($row.observedPct ?? 0)
                    $rec = [double]($row.recommendedMemoryMiB ?? 0)
                    $title = "Over-provisioned pod $($row.Namespace)/$($row.WorkloadName): P95 memory $([math]::Round($pct, 1))% of limit (recommend $([math]::Round($rec, 0))Mi)"
                    $detail = "Container '$($row.ContainerName)' in cluster '$($cluster.name)' has P95 memory below 20% of limit over ${LookbackDays}d."
                    Add-RightsizingFinding -Cluster $cluster -Category 'OverProvisionedMemory' -Severity 'Medium' -Compliant $false -Title $title -Detail $detail -Remediation 'Reduce memory limit/request for this workload.' -Namespace ([string]$row.Namespace) -WorkloadName ([string]$row.WorkloadName) -ContainerName ([string]$row.ContainerName) -MetricType 'memory' -ObservedPercent $pct -RecommendedMemoryMiB $rec -WorkspaceId $workspaceId -QueryName $queryName -QueryText $queryText -ToolVersion $toolVersion
                }
                'under-memory' {
                    $pct = [double]($row.observedPct ?? 0)
                    $title = "Under-provisioned pod $($row.Namespace)/$($row.WorkloadName): P95 memory $([math]::Round($pct, 1))% of limit"
                    $detail = "Container '$($row.ContainerName)' in cluster '$($cluster.name)' is at or above 95% memory limit over ${LookbackDays}d."
                    Add-RightsizingFinding -Cluster $cluster -Category 'UnderProvisionedMemory' -Severity 'High' -Compliant $false -Title $title -Detail $detail -Remediation 'Increase memory limit/request and review memory leaks.' -Namespace ([string]$row.Namespace) -WorkloadName ([string]$row.WorkloadName) -ContainerName ([string]$row.ContainerName) -MetricType 'memory' -ObservedPercent $pct -WorkspaceId $workspaceId -QueryName $queryName -QueryText $queryText -ToolVersion $toolVersion
                }
                'missing-hpa' {
                    $title = "Static replicas for $($row.Namespace)/$($row.ControllerName): candidate for HPA"
                    $detail = "Replica pattern remained static (min=max=$($row.replicasMin)) over ${LookbackDays}d in cluster '$($cluster.name)'."
                    Add-RightsizingFinding -Cluster $cluster -Category 'MissingHpa' -Severity 'Info' -Compliant $false -Title $title -Detail $detail -Remediation 'Create an HPA policy for this workload and tune min/max replicas.' -Namespace ([string]$row.Namespace) -WorkloadName ([string]$row.ControllerName) -WorkspaceId $workspaceId -QueryName $queryName -QueryText $queryText -ToolVersion $toolVersion
                }
                'oomkilled' {
                    $title = "Pod OOMKilled $($row.Namespace)/$($row.WorkloadName): increase memory limit"
                    $detail = "Container '$($row.ContainerName)' reported '$($row.ContainerStatusReason)' in cluster '$($cluster.name)'."
                    Add-RightsizingFinding -Cluster $cluster -Category 'OomKilled' -Severity 'High' -Compliant $false -Title $title -Detail $detail -Remediation 'Increase memory limit/request and investigate memory growth.' -Namespace ([string]$row.Namespace) -WorkloadName ([string]$row.WorkloadName) -ContainerName ([string]$row.ContainerName) -MetricType 'memory' -WorkspaceId $workspaceId -QueryName $queryName -QueryText $queryText -ToolVersion $toolVersion
                }
            }
        }
    }

    if ($OutputPath) {
        try {
            if (-not (Test-Path $OutputPath)) { New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null }
            $sanitizedClusterName = ([string]$cluster.name) -replace '[^A-Za-z0-9._-]', '_'
            $rawOut = Join-Path $OutputPath "aks-rightsizing-$sanitizedClusterName-$workspaceName.json"
            $clusterFindings = @($findings | Where-Object { $_.ClusterName -eq $cluster.name })
            Set-Content -Path $rawOut -Value (Remove-Credentials ($clusterFindings | ConvertTo-Json -Depth 20)) -Encoding UTF8
        } catch {
            Write-Verbose "Failed writing rightsizing raw output for $($cluster.name): $(Remove-Credentials -Text ([string]$_.Exception.Message))"
        }
    }
}

$result.Findings = @($findings)
$result.ToolVersion = $toolVersion
if ($workspaceErrors.Count -gt 0 -and $findings.Count -gt 0) {
    $result.Status = 'PartialSuccess'
} elseif ($workspaceErrors.Count -gt 0 -and $findings.Count -eq 0) {
    $result.Status = 'Failed'
}

$baseMessage = "Scanned $clusterCount AKS cluster(s) over ${LookbackDays} day(s); emitted $($findings.Count) rightsizing finding(s)."
if ($workspaceErrors.Count -gt 0) {
    $result.Message = "$baseMessage Workspace/query errors: $($workspaceErrors -join ' | ')"
} else {
    $result.Message = $baseMessage
}

return [PSCustomObject]$result
