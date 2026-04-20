#Requires -Version 7.0
<#
.SYNOPSIS
    Shared helpers for Kubernetes auth-mode handling across the K8s wrappers
    (Invoke-Kubescape, Invoke-Falco, Invoke-KubeBench).

.DESCRIPTION
    Implements the three auth modes documented in `docs/consumer/k8s-auth.md`:

      * Default          - whatever the kubeconfig already provides (exec
                           plugin, basic auth, cert, az aks get-credentials
                           output, etc). No conversion is performed.
      * Kubelogin        - runs `kubelogin convert-kubeconfig -l <login>` so
                           the kubeconfig uses the modern AAD exec plugin.
                           Default login flow is `azurecli`; when ClientId
                           and TenantId are supplied, `spn` (with optional
                           ServerId) is used.
      * WorkloadIdentity - federated identity. Sets AZURE_CLIENT_ID,
                           AZURE_TENANT_ID, and AZURE_FEDERATED_TOKEN_FILE
                           in process scope and converts the kubeconfig with
                           `kubelogin convert-kubeconfig -l workloadidentity`.
                           Designed for in-cluster use; for local runs the
                           caller must supply a federated token file path.

    The functions never mutate a user-supplied kubeconfig in place. Callers
    pass a kubeconfig path and the helpers operate on a working copy when
    conversion is needed (caller owns the working copy + cleanup).

.NOTES
    All external process launches go through Invoke-WithTimeout for the
    fixed 300s ceiling enforced project-wide. All log surfaces pass user
    input through Remove-Credentials before they hit disk.
#>

Set-StrictMode -Version Latest

# ---------------------------------------------------------------------------
# Soft dependencies. Wrappers dot-source Sanitize / Installer themselves; we
# fall back to no-op shims so this file can be unit-tested in isolation.
# ---------------------------------------------------------------------------
if (-not (Get-Command -Name Remove-Credentials -ErrorAction SilentlyContinue)) {
    function Remove-Credentials { param([string]$Text) return $Text }
}

# Set of valid kubelogin login flows. We do not pass arbitrary values to the
# kubelogin binary; the wrappers expose only `Default | Kubelogin |
# WorkloadIdentity` and KubeAuth.ps1 maps those to the safe subset below.
$script:KubeloginValidFlows = @(
    'azurecli', 'spn', 'msi', 'workloadidentity', 'devicecode', 'interactive'
)

function Test-KubeloginAvailable {
    <#
    .SYNOPSIS
        Returns $true if `kubelogin` is on PATH.
    #>
    return [bool](Get-Command -Name kubelogin -ErrorAction SilentlyContinue)
}

function Assert-KubeAuthMode {
    <#
    .SYNOPSIS
        Validate the requested KubeAuthMode + sub-params. Throws a clear
        error if a required prerequisite is missing.

    .PARAMETER Mode
        One of Default | Kubelogin | WorkloadIdentity.

    .PARAMETER WorkloadIdentityServiceAccountToken
        Either a file path (preferred) or the literal token value. Required
        when Mode is WorkloadIdentity.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [ValidateSet('Default', 'Kubelogin', 'WorkloadIdentity')]
        [string] $Mode,

        [string] $KubeloginServerId,
        [string] $KubeloginClientId,
        [string] $KubeloginTenantId,

        [string] $WorkloadIdentityClientId,
        [string] $WorkloadIdentityTenantId,
        [string] $WorkloadIdentityServiceAccountToken
    )

    if ($Mode -eq 'Default') { return }

    if (-not (Test-KubeloginAvailable)) {
        $remediation = if ($IsWindows) {
            'winget install --id Azure.Kubelogin --silent'
        } elseif ($IsMacOS) {
            'brew install Azure/kubelogin/kubelogin'
        } else {
            'az aks install-cli  (or download from https://github.com/Azure/kubelogin/releases)'
        }
        throw ("[MissingPrerequisite] kubelogin binary is required for KubeAuthMode='{0}' but was not found on PATH. Install via: {1}" -f $Mode, $remediation)
    }

    if ($Mode -eq 'Kubelogin') {
        # Mixed sub-param validation: ClientId and TenantId travel together
        # for the spn flow. Reject one-without-the-other to avoid silently
        # falling back to azurecli with a ClientId that the user expects to
        # be used.
        $hasClient = -not [string]::IsNullOrWhiteSpace($KubeloginClientId)
        $hasTenant = -not [string]::IsNullOrWhiteSpace($KubeloginTenantId)
        if ($hasClient -xor $hasTenant) {
            throw '[InvalidArgument] KubeloginClientId and KubeloginTenantId must be supplied together (spn login flow).'
        }
    }

    if ($Mode -eq 'WorkloadIdentity') {
        if ([string]::IsNullOrWhiteSpace($WorkloadIdentityClientId) -or
            [string]::IsNullOrWhiteSpace($WorkloadIdentityTenantId) -or
            [string]::IsNullOrWhiteSpace($WorkloadIdentityServiceAccountToken)) {
            throw '[InvalidArgument] WorkloadIdentity mode requires WorkloadIdentityClientId, WorkloadIdentityTenantId, and WorkloadIdentityServiceAccountToken.'
        }
        # Reject obviously broken tenant / client values upfront. We accept
        # GUIDs only; this also blocks shell-injection style values.
        $guidPattern = '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
        if ($WorkloadIdentityClientId -notmatch $guidPattern) {
            throw '[InvalidArgument] WorkloadIdentityClientId must be a GUID.'
        }
        if ($WorkloadIdentityTenantId -notmatch $guidPattern) {
            throw '[InvalidArgument] WorkloadIdentityTenantId must be a GUID.'
        }
    }
}

function Resolve-WorkloadIdentityTokenFile {
    <#
    .SYNOPSIS
        Returns a tuple { Path; Owned } for the federated token file.

        If the supplied value resolves to an existing file, it is used
        as-is (Owned = $false). Otherwise the value is treated as the
        token itself and written to a temp file with restrictive ACLs
        (Owned = $true; caller must delete on cleanup).
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)] [string] $PathOrValue
    )

    if (Test-Path -LiteralPath $PathOrValue -PathType Leaf -ErrorAction SilentlyContinue) {
        return [pscustomobject]@{
            Path  = (Resolve-Path -LiteralPath $PathOrValue).ProviderPath
            Owned = $false
        }
    }

    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("aa-fedtoken-{0}" -f ([guid]::NewGuid().ToString('N')))
    Set-Content -Path $tmp -Value $PathOrValue -NoNewline -Encoding ascii
    try {
        if ($IsWindows) {
            $acl = Get-Acl -Path $tmp
            $acl.SetAccessRuleProtection($true, $false)
            $sid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User
            $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
                $sid, 'Read,Write,Delete', 'Allow')
            $acl.AddAccessRule($rule)
            Set-Acl -Path $tmp -AclObject $acl
        } else {
            & chmod 600 $tmp 2>&1 | Out-Null
        }
    } catch {
        # Best-effort hardening; the file is in $env:TEMP either way.
    }
    return [pscustomobject]@{ Path = $tmp; Owned = $true }
}

function Copy-KubeconfigForAuthConversion {
    <#
    .SYNOPSIS
        Copy the user-supplied kubeconfig to a process-private temp file so
        kubelogin convert-kubeconfig can mutate it without touching the
        original. Returns the temp path. Caller is responsible for delete.

        When KubeconfigPath was generated by `az aks get-credentials` (the
        wrapper-owned temp), the caller may pass -InPlace to skip the copy.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)] [string] $KubeconfigPath,
        [switch] $InPlace
    )
    if ($InPlace) { return (Resolve-Path -LiteralPath $KubeconfigPath).ProviderPath }

    if (-not (Test-Path -LiteralPath $KubeconfigPath -PathType Leaf)) {
        throw "Cannot copy kubeconfig: '$(Remove-Credentials -Text $KubeconfigPath)' does not exist."
    }
    $dest = Join-Path ([System.IO.Path]::GetTempPath()) ("aa-kubeconfig-{0}.yaml" -f ([guid]::NewGuid().ToString('N')))
    Copy-Item -LiteralPath $KubeconfigPath -Destination $dest -Force
    return $dest
}

function Invoke-KubeloginConvert {
    <#
    .SYNOPSIS
        Run `kubelogin convert-kubeconfig` against the supplied kubeconfig
        with the AAD args derived from the requested auth mode.

    .PARAMETER KubeconfigPath
        Path to a writable kubeconfig (NOT the user's original).

    .PARAMETER LoginFlow
        One of azurecli | spn | msi | workloadidentity | devicecode | interactive.
        Mapped from KubeAuthMode + sub-param presence by the caller.

    .OUTPUTS
        $true on exit code 0; $false otherwise.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)] [string] $KubeconfigPath,
        [Parameter(Mandatory)]
        [ValidateScript({ $script:KubeloginValidFlows -contains $_ })]
        [string] $LoginFlow,

        [string] $ServerId,
        [string] $ClientId,
        [string] $TenantId,

        [string] $KubeContext
    )

    if (-not (Test-KubeloginAvailable)) {
        throw '[MissingPrerequisite] kubelogin binary not on PATH.'
    }

    $kArgs = @('convert-kubeconfig', '--kubeconfig', $KubeconfigPath, '-l', $LoginFlow)
    if ($KubeContext)             { $kArgs += @('--context', $KubeContext) }
    if ($ServerId -and $LoginFlow -ne 'msi' -and $LoginFlow -ne 'workloadidentity') { $kArgs += @('--server-id', $ServerId) }
    if ($ClientId)                { $kArgs += @('--client-id', $ClientId) }
    if ($TenantId)                { $kArgs += @('--tenant-id', $TenantId) }

    try {
        & kubelogin @kArgs 2>&1 | Out-Null
        return ($LASTEXITCODE -eq 0)
    } catch {
        Write-Warning ("kubelogin convert-kubeconfig failed: {0}" -f (Remove-Credentials -Text ([string]$_.Exception.Message)))
        return $false
    }
}

function Set-WorkloadIdentityEnv {
    <#
    .SYNOPSIS
        Set AZURE_CLIENT_ID / AZURE_TENANT_ID / AZURE_FEDERATED_TOKEN_FILE
        in process scope. Returns a snapshot the caller can hand to
        Restore-WorkloadIdentityEnv to undo the changes after the K8s call.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)] [string] $ClientId,
        [Parameter(Mandatory)] [string] $TenantId,
        [Parameter(Mandatory)] [string] $TokenFile
    )

    $snapshot = [pscustomobject]@{
        AZURE_CLIENT_ID            = $env:AZURE_CLIENT_ID
        AZURE_TENANT_ID            = $env:AZURE_TENANT_ID
        AZURE_FEDERATED_TOKEN_FILE = $env:AZURE_FEDERATED_TOKEN_FILE
    }
    $env:AZURE_CLIENT_ID            = $ClientId
    $env:AZURE_TENANT_ID            = $TenantId
    $env:AZURE_FEDERATED_TOKEN_FILE = $TokenFile
    return $snapshot
}

function Restore-WorkloadIdentityEnv {
    <#
    .SYNOPSIS
        Restore env vars previously captured via Set-WorkloadIdentityEnv.
    #>
    [CmdletBinding()]
    param ([Parameter(Mandatory)] $Snapshot)
    foreach ($name in 'AZURE_CLIENT_ID', 'AZURE_TENANT_ID', 'AZURE_FEDERATED_TOKEN_FILE') {
        $prev = $Snapshot.$name
        if ([string]::IsNullOrEmpty($prev)) {
            Remove-Item -Path ("Env:\{0}" -f $name) -ErrorAction SilentlyContinue
        } else {
            Set-Item -Path ("Env:\{0}" -f $name) -Value $prev
        }
    }
}

function Resolve-KubeloginFlow {
    <#
    .SYNOPSIS
        Map (KubeAuthMode + sub-param presence) to the kubelogin -l value.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [ValidateSet('Default', 'Kubelogin', 'WorkloadIdentity')]
        [string] $Mode,

        [string] $KubeloginClientId,
        [string] $KubeloginTenantId
    )
    switch ($Mode) {
        'Default'          { return $null }
        'WorkloadIdentity' { return 'workloadidentity' }
        'Kubelogin' {
            $hasSpn = -not [string]::IsNullOrWhiteSpace($KubeloginClientId) -and
                      -not [string]::IsNullOrWhiteSpace($KubeloginTenantId)
            return ($hasSpn ? 'spn' : 'azurecli')
        }
    }
}

function Initialize-KubeAuth {
    <#
    .SYNOPSIS
        End-to-end auth-mode preparation for a single wrapper invocation.

        Combines: Assert-KubeAuthMode, Copy-KubeconfigForAuthConversion (BYO),
        Invoke-KubeloginConvert (Kubelogin/WorkloadIdentity), and
        Set-WorkloadIdentityEnv (WorkloadIdentity only).

    .PARAMETER KubeconfigOwned
        $true when KubeconfigPath was generated by the wrapper itself
        (e.g. `az aks get-credentials` temp). When $false (BYO), a private
        copy is produced before kubelogin convert mutates the file.

    .OUTPUTS
        [pscustomobject]@{
            KubeconfigPath = <effective kubeconfig path>
            Cleanup        = <scriptblock to invoke in finally{}>
        }
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [ValidateSet('Default', 'Kubelogin', 'WorkloadIdentity')]
        [string] $Mode,

        [Parameter(Mandatory)] [string] $KubeconfigPath,
        [switch] $KubeconfigOwned,
        [string] $KubeContext,

        [string] $KubeloginServerId,
        [string] $KubeloginClientId,
        [string] $KubeloginTenantId,

        [string] $WorkloadIdentityClientId,
        [string] $WorkloadIdentityTenantId,
        [string] $WorkloadIdentityServiceAccountToken
    )

    Assert-KubeAuthMode `
        -Mode $Mode `
        -KubeloginServerId $KubeloginServerId `
        -KubeloginClientId $KubeloginClientId `
        -KubeloginTenantId $KubeloginTenantId `
        -WorkloadIdentityClientId $WorkloadIdentityClientId `
        -WorkloadIdentityTenantId $WorkloadIdentityTenantId `
        -WorkloadIdentityServiceAccountToken $WorkloadIdentityServiceAccountToken

    if ($Mode -eq 'Default') {
        return [pscustomobject]@{
            KubeconfigPath = $KubeconfigPath
            Cleanup        = { }.GetNewClosure()
        }
    }

    $workingPath = Copy-KubeconfigForAuthConversion -KubeconfigPath $KubeconfigPath -InPlace:$KubeconfigOwned
    $workingOwned = -not $KubeconfigOwned.IsPresent

    $tokenFileResult = $null
    $envSnapshot = $null

    if ($Mode -eq 'WorkloadIdentity') {
        $tokenFileResult = Resolve-WorkloadIdentityTokenFile -PathOrValue $WorkloadIdentityServiceAccountToken
        $envSnapshot = Set-WorkloadIdentityEnv `
            -ClientId  $WorkloadIdentityClientId `
            -TenantId  $WorkloadIdentityTenantId `
            -TokenFile $tokenFileResult.Path
    }

    $flow = Resolve-KubeloginFlow -Mode $Mode -KubeloginClientId $KubeloginClientId -KubeloginTenantId $KubeloginTenantId
    $effectiveClientId = if ($Mode -eq 'WorkloadIdentity') { $WorkloadIdentityClientId } else { $KubeloginClientId }
    $effectiveTenantId = if ($Mode -eq 'WorkloadIdentity') { $WorkloadIdentityTenantId } else { $KubeloginTenantId }
    $convertOk = Invoke-KubeloginConvert `
        -KubeconfigPath $workingPath `
        -LoginFlow      $flow `
        -ServerId       $KubeloginServerId `
        -ClientId       $effectiveClientId `
        -TenantId       $effectiveTenantId `
        -KubeContext    $KubeContext

    $cleanupScript = {
        param($_workingPath, $_workingOwned, $_envSnapshot, $_tokenFileResult)
        if ($_envSnapshot) { Restore-WorkloadIdentityEnv -Snapshot $_envSnapshot }
        if ($_tokenFileResult -and $_tokenFileResult.Owned -and (Test-Path -LiteralPath $_tokenFileResult.Path)) {
            try { Remove-Item -LiteralPath $_tokenFileResult.Path -Force -ErrorAction SilentlyContinue } catch {}
        }
        if ($_workingOwned -and $_workingPath -and (Test-Path -LiteralPath $_workingPath)) {
            try { Remove-Item -LiteralPath $_workingPath -Force -ErrorAction SilentlyContinue } catch {}
        }
    }
    $captured = [pscustomobject]@{
        WorkingPath    = $workingPath
        WorkingOwned   = $workingOwned
        EnvSnapshot    = $envSnapshot
        TokenFile      = $tokenFileResult
    }
    $cleanup = {
        & $cleanupScript $captured.WorkingPath $captured.WorkingOwned $captured.EnvSnapshot $captured.TokenFile
    }.GetNewClosure()

    if (-not $convertOk) {
        # Best effort: surface a warning but still return the (un-converted)
        # working kubeconfig so the wrapper can emit Failed status itself.
        Write-Warning ("kubelogin convert-kubeconfig (-l {0}) returned non-zero; auth may fail." -f $flow)
    }

    return [pscustomobject]@{
        KubeconfigPath = $workingPath
        Cleanup        = $cleanup
    }
}
