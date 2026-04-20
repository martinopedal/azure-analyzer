#requires -Version 7.0
<#
.SYNOPSIS
    Wrapper for kube-bench — node-level CIS checks on AKS worker nodes.

.DESCRIPTION
    Discovers AKS managed clusters in scope via Azure Resource Graph (or accepts
    explicit -ClusterArmIds), creates an isolated kubeconfig per cluster, applies a
    temporary kube-bench Job in kube-system, collects logs, and maps FAIL/WARN
    checks to v1 findings that fold onto the AKS cluster ARM resource ID.

    Job resources and temporary kubeconfig/manifest files are always cleaned up.

.PARAMETER KubeconfigPath
    Optional path to an existing kubeconfig file. When provided, skips
    Azure Resource Graph discovery and `az aks get-credentials`, and
    runs a single kube-bench Job against the cluster reachable via this
    kubeconfig. The file MUST exist when set explicitly; URLs are rejected.

.PARAMETER KubeContext
    Optional kubeconfig context name passed to `kubectl --context`.

.PARAMETER Namespace
    Namespace where the temporary kube-bench Job is created and logs
    are collected from. Default 'kube-system'.
#>
[CmdletBinding()]
param (
    [Parameter(Mandatory)] [string] $SubscriptionId,
    [string[]] $ClusterArmIds,
    [string] $OutputPath,
    [ValidateRange(60, 3600)]
    [int] $JobTimeoutSeconds = 600,
    [string] $KubeBenchImage = 'aquasec/kube-bench:v0.7.2',
    [string] $KubeconfigPath,
    [string] $KubeContext,
    [string] $Namespace = 'kube-system'
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

function ConvertFrom-KubeBenchLogJson {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    try { return ($Text | ConvertFrom-Json -Depth 40 -ErrorAction Stop) } catch {}
    $start = $Text.IndexOf('{')
    $end = $Text.LastIndexOf('}')
    if ($start -lt 0 -or $end -le $start) { return $null }
    try { return ($Text.Substring($start, ($end - $start + 1)) | ConvertFrom-Json -Depth 40 -ErrorAction Stop) } catch {}
    return $null
}

function Get-KubeBenchFailedChecks {
    param([object]$Report)
    $items = [System.Collections.Generic.List[object]]::new()
    if (-not $Report) { return @($items) }

    $controls = @()
    if ($Report.PSObject.Properties['Controls']) { $controls = @($Report.Controls) }
    elseif ($Report.PSObject.Properties['controls']) { $controls = @($Report.controls) }

    foreach ($control in $controls) {
        $tests = @()
        if ($control -and $control.PSObject.Properties['tests']) { $tests = @($control.tests) }
        foreach ($test in $tests) {
            $results = @()
            if ($test -and $test.PSObject.Properties['results']) { $results = @($test.results) }
            foreach ($r in $results) {
                $status = if ($r.PSObject.Properties['status']) { [string]$r.status } else { '' }
                if ($status -notmatch '^(?i)(FAIL|WARN)$') { continue }

                $testNumber = if ($r.PSObject.Properties['test_number']) { [string]$r.test_number } else { '' }
                $testDesc = if ($r.PSObject.Properties['test_desc']) { [string]$r.test_desc } else { '' }
                $section = if ($test.PSObject.Properties['section']) { [string]$test.section } else { '' }
                $remediation = if ($r.PSObject.Properties['remediation']) { [string]$r.remediation } else { '' }
                $audit = if ($r.PSObject.Properties['audit']) { [string]$r.audit } else { '' }

                $controlId = if ($testNumber) { $testNumber } elseif ($section) { $section } else { [guid]::NewGuid().ToString() }
                $title = if ($testNumber -and $testDesc) { "${testNumber}: $testDesc" } elseif ($testDesc) { $testDesc } else { "kube-bench check $controlId" }
                $detail = if ($audit) { "kube-bench $status check. section=$section; audit=$audit" } else { "kube-bench $status check. section=$section" }
                $severity = if ($status -match '^(?i)FAIL$') { 'High' } else { 'Medium' }

                $items.Add([pscustomobject]@{
                    ControlId    = $controlId
                    Title        = $title
                    Status       = $status.ToUpperInvariant()
                    Severity     = $severity
                    Detail       = $detail
                    Remediation  = $remediation
                }) | Out-Null
            }
        }
    }

    return @($items)
}

function Get-ShortSha256 {
    param([Parameter(Mandatory)][string]$InputText)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($InputText)
        $hash = $sha.ComputeHash($bytes)
        return ([System.BitConverter]::ToString($hash) -replace '-', '').Substring(0, 12).ToLowerInvariant()
    } finally {
        $sha.Dispose()
    }
}

$result = [ordered]@{
    SchemaVersion = '1.0'
    Source        = 'kube-bench'
    Status        = 'Success'
    Message       = ''
    Findings      = @()
    Subscription  = $SubscriptionId
    Timestamp     = (Get-Date).ToUniversalTime().ToString('o')
}

if (-not (Get-Command kubectl -ErrorAction SilentlyContinue)) {
    $result.Status  = 'Skipped'
    $result.Message = 'kubectl not installed. kube-bench runtime job requires kubectl to access AKS.'
    return [pscustomobject]$result
}

$kubeconfigModeRequested = $PSBoundParameters.ContainsKey('KubeconfigPath') -or `
                           $PSBoundParameters.ContainsKey('KubeContext')
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
    $candidate = if ($env:KUBECONFIG) { $env:KUBECONFIG } else { Join-Path $HOME '.kube' 'config' }
    if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
        throw "Invalid kubeconfig: -KubeContext was supplied but no kubeconfig found at '$(Remove-Credentials -Text $candidate)'. Set -KubeconfigPath or `$env:KUBECONFIG."
    }
    $resolvedKubeconfig = (Resolve-Path -LiteralPath $candidate).ProviderPath
}

if (-not $kubeconfigModeRequested -and -not (Get-Command az -ErrorAction SilentlyContinue)) {
    $result.Status  = 'Skipped'
    $result.Message = 'az CLI not installed. Required to populate AKS kubeconfig context (skip by passing -KubeconfigPath).'
    return [pscustomobject]$result
}

$clusters = @()
if ($kubeconfigModeRequested) {
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
        $result.Message = "ARG discovery failed: $(Remove-Credentials -Text ([string]$_.Exception.Message))"
        return [pscustomobject]$result
    }
}

if (-not $clusters -or @($clusters).Count -eq 0) {
    $result.Status  = 'Skipped'
    $result.Message = 'No AKS managed clusters in scope.'
    return [pscustomobject]$result
}

if ($OutputPath -and -not (Test-Path $OutputPath)) {
    try { New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null } catch {}
}

$findings = [System.Collections.Generic.List[object]]::new()
$scanned  = 0
$failed   = 0

foreach ($cluster in $clusters) {
    $isKubeconfigMode = $false
    if ($cluster.PSObject.Properties['kubeconfigPath'] -and $cluster.kubeconfigPath) {
        $isKubeconfigMode = $true
    }

    if (-not $isKubeconfigMode) {
        # Defense-in-depth: reject resources whose names contain shell metacharacters.
        # Azure RG names allow [A-Za-z0-9._()-]; AKS cluster names allow [A-Za-z0-9-].
        if ($cluster.resourceGroup -notmatch '^[A-Za-z0-9._()-]{1,90}$' -or
            $cluster.name          -notmatch '^[A-Za-z0-9-]{1,63}$') {
            Write-Warning "Skipping cluster with unsafe name/resourceGroup: $($cluster.name) in $($cluster.resourceGroup)"
            $failed++
            continue
        }
    }

    if ($isKubeconfigMode) {
        $context       = $cluster.kubeContext
        $tmpKubeconfig = $cluster.kubeconfigPath
    } else {
        $context = "kb-$($cluster.name)-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        $tmpKubeconfig = $null
    }
    $jobManifest = $null
    $jobName = "aa-kube-bench-$([guid]::NewGuid().ToString('N').Substring(0,8))"
    $jobApplied = $false
    $rawLogsPath = $null

    try {
        if (-not $isKubeconfigMode) {
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

        $jobManifest = Join-Path ([System.IO.Path]::GetTempPath()) "kube-bench-$jobName-job.yaml"
        @"
apiVersion: batch/v1
kind: Job
metadata:
  name: $jobName
  namespace: $Namespace
spec:
  backoffLimit: 0
  template:
    spec:
      restartPolicy: Never
      hostPID: true
      containers:
      - name: kube-bench
        image: $KubeBenchImage
        command: ["kube-bench", "run", "--json"]
        volumeMounts:
        - { name: var-lib-kubelet, mountPath: /var/lib/kubelet, readOnly: true }
        - { name: etc-systemd, mountPath: /etc/systemd, readOnly: true }
        - { name: lib-systemd, mountPath: /lib/systemd, readOnly: true }
        - { name: srv-kubernetes, mountPath: /etc/kubernetes, readOnly: true }
      volumes:
      - { name: var-lib-kubelet, hostPath: { path: "/var/lib/kubelet" } }
      - { name: etc-systemd, hostPath: { path: "/etc/systemd" } }
      - { name: lib-systemd, hostPath: { path: "/lib/systemd" } }
      - { name: srv-kubernetes, hostPath: { path: "/etc/kubernetes" } }
"@ | Set-Content -Path $jobManifest -Encoding utf8

        $env:KUBECONFIG = $tmpKubeconfig

        $kctxArgs = @()
        if ($context) { $kctxArgs += @('--context', $context) }

        & kubectl @kctxArgs apply -f $jobManifest 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) {
            $failed++
            continue
        }
        $jobApplied = $true

        & kubectl @kctxArgs -n $Namespace wait --for=condition=complete "job/$jobName" --timeout="$($JobTimeoutSeconds)s" 2>&1 | Out-Null
        & kubectl @kctxArgs -n $Namespace logs "job/$jobName" 2>&1 | Set-Variable -Name kubeBenchLogs
        if ([string]::IsNullOrWhiteSpace($kubeBenchLogs)) {
            $failed++
            continue
        }

        if ($OutputPath) {
            $rawLogsPath = Join-Path $OutputPath "kube-bench-$($cluster.name)-$(Get-Date -Format yyyyMMddHHmmss).json"
            (Remove-Credentials -Text $kubeBenchLogs) | Set-Content -Path $rawLogsPath -Encoding utf8
        }

        $parsed = ConvertFrom-KubeBenchLogJson -Text $kubeBenchLogs
        if (-not $parsed) {
            $failed++
            continue
        }

        $clusterFindings = @(Get-KubeBenchFailedChecks -Report $parsed)
        $idx = 0
        $clusterKey = Get-ShortSha256 -InputText ([string]$cluster.id)
        foreach ($f in $clusterFindings) {
            $idx++
            $findings.Add([pscustomobject]@{
                Id           = "kube-bench/$clusterKey/$($f.ControlId)/$idx"
                Source       = 'kube-bench'
                Category     = 'KubernetesNodeSecurity'
                Severity     = $f.Severity
                Compliant    = $false
                Title        = $f.Title
                Detail       = "$($f.Detail) cluster=$($cluster.name)"
                Remediation  = $f.Remediation
                ResourceId   = $cluster.id
                ControlId    = $f.ControlId
                Status       = $f.Status
                LearnMoreUrl = 'https://github.com/aquasecurity/kube-bench'
            }) | Out-Null
        }

        $scanned++
    } catch {
        $failed++
        Write-Warning "kube-bench scan failed for cluster $($cluster.name): $(Remove-Credentials -Text ([string]$_.Exception.Message))"
    } finally {
        if ($jobApplied) {
            $delArgs = @()
            if ($context) { $delArgs += @('--context', $context) }
            & kubectl @delArgs -n $Namespace delete "job/$jobName" --ignore-not-found=true 2>&1 | Out-Null
        }
        if ($jobManifest -and (Test-Path $jobManifest)) {
            try { Remove-Item $jobManifest -Force -ErrorAction SilentlyContinue } catch {}
        }
        if (-not $isKubeconfigMode -and $tmpKubeconfig -and (Test-Path $tmpKubeconfig)) {
            try { Remove-Item $tmpKubeconfig -Force -ErrorAction SilentlyContinue } catch {}
        }
        if ($env:KUBECONFIG) { Remove-Item Env:\KUBECONFIG -ErrorAction SilentlyContinue }
    }
}

$result.Findings = @($findings)
$result.Message = "Scanned $scanned AKS cluster(s); $failed failed; emitted $($findings.Count) kube-bench FAIL/WARN finding(s)."
if ($scanned -eq 0 -and $failed -gt 0) {
    $result.Status = 'Failed'
} elseif ($scanned -gt 0 -and $failed -gt 0) {
    $result.Status = 'PartialSuccess'
}

return [pscustomobject]$result
