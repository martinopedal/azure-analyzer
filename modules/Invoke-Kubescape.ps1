#requires -Version 7.0
<#
.SYNOPSIS
    Wrapper for kubescape - Kubernetes posture scanning against CIS K8s Benchmark + NSA/CISA hardening.

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

.PARAMETER KubeconfigPath
    Optional path to an existing kubeconfig file. When provided, the wrapper
    skips Azure Resource Graph discovery and `az aks get-credentials`, and
    runs a single kubescape scan against the cluster reachable via this
    kubeconfig (kubeconfig mode). Defaults: $env:KUBECONFIG, then
    $HOME/.kube/config when -KubeContext is supplied without a path.
    The file MUST exist when set explicitly; URLs are rejected.

.PARAMETER KubeContext
    Optional kubeconfig context name. In kubeconfig mode passed to
    kubescape via `--kube-context`. In AKS-discovery mode ignored
    (per-cluster contexts are generated automatically).

.PARAMETER Namespace
    Optional namespace filter forwarded to kubescape via
    `--include-namespaces`. Default empty (scan all namespaces).

.PARAMETER KubeAuthMode
    Auth mode applied to the kubeconfig before each scan. One of:
      Default          - use whatever the kubeconfig already provides (current behavior).
      Kubelogin        - run `kubelogin convert-kubeconfig` (azurecli flow by
                         default, spn when -KubeloginClientId/-KubeloginTenantId
                         are supplied) so AAD-integrated AKS clusters work.
      WorkloadIdentity - federated identity. Sets AZURE_CLIENT_ID /
                         AZURE_TENANT_ID / AZURE_FEDERATED_TOKEN_FILE in
                         process scope and converts the kubeconfig to use
                         `-l workloadidentity`. Designed for in-cluster runs;
                         locally, supply -WorkloadIdentityServiceAccountToken
                         as a path to a federated token file.

.PARAMETER KubeloginServerId
    AAD server (audience) ID for the AKS API. Optional; defaults inferred by kubelogin.

.PARAMETER KubeloginClientId
    AAD client ID for the kubelogin spn flow. Pass with -KubeloginTenantId.

.PARAMETER KubeloginTenantId
    AAD tenant ID for the kubelogin spn flow. Pass with -KubeloginClientId.

.PARAMETER WorkloadIdentityClientId
    AAD client ID of the federated workload identity. GUID. Required for WorkloadIdentity mode.

.PARAMETER WorkloadIdentityTenantId
    AAD tenant ID for the federated workload identity. GUID. Required for WorkloadIdentity mode.

.PARAMETER WorkloadIdentityServiceAccountToken
    Either the path to a federated token file (`/var/run/secrets/azure/tokens/azure-identity-token`
    in pod) or the literal token value (will be written to a temp file with
    restrictive ACLs and cleaned up).
#>
[CmdletBinding()]
param (
    [Parameter(Mandatory)] [string] $SubscriptionId,
    [string[]] $ClusterArmIds,
    [string] $OutputPath,
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

$kubeAuthPath = Join-Path $PSScriptRoot 'shared' 'KubeAuth.ps1'
if (Test-Path $kubeAuthPath) { . $kubeAuthPath }
$aksDiscoveryPath = Join-Path $PSScriptRoot 'shared' 'AksDiscovery.ps1'
if (Test-Path $aksDiscoveryPath) { . $aksDiscoveryPath }

$result = [ordered]@{
    SchemaVersion = '1.0'
    Source        = 'kubescape'
    Status        = 'Success'
    Message       = ''
    Findings      = @()
    Subscription  = $SubscriptionId
    Timestamp     = (Get-Date).ToUniversalTime().ToString('o')
}

# Determine auth mode early. Explicit -KubeconfigPath (or just -KubeContext)
# enables "kubeconfig mode" (BYO cluster, no AKS discovery / get-credentials).
$kubeconfigModeRequested = $PSBoundParameters.ContainsKey('KubeconfigPath') -or `
                           $PSBoundParameters.ContainsKey('KubeContext')

# Validate KubeAuthMode prerequisites up front so we fail fast before any
# per-cluster work is attempted. Default mode is a no-op.
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
        throw "Invalid -KubeconfigPath: value is empty."
    }
    if ($KubeconfigPath -match '^[a-z][a-z0-9+.-]*://') {
        throw "Invalid -KubeconfigPath '$(Remove-Credentials -Text $KubeconfigPath)': URLs are not accepted; provide a local file path."
    }
    if (-not (Test-Path -LiteralPath $KubeconfigPath -PathType Leaf)) {
        throw "Invalid -KubeconfigPath '$(Remove-Credentials -Text $KubeconfigPath)': file does not exist."
    }
    $resolvedKubeconfig = (Resolve-Path -LiteralPath $KubeconfigPath).ProviderPath
} elseif ($kubeconfigModeRequested) {
    # -KubeContext supplied but no -KubeconfigPath: fall back to env / default.
    $candidate = if ($env:KUBECONFIG) { $env:KUBECONFIG } else { Join-Path $HOME '.kube' 'config' }
    if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
        throw "Invalid kubeconfig: -KubeContext was supplied but no kubeconfig found at '$(Remove-Credentials -Text $candidate)'. Set -KubeconfigPath or `$env:KUBECONFIG."
    }
    $resolvedKubeconfig = (Resolve-Path -LiteralPath $candidate).ProviderPath
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
if (-not $kubeconfigModeRequested -and -not (Get-Command az -ErrorAction SilentlyContinue)) {
    $result.Status  = 'Skipped'
    $result.Message = 'az CLI not installed. Required to populate AKS kubeconfig context (skip by passing -KubeconfigPath).'
    return [pscustomobject]$result
}

# --- Discover AKS clusters via ARG (unless explicit list provided, or kubeconfig mode) ---
$clusters = @()
if ($kubeconfigModeRequested) {
    # Synthetic single "cluster" backed by the user-supplied kubeconfig.
    $synthName = if ($KubeContext) { $KubeContext } else { 'kubeconfig-default' }
    $synthId   = "kubeconfig:$synthName"
    $clusters += [pscustomobject]@{
        id              = $synthId
        resourceGroup   = ''
        name            = $synthName
        kubeconfigPath  = $resolvedKubeconfig
        kubeContext     = $KubeContext
        kubeconfigOwned = $false   # do NOT delete user-supplied kubeconfig
    }
} elseif ($ClusterArmIds -and $ClusterArmIds.Count -gt 0) {
    try {
        $clusters = @(Get-AksClustersInScope -SubscriptionId $SubscriptionId -ClusterArmIds $ClusterArmIds)
    } catch {
        $result.Status  = 'Failed'
        $result.Message = "ARG discovery failed: $(Remove-Credentials -Text ([string]$_.Exception.Message))"
        return [pscustomobject]$result
    }
} else {
    try {
        $clusters = @(Get-AksClustersInScope -SubscriptionId $SubscriptionId)
    } catch {
        $result.Status  = 'Failed'
        $result.Message = "ARG discovery failed: $(Remove-Credentials -Text ([string]$_.Exception.Message))"
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
    $isKubeconfigMode = $false
    if ($cluster.PSObject.Properties['kubeconfigPath'] -and $cluster.kubeconfigPath) {
        $isKubeconfigMode = $true
    }
    $contextForScan = $null
    $tmpKubeconfig  = $null
    if ($isKubeconfigMode) {
        $tmpKubeconfig  = $cluster.kubeconfigPath
        $contextForScan = $cluster.kubeContext
    } else {
        $context = "ks-$($cluster.name)-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        $contextForScan = $context
    }
    $authPrep = $null
    try {
        if (-not $isKubeconfigMode) {
            # Isolated kubeconfig context per cluster - avoid cross-cluster pollution.
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
        }

        $rawFile = if ($OutputPath) {
            Join-Path $OutputPath "kubescape-$($cluster.name)-$(Get-Date -Format yyyyMMddHHmmss).json"
        } else {
            Join-Path ([System.IO.Path]::GetTempPath()) "kubescape-$([guid]::NewGuid().ToString('N').Substring(0,8)).json"
        }

        $env:KUBECONFIG = $tmpKubeconfig

        # Apply KubeAuthMode (kubelogin convert / workload identity env vars)
        # AFTER the kubeconfig is materialized but BEFORE we hand it to
        # kubescape. The helper copies the kubeconfig when it is BYO so we
        # never mutate the user's file. In wrapper-owned mode (az aks
        # get-credentials temp), we convert in place.
        if ($KubeAuthMode -ne 'Default') {
            $kubeconfigOwned = -not $isKubeconfigMode
            $authPrep = Initialize-KubeAuth `
                -Mode $KubeAuthMode `
                -KubeconfigPath $tmpKubeconfig `
                -KubeconfigOwned:$kubeconfigOwned `
                -KubeContext $contextForScan `
                -KubeloginServerId $KubeloginServerId `
                -KubeloginClientId $KubeloginClientId `
                -KubeloginTenantId $KubeloginTenantId `
                -WorkloadIdentityClientId $WorkloadIdentityClientId `
                -WorkloadIdentityTenantId $WorkloadIdentityTenantId `
                -WorkloadIdentityServiceAccountToken $WorkloadIdentityServiceAccountToken
            $env:KUBECONFIG = $authPrep.KubeconfigPath
        }

        $ksArgs = @('scan', '--format', 'json', '--output', $rawFile, '--format-version', 'v2')
        if ($contextForScan) { $ksArgs += @('--kube-context', $contextForScan) }
        if ($Namespace)      { $ksArgs += @('--include-namespaces', $Namespace) }
        & kubescape @ksArgs 2>&1 | Out-Null
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
        Write-Warning "kubescape scan failed for cluster $($cluster.name): $(Remove-Credentials -Text ([string]$_.Exception.Message))"
    } finally {
        # Remove the isolated kubeconfig to avoid leaking cluster auth.
        # In kubeconfig mode the path was supplied by the caller; do not delete it.
        if ($authPrep -and $authPrep.Cleanup) {
            try { & $authPrep.Cleanup } catch {}
        }
        if (-not $isKubeconfigMode -and $tmpKubeconfig -and (Test-Path $tmpKubeconfig)) {
            try { Remove-Item $tmpKubeconfig -Force -ErrorAction SilentlyContinue } catch {}
        }
        if ($env:KUBECONFIG) { Remove-Item Env:\KUBECONFIG -ErrorAction SilentlyContinue }
    }
}

$result.Findings = @($findings)
$result.Message  = "Scanned $scanned AKS cluster(s); $failed failed; emitted $($findings.Count) non-passing control findings."
if ($scanned -eq 0 -and $failed -gt 0) {
    $result.Status = 'Failed'
} elseif ($scanned -gt 0 -and $failed -gt 0) {
    $result.Status = 'PartialSuccess'
}

return [pscustomobject]$result
