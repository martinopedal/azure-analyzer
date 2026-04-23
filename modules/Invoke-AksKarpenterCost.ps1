#Requires -Version 7.4
<#
.SYNOPSIS
    AKS Karpenter cost wrapper. Cluster-level node cost rollup + idle node
    detection (Reader-only) plus opt-in Karpenter Provisioner inspection
    (Azure Kubernetes Service Cluster User Role on the cluster).

.DESCRIPTION
    Two finding tiers are emitted:

      * Reader-only (always enabled):
          - aks.node-cost-rollup    Info    KubeNodeInventory node-hours x 7d
          - aks.idle-node           Medium  avg node CPU < 10% over LookbackDays

      * Elevated (Azure Kubernetes Service Cluster User Role; gated by
        -EnableElevatedRbac, OFF by default):
          - karpenter.consolidation-disabled  Medium  spec.consolidation.enabled=false
          - karpenter.over-provisioned        Medium  avg node util <50% over LookbackDays
          - karpenter.no-node-limit           High    spec.limits is missing

    Karpenter findings require a kubeconfig to query the
    `provisioners.karpenter.sh` CRD via kubectl. When -EnableElevatedRbac is
    NOT set the wrapper SKIPS the kubectl branch entirely; no kubeconfig
    fetch and no kubectl process is launched.

    Reuses shared modules:
      * AksDiscovery  (cluster discovery via Az.ResourceGraph)
      * KqlQuery      (Container Insights queries)
      * KubeAuth      (KubeAuthMode handling, identical to Invoke-Kubescape et al.)
      * Retry, Sanitize, Installer (Invoke-WithTimeout)
      * RbacTier      (the per-wrapper opt-in mechanism shipped in this PR)
#>
[CmdletBinding(SupportsShouldProcess=$true, ConfirmImpact='Medium')]
param (
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string] $SubscriptionId,

    [string] $ResourceGroup,
    [string] $ClusterName,
    [string] $LogAnalyticsWorkspaceId,

    [ValidateRange(1, 30)]
    [int] $LookbackDays = 7,

    [string] $KubeconfigPath,
    [string] $KubeContext,
    [string] $Namespace = '',

    [ValidateSet('Default', 'Kubelogin', 'WorkloadIdentity')]
    [string] $KubeAuthMode = 'Default',
    [string] $KubeloginServerId,
    [string] $KubeloginClientId,
    [string] $KubeloginTenantId,
    [string] $WorkloadIdentityClientId,
    [string] $WorkloadIdentityTenantId,
    [string] $WorkloadIdentityServiceAccountToken,

    [switch] $EnableElevatedRbac,

    [string] $OutputPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Shared module dot-source with no-op shims for unit-test isolation. Mirrors
# the pattern used by Invoke-AksRightsizing.
# ---------------------------------------------------------------------------
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
if (-not (Get-Command Invoke-WithTimeout -ErrorAction SilentlyContinue) -and (Test-Path $installerPath)) { . $installerPath }
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

$kubeAuthPath = Join-Path $PSScriptRoot 'shared' 'KubeAuth.ps1'
if (-not (Get-Command Initialize-KubeAuth -ErrorAction SilentlyContinue) -and (Test-Path $kubeAuthPath)) { . $kubeAuthPath }

$rbacTierPath = Join-Path $PSScriptRoot 'shared' 'RbacTier.ps1'
if (-not (Get-Command Get-RbacTier -ErrorAction SilentlyContinue) -and (Test-Path $rbacTierPath)) { . $rbacTierPath }

# ---------------------------------------------------------------------------
# Result envelope (v1)
# ---------------------------------------------------------------------------
$result = [ordered]@{
    SchemaVersion = '1.0'
    Source        = 'aks-karpenter-cost'
    Status        = 'Success'
    Message       = ''
    Findings      = @()
    Subscription  = $SubscriptionId
    Timestamp     = (Get-Date).ToUniversalTime().ToString('o')
    RbacTier      = 'Reader'
}

# ---------------------------------------------------------------------------
# Opt-in elevated RBAC tier
# ---------------------------------------------------------------------------
$allowElevatedOps = $EnableElevatedRbac.IsPresent
if ($EnableElevatedRbac.IsPresent) {
    $elevatedTarget = if (-not [string]::IsNullOrWhiteSpace($ClusterName)) { $ClusterName } elseif (-not [string]::IsNullOrWhiteSpace($ResourceGroup)) { $ResourceGroup } else { $SubscriptionId }
    $allowElevatedOps = $PSCmdlet.ShouldProcess($elevatedTarget, 'Initialize kube auth and run kubectl Karpenter inspection')
    if ($allowElevatedOps) {
        if (Get-Command Set-RbacTier -ErrorAction SilentlyContinue) {
            Set-RbacTier -Tier 'ClusterUser'
        }
        $result.RbacTier = 'ClusterUser'
    }
}

# ---------------------------------------------------------------------------
# Module preflight
# ---------------------------------------------------------------------------
if (-not (Get-Module -ListAvailable -Name Az.Accounts)) {
    if (Get-Command Reset-RbacTier -ErrorAction SilentlyContinue) { Reset-RbacTier }
    $result.Status  = 'Skipped'
    $result.Message = 'Az.Accounts module not installed. Run: Install-Module Az.Accounts -Scope CurrentUser'
    return [PSCustomObject]$result
}

if (-not (Get-Module -ListAvailable -Name Az.OperationalInsights)) {
    if (Get-Command Reset-RbacTier -ErrorAction SilentlyContinue) { Reset-RbacTier }
    $result.Status  = 'Skipped'
    $result.Message = 'Az.OperationalInsights module not installed. Run: Install-Module Az.OperationalInsights -Scope CurrentUser'
    return [PSCustomObject]$result
}

try {
    Import-Module Az.Accounts -ErrorAction SilentlyContinue -WarningAction SilentlyContinue
    $null = Get-AzContext -ErrorAction Stop
} catch {
    Write-Verbose 'Az context probe failed; downstream calls will surface concrete auth errors.'
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
function Resolve-WorkspaceIdFromCluster {
    [CmdletBinding()]
    param ([Parameter(Mandatory)][pscustomobject] $Cluster)

    if ($Cluster.PSObject.Properties['workspaceResourceId'] -and $Cluster.workspaceResourceId) {
        return [string]$Cluster.workspaceResourceId
    }
    $clusterId = [string]$Cluster.id
    if ([string]::IsNullOrWhiteSpace($clusterId)) { return '' }

    $diagUri = "https://management.azure.com$clusterId/providers/Microsoft.Insights/diagnosticSettings?api-version=2021-05-01-preview"
    try {
        $resp = Invoke-WithRetry -MaxAttempts 3 -InitialDelaySeconds 2 -MaxDelaySeconds 20 -ScriptBlock {
            Invoke-AzRestMethod -Method GET -Uri $diagUri -ErrorAction Stop
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

function Get-ClusterInsightsUrl {
    param([string]$ClusterId)
    if (-not $ClusterId) { return '' }
    return "https://portal.azure.com/#@/resource$ClusterId/insights"
}

function Get-AksClusterPortalDeepLink {
    param(
        [string]$ClusterId,
        [string]$ProvisionerName = ''
    )
    if (-not $ClusterId) { return '' }
    $encodedCluster = [System.Uri]::EscapeDataString($ClusterId)
    if (-not [string]::IsNullOrWhiteSpace($ProvisionerName)) {
        $encodedProvisioner = [System.Uri]::EscapeDataString($ProvisionerName)
        return "https://portal.azure.com/#view/Microsoft_Azure_ContainerService/ManagedClusterMenuBlade/~/karpenter/resourceId/$encodedCluster/provisioner/$encodedProvisioner"
    }
    return "https://portal.azure.com/#view/Microsoft_Azure_ContainerService/ManagedClusterMenuBlade/~/nodes/resourceId/$encodedCluster"
}

function Get-LogsQueryEvidenceUrl {
    param(
        [string]$WorkspaceId,
        [string]$Query
    )
    if ([string]::IsNullOrWhiteSpace($WorkspaceId) -or [string]::IsNullOrWhiteSpace($Query)) { return '' }
    $encodedWs = [System.Uri]::EscapeDataString($WorkspaceId)
    $encodedQ = [System.Uri]::EscapeDataString($Query)
    return "https://portal.azure.com/#blade/Microsoft_Azure_Monitoring_Logs/LogsBlade/resourceId/$encodedWs/source/LogsBlade.AnalyticsShareLinkToQuery/q/$encodedQ"
}

function Get-KarpenterManifestEvidenceUrl {
    param(
        [string]$ProvisionerName,
        [string]$ApiVersion = ''
    )
    if ([string]::IsNullOrWhiteSpace($ProvisionerName)) { return '' }
    $safeName = [System.Uri]::EscapeDataString($ProvisionerName)
    $resolvedApiVersion = if ([string]::IsNullOrWhiteSpace($ApiVersion)) { 'v1beta1' } else { $ApiVersion }
    return "https://kubernetes.default.svc/apis/karpenter.sh/$resolvedApiVersion/provisioners/$safeName"
}

function Resolve-KarpenterPillar {
    param([string]$RuleId)
    if ($RuleId -eq 'karpenter.consolidation-disabled') { return 'Cost Optimization; Reliability' }
    return 'Cost Optimization'
}

function Resolve-KarpenterImpact {
    param(
        [string]$RuleId,
        [Nullable[double]]$NodeHours = $null,
        [Nullable[double]]$ObservedPercent = $null
    )
    if ($RuleId -eq 'karpenter.no-node-limit') { return 'High' }
    if ($RuleId -eq 'karpenter.consolidation-disabled') { return 'Medium' }
    if ($NodeHours -ne $null) {
        if ($NodeHours -ge 500.0) { return 'High' }
        if ($NodeHours -ge 150.0) { return 'Medium' }
        return 'Low'
    }
    if ($ObservedPercent -ne $null) {
        if ($ObservedPercent -le 10.0) { return 'High' }
        if ($ObservedPercent -le 35.0) { return 'Medium' }
        return 'Low'
    }
    return 'Low'
}

function Resolve-KarpenterEffort {
    param([string]$RuleId)
    if ($RuleId -like 'karpenter.*') { return 'Medium' }
    return 'Low'
}

function Get-KarpenterBaselineTags {
    param(
        [string]$RuleId,
        [string]$RbacTier
    )
    $ruleTag = switch ($RuleId) {
        'aks.idle-node' { 'Karpenter-IdleNodes' }
        'karpenter.consolidation-disabled' { 'Karpenter-Consolidation' }
        'karpenter.no-node-limit' { 'Karpenter-ProvisionerLimits' }
        'karpenter.over-provisioned' { 'Karpenter-IdleNodes' }
        default { 'Karpenter-NodeHours' }
    }
    $rbacTag = if ($RbacTier -eq 'Reader') { 'RBAC-Reader' } else { 'RBAC-ClusterAdmin' }
    return @($ruleTag, $rbacTag)
}

function Get-KarpenterRemediationSnippets {
    param(
        [string]$RuleId,
        [string]$ProvisionerName
    )
    $target = if ([string]::IsNullOrWhiteSpace($ProvisionerName)) { '<provisioner>' } else { $ProvisionerName }
    switch ($RuleId) {
        'karpenter.no-node-limit' {
            return @(@{
                    language = 'yaml'
                    before   = "apiVersion: karpenter.sh/v1beta1`nkind: NodePool`nmetadata:`n  name: $target`nspec:`n  limits: null"
                    after    = "apiVersion: karpenter.sh/v1beta1`nkind: NodePool`nmetadata:`n  name: $target`nspec:`n  limits:`n    cpu: '200'`n    memory: 400Gi"
                })
        }
        'karpenter.consolidation-disabled' {
            return @(@{
                    language = 'yaml'
                    before   = "apiVersion: karpenter.sh/v1beta1`nkind: NodePool`nmetadata:`n  name: $target`nspec:`n  disruption:`n    consolidationPolicy: WhenEmpty"
                    after    = "apiVersion: karpenter.sh/v1beta1`nkind: NodePool`nmetadata:`n  name: $target`nspec:`n  disruption:`n    consolidationPolicy: WhenUnderutilized"
                })
        }
        default { return @() }
    }
}

function Get-KubectlClientVersion {
    try {
        $proc = Invoke-WithTimeout -Command 'kubectl' -Arguments @('version', '--client', '--output=yaml') -TimeoutSec 300
        if ($proc.ExitCode -ne 0) { return 'unknown' }
        $text = [string]$proc.Output
        $match = [regex]::Match($text, '(?im)^\s*gitVersion:\s*v?([0-9]+\.[0-9]+\.[0-9]+[^\s]*)')
        if ($match.Success) { return "v$($match.Groups[1].Value)" }
        return 'unknown'
    } catch {
        return 'unknown'
    }
}

function Get-KarpenterDocsUrl {
    param([string]$RuleId)
    switch ($RuleId) {
        'karpenter.consolidation-disabled' { 'https://karpenter.sh/docs/concepts/disruption/#consolidation' }
        'karpenter.over-provisioned'        { 'https://karpenter.sh/docs/concepts/nodepools/' }
        'karpenter.no-node-limit'           { 'https://karpenter.sh/docs/concepts/nodepools/#speclimits' }
        default                             { 'https://karpenter.sh/docs/' }
    }
}

function New-ProvisionerEntityId {
    param (
        [Parameter(Mandatory)][string] $ClusterId,
        [Parameter(Mandatory)][string] $ProvisionerName
    )
    $base = $ClusterId.Trim().TrimEnd('/')
    $safeName = ($ProvisionerName.Trim() -replace '[^A-Za-z0-9._-]', '-').ToLowerInvariant()
    return "$base/karpenter/provisioners/$safeName"
}

function Add-Finding {
    param (
        [Parameter(Mandatory)][pscustomobject] $Cluster,
        [Parameter(Mandatory)][string] $RuleId,
        [Parameter(Mandatory)][string] $Severity,
        [Parameter(Mandatory)][string] $Title,
        [Parameter(Mandatory)][string] $Detail,
        [Parameter(Mandatory)][string] $Remediation,
        [Parameter(Mandatory)][bool]   $Compliant,
        [Parameter(Mandatory)][ValidateSet('AzureResource', 'KarpenterProvisioner')]
        [string] $EntityType,
        [string] $ProvisionerName = '',
        [string] $LearnMoreUrl    = '',
        [string] $WorkspaceId     = '',
        [string] $EvidenceQuery   = '',
        [string] $KarpenterApiVersion = '',
        [hashtable] $Extra        = @{}
    )

    $clusterId = [string]$Cluster.id
    $entityRawId = if ($EntityType -eq 'KarpenterProvisioner' -and $ProvisionerName) {
        New-ProvisionerEntityId -ClusterId $clusterId -ProvisionerName $ProvisionerName
    } else {
        $clusterId
    }

    if (-not $LearnMoreUrl) {
        $LearnMoreUrl = if ($EntityType -eq 'KarpenterProvisioner') {
            Get-KarpenterDocsUrl -RuleId $RuleId
        } else {
            Get-ClusterInsightsUrl -ClusterId $clusterId
        }
    }

    $nodeHours = $null
    if ($Extra.ContainsKey('NodeHours') -and $null -ne $Extra['NodeHours']) {
        $nodeHours = [double]$Extra['NodeHours']
    }
    $observedPercent = $null
    if ($Extra.ContainsKey('ObservedPercent') -and $null -ne $Extra['ObservedPercent']) {
        $observedPercent = [double]$Extra['ObservedPercent']
    }
    $scoreDelta = if ($nodeHours -ne $null) { $nodeHours } elseif ($observedPercent -ne $null) { $observedPercent } else { $null }
    $evidenceUris = [System.Collections.Generic.List[string]]::new()
    $logEvidence = Get-LogsQueryEvidenceUrl -WorkspaceId $WorkspaceId -Query $EvidenceQuery
    if ($logEvidence) { $evidenceUris.Add($logEvidence) | Out-Null }
    if ($EntityType -eq 'KarpenterProvisioner' -and -not [string]::IsNullOrWhiteSpace($ProvisionerName)) {
        $manifestUri = Get-KarpenterManifestEvidenceUrl -ProvisionerName $ProvisionerName -ApiVersion $KarpenterApiVersion
        if ($manifestUri) { $evidenceUris.Add($manifestUri) | Out-Null }
    }

    $entityRefs = [System.Collections.Generic.List[string]]::new()
    if (-not [string]::IsNullOrWhiteSpace($clusterId)) { $entityRefs.Add($clusterId) | Out-Null }
    if (-not [string]::IsNullOrWhiteSpace($ProvisionerName)) { $entityRefs.Add($ProvisionerName) | Out-Null }

    $findingId = "aks-karpenter-cost/$RuleId/$($Cluster.name)/$([guid]::NewGuid().ToString('N'))"
    $row = [ordered]@{
        Id                   = $findingId
        Source               = 'aks-karpenter-cost'
        RuleId               = $RuleId
        Category             = 'Cost'
        Severity             = $Severity
        Compliant            = $Compliant
        Title                = $Title
        Detail               = $Detail
        Remediation          = $Remediation
        ResourceId           = $clusterId
        EntityRawId          = $entityRawId
        EntityType           = $EntityType
        LearnMoreUrl         = $LearnMoreUrl
        DeepLinkUrl          = Get-AksClusterPortalDeepLink -ClusterId $clusterId -ProvisionerName $ProvisionerName
        ClusterName          = [string]$Cluster.name
        ClusterResourceGroup = [string]$Cluster.resourceGroup
        ProvisionerName      = $ProvisionerName
        RbacTier             = $result.RbacTier
        Pillar               = Resolve-KarpenterPillar -RuleId $RuleId
        Impact               = Resolve-KarpenterImpact -RuleId $RuleId -NodeHours $nodeHours -ObservedPercent $observedPercent
        Effort               = Resolve-KarpenterEffort -RuleId $RuleId
        BaselineTags         = @(Get-KarpenterBaselineTags -RuleId $RuleId -RbacTier $result.RbacTier)
        EvidenceUris         = @($evidenceUris)
        ScoreDelta           = $scoreDelta
        EntityRefs           = @($entityRefs)
        RemediationSnippets  = @(Get-KarpenterRemediationSnippets -RuleId $RuleId -ProvisionerName $ProvisionerName)
    }
    foreach ($k in $Extra.Keys) {
        $row[$k] = $Extra[$k]
    }
    $script:findings.Add([PSCustomObject]$row) | Out-Null
}

function Invoke-KarpenterKubectl {
    <#
    .SYNOPSIS
        Run `kubectl get provisioners.karpenter.sh -A -o json` against the
        supplied kubeconfig and return parsed items. Returns @() on any
        non-zero exit (the caller logs the workspace error).
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)][string] $KubeconfigPath,
        [string] $KubeContext,
        [string] $Namespace = ''
    )

    $kArgs = @('--kubeconfig', $KubeconfigPath, 'get', 'provisioners.karpenter.sh', '-o', 'json')
    if ($KubeContext)       { $kArgs += @('--context', $KubeContext) }
    if ($Namespace)         { $kArgs += @('-n', $Namespace) }
    else                    { $kArgs += @('-A') }

    $proc = Invoke-WithTimeout -Command 'kubectl' -Arguments $kArgs -TimeoutSec 300
    if ($proc.ExitCode -ne 0) {
        throw (Format-FindingErrorMessage (New-FindingError -Source 'wrapper:aks-karpenter-cost' -Category 'UnexpectedFailure' -Reason "kubectl get provisioners.karpenter.sh failed with exit code $($proc.ExitCode)." -Remediation 'Verify cluster access, kubeconfig context, and kubectl permissions for provisioners.karpenter.sh.' -Details ([string]$proc.Output)))
    }
    if ([string]::IsNullOrWhiteSpace($proc.Output)) { return @() }

    try {
        $parsed = $proc.Output | ConvertFrom-Json -Depth 20
    } catch {
        throw (Format-FindingErrorMessage (New-FindingError -Source 'wrapper:aks-karpenter-cost' -Category 'ConfigurationError' -Reason 'kubectl returned non-JSON output.' -Remediation 'Ensure kubectl returns JSON for provisioners.karpenter.sh and that no shell wrappers modify output.' -Details ([string]$_.Exception.Message)))
    }

    if ($parsed -and $parsed.PSObject.Properties['items']) { return @($parsed.items) }
    return @()
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
$findings = [System.Collections.Generic.List[object]]::new()
$workspaceErrors = [System.Collections.Generic.List[string]]::new()
$kubectlVersion = if ($EnableElevatedRbac.IsPresent) { 'unknown' } else { 'not-run' }
$karpenterVersion = if ($EnableElevatedRbac.IsPresent) { 'unknown' } else { 'not-run' }

try {
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

    foreach ($cluster in $clusters) {
        # ----- Reader-tier KQL findings -----
        $workspaceId = if ($LogAnalyticsWorkspaceId) { $LogAnalyticsWorkspaceId } else { Resolve-WorkspaceIdFromCluster -Cluster $cluster }
        if ([string]::IsNullOrWhiteSpace($workspaceId)) {
            $workspaceErrors.Add("Cluster $($cluster.name): Container Insights workspace not found.") | Out-Null
        } else {
            $timeFilter = "ago(${LookbackDays}d)"

            $nodeCostQuery = @"
let lookback = $timeFilter;
KubeNodeInventory
| where TimeGenerated >= lookback
| where ClusterName =~ '$($cluster.name)'
| summarize firstSeen = min(TimeGenerated), lastSeen = max(TimeGenerated) by Computer
| extend nodeHours = round(datetime_diff('hour', lastSeen, firstSeen), 2)
| summarize nodes = dcount(Computer), totalNodeHours = sum(nodeHours)
"@

            $idleNodeQuery = @"
let lookback = $timeFilter;
Perf
| where TimeGenerated >= lookback
| where ObjectName == 'K8SNode'
| where CounterName == 'cpuUsageNanoCores'
| summarize avg_cpu = avg(CounterValue), capacityNano = max(CounterValue) by Computer
| extend pct = iff(capacityNano > 0, (avg_cpu / capacityNano) * 100.0, 0.0)
| where pct < 10.0
| project Computer, observedPct = round(pct, 2), avg_cpu
"@

            try {
                $costRows = @()
                $resp = Invoke-WithRetry -MaxAttempts 4 -InitialDelaySeconds 2 -MaxDelaySeconds 20 -ScriptBlock {
                    Invoke-LogAnalyticsQuery -WorkspaceId $workspaceId -Query $nodeCostQuery -TimeoutSeconds 300
                }
                if ($resp -and $resp.PSObject.Properties['Results']) { $costRows = @($resp.Results) }
                foreach ($row in $costRows) {
                    $nodes = [int]($row.nodes ?? 0)
                    $hours = [double]($row.totalNodeHours ?? 0)
                    if ($nodes -le 0) { continue }
                    Add-Finding -Cluster $cluster -RuleId 'aks.node-cost-rollup' -Severity 'Info' -Compliant $true `
                        -EntityType 'AzureResource' `
                        -Title "AKS node cost rollup for $($cluster.name): $nodes node(s), $([math]::Round($hours,1)) node-hours over ${LookbackDays}d" `
                        -Detail  "Container Insights observed $nodes distinct node(s) totalling $([math]::Round($hours,1)) node-hour(s) in cluster '$($cluster.name)' over the last ${LookbackDays} day(s). Multiply by your VM SKU rate to obtain a cost estimate." `
                        -Remediation 'Review node hours in Cost Management; consider Karpenter consolidation or smaller VM SKUs if utilization is low.' `
                        -WorkspaceId $workspaceId -EvidenceQuery $nodeCostQuery `
                        -Extra @{ NodeCount = $nodes; NodeHours = [math]::Round($hours, 2) }
                }
            } catch {
                $workspaceErrors.Add("Cluster $($cluster.name) node-cost-rollup query failed: $(Remove-Credentials -Text ([string]$_.Exception.Message))") | Out-Null
            }

            try {
                $idleRows = @()
                $resp = Invoke-WithRetry -MaxAttempts 4 -InitialDelaySeconds 2 -MaxDelaySeconds 20 -ScriptBlock {
                    Invoke-LogAnalyticsQuery -WorkspaceId $workspaceId -Query $idleNodeQuery -TimeoutSeconds 300
                }
                if ($resp -and $resp.PSObject.Properties['Results']) { $idleRows = @($resp.Results) }
                foreach ($row in $idleRows) {
                    $pct = [double]($row.observedPct ?? 0)
                    Add-Finding -Cluster $cluster -RuleId 'aks.idle-node' -Severity 'Medium' -Compliant $false `
                        -EntityType 'AzureResource' `
                        -Title "Idle node $($row.Computer) in $($cluster.name): avg CPU $([math]::Round($pct,1))% over ${LookbackDays}d" `
                        -Detail  "Node '$($row.Computer)' averaged $([math]::Round($pct,2))% CPU utilization over the last ${LookbackDays} day(s)." `
                        -Remediation 'Cordon and drain the node, or enable Karpenter consolidation / cluster autoscaler scale-down to remove idle capacity.' `
                        -WorkspaceId $workspaceId -EvidenceQuery $idleNodeQuery `
                        -Extra @{ NodeName = [string]$row.Computer; ObservedPercent = [math]::Round($pct, 2) }
                }
            } catch {
                $workspaceErrors.Add("Cluster $($cluster.name) idle-node query failed: $(Remove-Credentials -Text ([string]$_.Exception.Message))") | Out-Null
            }
        }

        # ----- Elevated-tier Karpenter findings (gated) -----
        if (-not $allowElevatedOps) { continue }

        # Honor -WhatIf / ShouldProcess: skip ALL side-effecting calls
        # (kubectl invocations + Initialize-KubeAuth) when running in WhatIf
        # mode. The reader-tier KQL findings above are already accumulated.
        $shouldProcessTarget = "AKS cluster '$($cluster.name)' (elevated Karpenter inspection: kubectl + kube-auth)"
        if (-not $PSCmdlet.ShouldProcess($shouldProcessTarget, 'Invoke kubectl + Initialize-KubeAuth')) {
            continue
        }

        if (Get-Command Assert-RbacTier -ErrorAction SilentlyContinue) {
            try { Assert-RbacTier -Required 'ClusterUser' -Capability 'Karpenter Provisioner inspection' -OptInFlag '-EnableElevatedRbac' }
            catch {
                $workspaceErrors.Add("Cluster $($cluster.name) karpenter inspection skipped: $(Remove-Credentials -Text ([string]$_.Exception.Message))") | Out-Null
                continue
            }
        }

        if (-not (Get-Command kubectl -ErrorAction SilentlyContinue)) {
            $kubectlVersion = 'missing'
            $workspaceErrors.Add("Cluster $($cluster.name): kubectl not on PATH; install via 'az aks install-cli'.") | Out-Null
            continue
        }

        if ([string]::IsNullOrWhiteSpace($KubeconfigPath)) {
            $workspaceErrors.Add("Cluster $($cluster.name): -KubeconfigPath required when -EnableElevatedRbac is set.") | Out-Null
            continue
        }
        if ($kubectlVersion -eq 'unknown') {
            $kubectlVersion = Get-KubectlClientVersion
        }

        $kubeAuth = $null
        try {
            $kubeAuth = Initialize-KubeAuth `
                -Mode $KubeAuthMode `
                -KubeconfigPath $KubeconfigPath `
                -KubeContext $KubeContext `
                -KubeloginServerId $KubeloginServerId `
                -KubeloginClientId $KubeloginClientId `
                -KubeloginTenantId $KubeloginTenantId `
                -WorkloadIdentityClientId $WorkloadIdentityClientId `
                -WorkloadIdentityTenantId $WorkloadIdentityTenantId `
                -WorkloadIdentityServiceAccountToken $WorkloadIdentityServiceAccountToken
        } catch {
            $workspaceErrors.Add("Cluster $($cluster.name) kube-auth init failed: $(Remove-Credentials -Text ([string]$_.Exception.Message))") | Out-Null
            continue
        }

        try {
            $items = @()
            try {
                $items = @(
                    Invoke-WithRetry -MaxAttempts 3 -InitialDelaySeconds 2 -MaxDelaySeconds 20 -ScriptBlock {
                        Invoke-KarpenterKubectl -KubeconfigPath $kubeAuth.KubeconfigPath -KubeContext $KubeContext -Namespace $Namespace
                    }
                )
            } catch {
                $workspaceErrors.Add("Cluster $($cluster.name) karpenter list failed: $(Remove-Credentials -Text ([string]$_.Exception.Message))") | Out-Null
                continue
            }

            foreach ($prov in $items) {
                if (-not $prov) { continue }
                $name = if ($prov.PSObject.Properties['metadata'] -and $prov.metadata.name) { [string]$prov.metadata.name } else { 'unknown' }
                $spec = if ($prov.PSObject.Properties['spec'])     { $prov.spec }     else { $null }
                $provApiVersion = if ($prov.PSObject.Properties['apiVersion']) { [string]$prov.apiVersion } else { '' }
                if ($karpenterVersion -eq 'unknown' -and $provApiVersion -match '/(v[0-9a-zA-Z]+)$') {
                    $karpenterVersion = $Matches[1]
                }

                # consolidation-disabled
                $consolidationEnabled = $false
                if ($spec -and $spec.PSObject.Properties['consolidation'] -and $spec.consolidation.PSObject.Properties['enabled']) {
                    $consolidationEnabled = [bool]$spec.consolidation.enabled
                } elseif ($spec -and $spec.PSObject.Properties['disruption'] -and $spec.disruption.PSObject.Properties['consolidationPolicy']) {
                    $consolidationEnabled = ([string]$spec.disruption.consolidationPolicy -ne 'WhenEmpty')
                }
                if (-not $consolidationEnabled) {
                    Add-Finding -Cluster $cluster -RuleId 'karpenter.consolidation-disabled' -Severity 'Medium' -Compliant $false `
                        -EntityType 'KarpenterProvisioner' -ProvisionerName $name `
                        -Title "Karpenter Provisioner '$name' has consolidation disabled" `
                        -Detail  "Provisioner '$name' in cluster '$($cluster.name)' is not configured for consolidation. Karpenter will not bin-pack workloads onto fewer nodes." `
                        -Remediation 'Set spec.consolidation.enabled=true (or spec.disruption.consolidationPolicy=WhenUnderutilized) on the Provisioner / NodePool.' `
                        -WorkspaceId $workspaceId -KarpenterApiVersion $provApiVersion
                }

                # no-node-limit
                $hasLimits = $false
                if ($spec -and $spec.PSObject.Properties['limits']) {
                    $hasLimits = ($null -ne $spec.limits)
                }
                if (-not $hasLimits) {
                    Add-Finding -Cluster $cluster -RuleId 'karpenter.no-node-limit' -Severity 'High' -Compliant $false `
                        -EntityType 'KarpenterProvisioner' -ProvisionerName $name `
                        -Title "Karpenter Provisioner '$name' has no spec.limits set" `
                        -Detail  "Provisioner '$name' in cluster '$($cluster.name)' has no resource limits configured. A pod scheduling burst can scale node count without bound, creating runaway cost risk." `
                        -Remediation 'Add spec.limits.resources (e.g. cpu, memory) to cap how much capacity Karpenter may provision for this NodePool.' `
                        -WorkspaceId $workspaceId -KarpenterApiVersion $provApiVersion
                }

                # over-provisioned (Container Insights)
                if (-not [string]::IsNullOrWhiteSpace($workspaceId)) {
                    $overQuery = @"
let lookback = ago(${LookbackDays}d);
let provLabel = '$name';
KubeNodeInventory
| where TimeGenerated >= lookback
| where ClusterName =~ '$($cluster.name)'
| where Labels has provLabel or Labels has 'karpenter.sh/provisioner-name'
| summarize nodes = dcount(Computer) by Computer
| join kind=inner (
    Perf
    | where TimeGenerated >= lookback
    | where ObjectName == 'K8SNode'
    | where CounterName == 'cpuUsageNanoCores'
    | summarize avg_cpu = avg(CounterValue), capacityNano = max(CounterValue) by Computer
) on Computer
| extend pct = iff(capacityNano > 0, (avg_cpu / capacityNano) * 100.0, 0.0)
| summarize avgPct = avg(pct), nodeCount = count()
| where avgPct < 50.0
"@
                    try {
                        $overRows = @()
                        $resp = Invoke-WithRetry -MaxAttempts 3 -InitialDelaySeconds 2 -MaxDelaySeconds 20 -ScriptBlock {
                            Invoke-LogAnalyticsQuery -WorkspaceId $workspaceId -Query $overQuery -TimeoutSeconds 300
                        }
                        if ($resp -and $resp.PSObject.Properties['Results']) { $overRows = @($resp.Results) }
                        foreach ($row in $overRows) {
                            $pct = [double]($row.avgPct ?? 0)
                            $nc  = [int]($row.nodeCount ?? 0)
                            Add-Finding -Cluster $cluster -RuleId 'karpenter.over-provisioned' -Severity 'Medium' -Compliant $false `
                                -EntityType 'KarpenterProvisioner' -ProvisionerName $name `
                                -Title "Karpenter Provisioner '$name' over-provisioned: avg $([math]::Round($pct,1))% CPU across $nc node(s)" `
                                -Detail  "Average node CPU utilization for nodes managed by Provisioner '$name' was $([math]::Round($pct,2))% over ${LookbackDays}d (threshold 50%)." `
                                -Remediation 'Lower spec.limits, enable consolidation, or pick a smaller default instance type.' `
                                -WorkspaceId $workspaceId -EvidenceQuery $overQuery -KarpenterApiVersion $provApiVersion `
                                -Extra @{ ObservedPercent = [math]::Round($pct, 2); NodeCount = $nc }
                        }
                    } catch {
                        $workspaceErrors.Add("Cluster $($cluster.name) over-provisioned query for '$name' failed: $(Remove-Credentials -Text ([string]$_.Exception.Message))") | Out-Null
                    }
                }
            }
        } finally {
            if ($kubeAuth -and $kubeAuth.PSObject.Properties['Cleanup']) {
                try { & $kubeAuth.Cleanup } catch { Write-Verbose ("KubeAuth cleanup failed: {0}" -f (Remove-Credentials -Text ([string]$_.Exception.Message))) }
            }
        }
    }

    if ($OutputPath) {
        try {
            if (-not (Test-Path $OutputPath)) { New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null }
            $rawOut = Join-Path $OutputPath "aks-karpenter-cost-$SubscriptionId.json"
            Set-Content -Path $rawOut -Value (Remove-Credentials (($findings | ConvertTo-Json -Depth 20))) -Encoding UTF8
        } catch {
            Write-Verbose "Failed writing karpenter cost raw output: $(Remove-Credentials -Text ([string]$_.Exception.Message))"
        }
    }
}
finally {
    if ($EnableElevatedRbac.IsPresent -and (Get-Command Reset-RbacTier -ErrorAction SilentlyContinue)) {
        Reset-RbacTier
    }
}

$result.ToolVersion = "kubectl=$kubectlVersion; karpenter=$karpenterVersion"
foreach ($finding in $findings) {
    if ($finding.PSObject.Properties['ToolVersion']) {
        $finding.ToolVersion = $result.ToolVersion
    } else {
        $finding | Add-Member -NotePropertyName ToolVersion -NotePropertyValue $result.ToolVersion -Force
    }
}

$result.Findings = @($findings)
if ($workspaceErrors.Count -gt 0 -and $findings.Count -gt 0) {
    $result.Status = 'PartialSuccess'
} elseif ($workspaceErrors.Count -gt 0 -and $findings.Count -eq 0) {
    $result.Status = 'Failed'
}

$baseMessage = "Scanned $($clusters.Count) AKS cluster(s) over ${LookbackDays} day(s); emitted $($findings.Count) cost finding(s); RBAC tier '$($result.RbacTier)'."
if ($workspaceErrors.Count -gt 0) {
    $result.Message = "$baseMessage Errors: $($workspaceErrors -join ' | ')"
} else {
    $result.Message = $baseMessage
}

return [PSCustomObject]$result
