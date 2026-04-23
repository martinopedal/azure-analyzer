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

.PARAMETER KubeconfigPath
    Optional path to an existing kubeconfig file. In install mode this
    skips Azure Resource Graph discovery and `az aks get-credentials`,
    and targets the cluster reachable via this kubeconfig. Ignored in
    query mode (query mode reads Azure-side alerts, not cluster state).
    The file MUST exist when set explicitly; URLs are rejected.

.PARAMETER KubeContext
    Optional kubeconfig context name passed to `helm` and `kubectl`
    via `--kube-context` / `--context` in install mode.

.PARAMETER Namespace
    Namespace used in install mode for the Falco Helm release and the
    `kubectl logs daemonset/falco` collection. Default 'falco'.

.PARAMETER KubeAuthMode
    Auth mode applied to the kubeconfig before each install-mode invocation.
    One of Default | Kubelogin | WorkloadIdentity. See docs/consumer/k8s-auth.md.

.PARAMETER KubeloginServerId / KubeloginClientId / KubeloginTenantId
    AAD args for kubelogin convert-kubeconfig. ClientId+TenantId enables spn
    flow; otherwise azurecli flow is used.

.PARAMETER WorkloadIdentityClientId / WorkloadIdentityTenantId / WorkloadIdentityServiceAccountToken
    Federated identity args. Path-or-value token; sets
    AZURE_CLIENT_ID / AZURE_TENANT_ID / AZURE_FEDERATED_TOKEN_FILE.
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param (
    [Parameter(Mandatory)] [string] $SubscriptionId,
    [string[]] $ClusterArmIds,
    [switch] $InstallFalco,
    [switch] $UninstallFalco,
    [ValidateRange(1, 60)] [int] $CaptureMinutes = 5,
    [string] $KubeconfigPath,
    [string] $KubeContext,
    [string] $Namespace = 'falco',
    [ValidateSet('Default', 'Kubelogin', 'WorkloadIdentity')]
    [string] $KubeAuthMode = 'Default',
    [string] $KubeloginServerId,
    [string] $KubeloginClientId,
    [string] $KubeloginTenantId,
    [string] $WorkloadIdentityClientId,
    [string] $WorkloadIdentityTenantId,
    [string] $WorkloadIdentityServiceAccountToken
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$retryPath = Join-Path $PSScriptRoot 'shared' 'Retry.ps1'
if (Test-Path $retryPath) { . $retryPath }
if (-not (Get-Command Invoke-WithRetry -ErrorAction SilentlyContinue)) {
    function Invoke-WithRetry { param([scriptblock]$ScriptBlock, [int]$MaxAttempts = 3) & $ScriptBlock }
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

$kubeAuthPath = Join-Path $PSScriptRoot 'shared' 'KubeAuth.ps1'
if (Test-Path $kubeAuthPath) { . $kubeAuthPath }

$envelopePath = Join-Path $PSScriptRoot 'shared' 'New-WrapperEnvelope.ps1'
if (Test-Path $envelopePath) { . $envelopePath }
if (-not (Get-Command New-WrapperEnvelope -ErrorAction SilentlyContinue)) { function New-WrapperEnvelope { param([string]$Source,[string]$Status='Failed',[string]$Message='',[object[]]$FindingErrors=@()) return [PSCustomObject]@{ Source=$Source; SchemaVersion='1.0'; Status=$Status; Message=$Message; Findings=@(); Errors=@($FindingErrors) } } }
$result = [ordered]@{
    SchemaVersion = '1.0'
    Source        = 'falco'
    Status        = 'Success'
    Message       = ''
    Findings      = @()
    Subscription  = $SubscriptionId
    Timestamp     = (Get-Date).ToUniversalTime().ToString('o')
}

# Validate -KubeconfigPath up front (applies to install mode; in query mode the
# file is not used but we still reject obviously broken values to keep the
# param contract consistent across wrappers).
$kubeconfigModeRequested = $PSBoundParameters.ContainsKey('KubeconfigPath') -or `
                           $PSBoundParameters.ContainsKey('KubeContext')

# Validate KubeAuthMode prerequisites up front. Default mode is a no-op.
# Falco install mode is the only path that touches the cluster, but we
# validate regardless so misconfigured query-mode invocations also fail
# fast (consistent contract across the three K8s wrappers).
Assert-KubeAuthMode `
    -Mode $KubeAuthMode `
    -KubeloginServerId $KubeloginServerId `
    -KubeloginClientId $KubeloginClientId `
    -KubeloginTenantId $KubeloginTenantId `
    -WorkloadIdentityClientId $WorkloadIdentityClientId `
    -WorkloadIdentityTenantId $WorkloadIdentityTenantId `
    -WorkloadIdentityServiceAccountToken $WorkloadIdentityServiceAccountToken
$resolvedKubeconfig = $null
if ($PSBoundParameters.ContainsKey('KubeconfigPath')) {
    if ([string]::IsNullOrWhiteSpace($KubeconfigPath)) {
        throw (Format-FindingErrorMessage (New-FindingError -Source 'wrapper:falco' -Category 'InvalidParameter' -Reason 'Invalid -KubeconfigPath: value is empty.' -Remediation 'Provide a non-empty local file path via -KubeconfigPath.'))
    }
    if ($KubeconfigPath -match '^[a-z][a-z0-9+.-]*://') {
        throw (Format-FindingErrorMessage (New-FindingError -Source 'wrapper:falco' -Category 'InvalidParameter' -Reason "Invalid -KubeconfigPath '$(Remove-Credentials -Text $KubeconfigPath)': URLs are not accepted; provide a local file path." -Remediation 'Use a local kubeconfig file path, not a URL.'))
    }
    if (-not (Test-Path -LiteralPath $KubeconfigPath -PathType Leaf)) {
        throw (Format-FindingErrorMessage (New-FindingError -Source 'wrapper:falco' -Category 'NotFound' -Reason "Invalid -KubeconfigPath '$(Remove-Credentials -Text $KubeconfigPath)': file does not exist." -Remediation 'Provide an existing kubeconfig file path via -KubeconfigPath.'))
    }
    $resolvedKubeconfig = (Resolve-Path -LiteralPath $KubeconfigPath).ProviderPath
} elseif ($kubeconfigModeRequested) {
    $candidate = if ($env:KUBECONFIG) { $env:KUBECONFIG } else { Join-Path $HOME '.kube' 'config' }
    if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
        throw (Format-FindingErrorMessage (New-FindingError -Source 'wrapper:falco' -Category 'NotFound' -Reason "Invalid kubeconfig: -KubeContext was supplied but no kubeconfig found at '$(Remove-Credentials -Text $candidate)'. Set -KubeconfigPath or `$env:KUBECONFIG." -Remediation 'Set -KubeconfigPath or ensure $env:KUBECONFIG points to an existing kubeconfig file.'))
    }
    $resolvedKubeconfig = (Resolve-Path -LiteralPath $candidate).ProviderPath
}

$installKubeconfigMode = $InstallFalco -and $kubeconfigModeRequested

if (-not $installKubeconfigMode) {
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
}

$clusters = @()
if ($installKubeconfigMode) {
    $synthName = if ($KubeContext) { $KubeContext } else { 'kubeconfig-default' }
    $clusters += [pscustomobject]@{
        id              = "kubeconfig:$synthName"
        resourceGroup   = ''
        name            = $synthName
        kubeconfigPath  = $resolvedKubeconfig
        kubeContext     = $KubeContext
    }
} elseif ($ClusterArmIds -and $ClusterArmIds.Count -gt 0) {
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
        $result.Message = "AKS discovery failed: $(Remove-Credentials -Text ([string]$_.Exception.Message))"
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

function New-FalcoRuleId {
    param([string]$RuleName)
    if ([string]::IsNullOrWhiteSpace($RuleName)) { return 'falco:runtime-alert' }
    $slug = ($RuleName.ToLowerInvariant() -replace '[^a-z0-9]+', '-').Trim('-')
    if ([string]::IsNullOrWhiteSpace($slug)) { $slug = 'runtime-alert' }
    return "falco:$slug"
}

function Get-FalcoMitreMapping {
    param(
        [string]$RuleName,
        [string]$Priority,
        [string]$Detail
    )
    $text = "$RuleName $Detail".ToLowerInvariant()
    if ($text -match 'shell|exec') {
        return @{
            Tactics    = @('Execution')
            Techniques = @('T1059')
        }
    }
    if ($text -match 'capabilit|privilege|root|escalat') {
        return @{
            Tactics    = @('PrivilegeEscalation')
            Techniques = @('T1068')
        }
    }
    if ($text -match 'write|modify|executable|binary|filesystem') {
        return @{
            Tactics    = @('DefenseEvasion')
            Techniques = @('T1070')
        }
    }

    $p = ($Priority ?? '').ToLowerInvariant()
    if ($p -eq 'critical' -or $p -eq 'error') {
        return @{
            Tactics    = @('Execution')
            Techniques = @('T1059')
        }
    }
    return @{
        Tactics    = @()
        Techniques = @()
    }
}

function Get-FalcoFrameworks {
    param(
        [string]$RuleId,
        [string]$RuleName
    )
    if ([string]::IsNullOrWhiteSpace($RuleName)) { return @() }
    return @(
        @{
            Name      = 'CIS Kubernetes Benchmark'
            ControlId = $RuleId
            Controls  = @($RuleId)
        }
    )
}

function Get-FalcoImpact {
    param([string]$Severity)
    switch ($Severity) {
        'Critical' { return 'High' }
        'High'     { return 'High' }
        'Medium'   { return 'Medium' }
        'Low'      { return 'Low' }
        default    { return 'Low' }
    }
}

function Get-FalcoEffort {
    param([string]$Severity)
    switch ($Severity) {
        'Critical' { return 'Medium' }
        'High'     { return 'Medium' }
        'Medium'   { return 'Low' }
        'Low'      { return 'Low' }
        default    { return 'Low' }
    }
}

function Get-FalcoToolVersion {
    $fallback = 'falco-alert-pipeline'
    if (-not (Get-Command falco -ErrorAction SilentlyContinue)) { return $fallback }
    try {
        $raw = @(& falco --version 2>$null) -join ' '
        if ([string]::IsNullOrWhiteSpace($raw)) { return $fallback }
        return (($raw -replace '\s+', ' ').Trim())
    } catch {
        return $fallback
    }
}

$falcoToolVersion = Get-FalcoToolVersion
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
        $result.Message = "Falco query mode failed: $(Remove-Credentials -Text ([string]$_.Exception.Message))"
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
        $ruleId = New-FalcoRuleId -RuleName $rule
        $impact = Get-FalcoImpact -Severity $sev
        $effort = Get-FalcoEffort -Severity $sev
        $mitre = Get-FalcoMitreMapping -RuleName $rule -Priority $priority -Detail ([string]$a.description)
        $frameworks = Get-FalcoFrameworks -RuleId $ruleId -RuleName $rule
        $ruleDisplay = if ($rule) { $rule } else { [string]$a.alertName }
        if (-not $ruleDisplay) { $ruleDisplay = 'Falco runtime alert' }
        $deepLinkUrl = if ($a.id) { "https://portal.azure.com/#view/Microsoft_Azure_Security/SecurityMenuBlade/~/6/id/$([uri]::EscapeDataString([string]$a.id))" } else { '' }
        $evidenceUris = @()
        if ($a.id) { $evidenceUris += [string]$a.id }
        if ($deepLinkUrl) { $evidenceUris += $deepLinkUrl }
        if (-not [string]::IsNullOrWhiteSpace([string]$rid)) { $evidenceUris += [string]$rid }

        $findings.Add([pscustomobject]@{
            Id          = if ($a.id) { "falco/$($a.id)" } else { "falco/$([guid]::NewGuid())" }
            Source      = 'falco'
            Category    = 'KubernetesRuntimeThreatDetection'
            RuleId      = $ruleId
            Severity    = $sev
            Priority    = $priority
            Compliant   = $false
            Title       = "Falco: $ruleDisplay"
            Detail      = Remove-Credentials ([string]$a.description)
            Remediation = 'Investigate Falco runtime behavior and validate if process/pod activity is expected.'
            ResourceId  = $rid
            RuleName    = $rule
            Pod         = $pod
            Process     = $proc
            LearnMoreUrl = 'https://falco.org/docs/'
            Frameworks  = @($frameworks)
            Pillar      = 'Security'
            Impact      = $impact
            Effort      = $effort
            DeepLinkUrl = $deepLinkUrl
            RemediationSnippets = @(@{
                    language = 'text'
                    code     = 'Investigate container activity, validate expected process behavior, and tighten pod security controls.'
                })
            EvidenceUris = @($evidenceUris)
            BaselineTags = @('falco', 'aks-runtime-threat', $ruleId)
            MitreTactics = @($mitre.Tactics)
            MitreTechniques = @($mitre.Techniques)
            EntityRefs   = @([string]$rid)
            ToolVersion  = $falcoToolVersion
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
if (-not $installKubeconfigMode -and -not (Get-Command az -ErrorAction SilentlyContinue)) {
    $result.Status = 'Skipped'
    $result.Message = 'Install mode requested but az CLI is not installed (skip by passing -KubeconfigPath).'
    return [pscustomobject]$result
}

$captureMinutes = $CaptureMinutes
$scanned = 0
$failed = 0
foreach ($cluster in $clusters) {
    $isKubeconfigMode = $false
    if ($cluster.PSObject.Properties['kubeconfigPath'] -and $cluster.kubeconfigPath) {
        $isKubeconfigMode = $true
    }

    if (-not $isKubeconfigMode) {
        # Defense-in-depth: reject resources whose names contain shell metacharacters.
        if ($cluster.resourceGroup -notmatch '^[A-Za-z0-9._()-]{1,90}$' -or
            $cluster.name          -notmatch '^[A-Za-z0-9-]{1,63}$') {
            Write-Warning "Skipping cluster with unsafe name/resourceGroup: $($cluster.name) in $($cluster.resourceGroup)"
            $failed++
            continue
        }
    }

    if ($isKubeconfigMode) {
        $tmpKubeconfig = $cluster.kubeconfigPath
        $ctx           = $cluster.kubeContext
    } else {
        $ctx = "falco-$($cluster.name)-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        $tmpKubeconfig = Join-Path ([System.IO.Path]::GetTempPath()) "kubeconfig-$ctx.yaml"
    }
    $authPrep = $null
    try {
        if (-not $PSCmdlet.ShouldProcess([string]$cluster.name, 'Install Falco via Helm and collect daemonset logs')) {
            continue
        }

        if (-not $isKubeconfigMode) {
            & az aks get-credentials --subscription $SubscriptionId --resource-group $cluster.resourceGroup --name $cluster.name --file $tmpKubeconfig --context $ctx --overwrite-existing --only-show-errors 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0) { $failed++; continue }
        }

        $env:KUBECONFIG = $tmpKubeconfig

        $authPrep = $null
        if ($KubeAuthMode -ne 'Default') {
            $kubeconfigOwned = -not $isKubeconfigMode
            $authPrep = Initialize-KubeAuth `
                -Mode $KubeAuthMode `
                -KubeconfigPath $tmpKubeconfig `
                -KubeconfigOwned:$kubeconfigOwned `
                -KubeContext $ctx `
                -KubeloginServerId $KubeloginServerId `
                -KubeloginClientId $KubeloginClientId `
                -KubeloginTenantId $KubeloginTenantId `
                -WorkloadIdentityClientId $WorkloadIdentityClientId `
                -WorkloadIdentityTenantId $WorkloadIdentityTenantId `
                -WorkloadIdentityServiceAccountToken $WorkloadIdentityServiceAccountToken
            $env:KUBECONFIG = $authPrep.KubeconfigPath
        }

        & helm repo add falcosecurity https://falcosecurity.github.io/charts 2>&1 | Out-Null
        & helm repo update 2>&1 | Out-Null
        $helmArgs = @('upgrade', '--install', 'falco', 'falcosecurity/falco',
                      '--namespace', $Namespace, '--create-namespace',
                      '--wait', '--timeout', '5m')
        if ($ctx) { $helmArgs += @('--kube-context', $ctx) }
        & helm @helmArgs 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { $failed++; continue }

        Start-Sleep -Seconds ($captureMinutes * 60)
        $logArgs = @()
        if ($ctx) { $logArgs += @('--context', $ctx) }
        $logArgs += @('-n', $Namespace, 'logs', 'daemonset/falco', '--since', "$($captureMinutes)m", '--tail', '5000')
        $rawLogs = @(& kubectl @logArgs 2>&1)
        if ($LASTEXITCODE -ne 0) {
            $failed++
            Write-Warning "Falco log collection failed for cluster $($cluster.name): $(Remove-Credentials -Text ([string]($rawLogs -join ' ')))"
            continue
        }
        foreach ($line in @($rawLogs)) {
            if (-not $line) { continue }
            $priority = Get-MatchValue -Text $line -Pattern '(?i)"priority"\s*:\s*"([^"]+)"'
            if (-not $priority) { continue }
            $rule = Get-MatchValue -Text $line -Pattern '(?i)"rule"\s*:\s*"([^"]+)"'
            $pod = Get-MatchValue -Text $line -Pattern '(?i)"k8s\.pod\.name"\s*:\s*"([^"]+)"'
            $proc = Get-MatchValue -Text $line -Pattern '(?i)"proc\.name"\s*:\s*"([^"]+)"'
            $sev = Convert-PriorityToSeverity -Priority $priority
            $ruleId = New-FalcoRuleId -RuleName $rule
            $impact = Get-FalcoImpact -Severity $sev
            $effort = Get-FalcoEffort -Severity $sev
            $mitre = Get-FalcoMitreMapping -RuleName $rule -Priority $priority -Detail ([string]$line)
            $frameworks = Get-FalcoFrameworks -RuleId $ruleId -RuleName $rule
            $deepLinkUrl = if ($cluster.id) { "https://portal.azure.com/#@/resource$([string]$cluster.id)" } else { '' }
            $evidenceUris = @()
            if ($deepLinkUrl) { $evidenceUris += $deepLinkUrl }
            if (-not [string]::IsNullOrWhiteSpace([string]$cluster.id)) { $evidenceUris += [string]$cluster.id }

            $findings.Add([pscustomobject]@{
                Id          = "falco/$($cluster.id)/$([guid]::NewGuid())"
                Source      = 'falco'
                Category    = 'KubernetesRuntimeThreatDetection'
                RuleId      = $ruleId
                Severity    = $sev
                Priority    = $priority
                Compliant   = $false
                Title       = if ($rule) { "Falco: $rule" } else { 'Falco runtime alert' }
                Detail      = Remove-Credentials ([string]$line)
                Remediation = 'Investigate Falco runtime behavior and validate if process/pod activity is expected.'
                ResourceId  = [string]$cluster.id
                RuleName    = $rule
                Pod         = $pod
                Process     = $proc
                LearnMoreUrl = 'https://falco.org/docs/'
                Frameworks  = @($frameworks)
                Pillar      = 'Security'
                Impact      = $impact
                Effort      = $effort
                DeepLinkUrl = $deepLinkUrl
                RemediationSnippets = @(@{
                        language = 'text'
                        code     = 'Investigate container activity, validate expected process behavior, and tighten pod security controls.'
                    })
                EvidenceUris = @($evidenceUris)
                BaselineTags = @('falco', 'aks-runtime-threat', $ruleId)
                MitreTactics = @($mitre.Tactics)
                MitreTechniques = @($mitre.Techniques)
                EntityRefs   = @([string]$cluster.id)
                ToolVersion  = $falcoToolVersion
            }) | Out-Null
        }

        if ($UninstallFalco) {
            if ($PSCmdlet.ShouldProcess([string]$cluster.name, 'Uninstall Falco Helm release')) {
                $uninstallArgs = @('uninstall', 'falco', '-n', $Namespace)
                if ($ctx) { $uninstallArgs += @('--kube-context', $ctx) }
                & helm @uninstallArgs 2>&1 | Out-Null
            }
        }
        $scanned++
    } catch {
        $failed++
        Write-Warning "Falco install mode failed for cluster $($cluster.name): $(Remove-Credentials -Text ([string]$_.Exception.Message))"
    } finally {
        if ($authPrep -and $authPrep.Cleanup) {
            try { & $authPrep.Cleanup } catch {}
        }
        if ($env:KUBECONFIG) { Remove-Item Env:\KUBECONFIG -ErrorAction SilentlyContinue }
        if (-not $isKubeconfigMode -and $tmpKubeconfig -and (Test-Path $tmpKubeconfig)) {
            try { Remove-Item $tmpKubeconfig -Force -ErrorAction SilentlyContinue } catch {}
        }
    }
}

$result.Findings = @($findings)
$result.Message  = "Install mode: scanned $scanned AKS cluster(s); $failed failed; emitted $($findings.Count) Falco alert finding(s)."
if ($scanned -eq 0 -and $failed -gt 0) {
    $result.Status = 'Failed'
} elseif ($scanned -gt 0 -and $failed -gt 0) {
    $result.Status = 'PartialSuccess'
}

return [pscustomobject]$result
