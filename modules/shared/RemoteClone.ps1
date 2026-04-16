#Requires -Version 7.4
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$sharedDir = $PSScriptRoot
$sanitizePath = Join-Path $sharedDir 'Sanitize.ps1'
if (Test-Path $sanitizePath) { . $sanitizePath }

if (-not (Get-Command Remove-Credentials -ErrorAction SilentlyContinue)) {
    function Remove-Credentials { param ([string]$Text) return $Text }
}

$script:RemoteCloneAllowedHosts = @(
    'github.com',
    'dev.azure.com'
)
$script:RemoteCloneAllowedHostSuffixes = @(
    '.visualstudio.com',
    '.ghe.com'
)

function Test-RemoteRepoUrl {
    param ([Parameter(Mandatory)][string] $Url)

    if ($Url -notmatch '^https://') { return $false }

    try {
        $uri = [System.Uri]::new($Url)
        $hostPart = $uri.Host.ToLowerInvariant()
    } catch {
        return $false
    }

    if ($script:RemoteCloneAllowedHosts -contains $hostPart) { return $true }
    foreach ($suffix in $script:RemoteCloneAllowedHostSuffixes) {
        if ($hostPart.EndsWith($suffix)) { return $true }
    }

    return $false
}

function Resolve-RemoteRepoToken {
    param (
        [Parameter(Mandatory)][string] $Url,
        [string] $Token
    )

    if ($Token) { return $Token }

    try {
        $uri = [System.Uri]::new($Url)
        $hostPart = $uri.Host.ToLowerInvariant()
    } catch {
        return ''
    }

    if ($hostPart -eq 'github.com' -or $hostPart.EndsWith('.ghe.com')) {
        if ($env:GITHUB_AUTH_TOKEN) { return $env:GITHUB_AUTH_TOKEN }
        if ($env:GITHUB_TOKEN) { return $env:GITHUB_TOKEN }
        if ($env:GH_TOKEN) { return $env:GH_TOKEN }
    }

    if ($hostPart -eq 'dev.azure.com' -or $hostPart.EndsWith('.visualstudio.com')) {
        if ($env:AZURE_DEVOPS_EXT_PAT) { return $env:AZURE_DEVOPS_EXT_PAT }
        if ($env:SYSTEM_ACCESSTOKEN) { return $env:SYSTEM_ACCESSTOKEN }
    }

    return ''
}

function ConvertTo-AuthenticatedRemoteUrl {
    param (
        [Parameter(Mandatory)][string] $Url,
        [string] $Token
    )

    if (-not $Token) { return $Url }

    try {
        $uri = [System.Uri]::new($Url)
        if ($uri.UserInfo) { return $Url }
    } catch {
        return $Url
    }

    $encodedToken = [System.Uri]::EscapeDataString($Token)
    return ($Url -replace '^https://', "https://x-access-token:$encodedToken@")
}

function Remove-RemoteCloneCredentialsFromGitConfig {
    param (
        [Parameter(Mandatory)][string] $ClonePath
    )

    $gitConfigPath = Join-Path $ClonePath '.git' 'config'
    if (-not (Test-Path $gitConfigPath)) { return }

    try {
        $configText = Get-Content -LiteralPath $gitConfigPath -Raw -ErrorAction Stop
        $scrubbed = $configText -replace '(https://)([^@]+@)', '$1'
        if ($scrubbed -ne $configText) {
            Set-Content -LiteralPath $gitConfigPath -Value $scrubbed -NoNewline -Encoding UTF8 -ErrorAction Stop
        }
    } catch {
        Write-Warning (Remove-Credentials "[remote-clone] Failed to scrub credentials from .git/config: $_")
    }
}

function Invoke-RemoteRepoClone {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)][string] $RepoUrl,
        [string] $Token,
        [string] $Branch,
        [int] $TimeoutSec = 120
    )

    if (-not (Test-RemoteRepoUrl -Url $RepoUrl)) {
        Write-Warning '[remote-clone] Refusing to clone from non-HTTPS or disallowed host URL. Allowed: github.com, dev.azure.com, *.visualstudio.com, *.ghe.com.'
        return $null
    }
    try {
        if ([System.Uri]::new($RepoUrl).UserInfo) {
            Write-Warning '[remote-clone] Refusing URL with embedded credentials. Provide token via environment variable instead.'
            return $null
        }
    } catch {
        Write-Warning "[remote-clone] Invalid repository URL: $(Remove-Credentials $RepoUrl)"
        return $null
    }

    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        Write-Warning "[remote-clone] git CLI not installed; cannot clone $(Remove-Credentials $RepoUrl)."
        return $null
    }

    $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) "azanz-remote-$([guid]::NewGuid().ToString('N'))"
    $null = New-Item -ItemType Directory -Path $tempRoot -Force

    $cleanup = {
        param($p = $tempRoot)
        if ($p -and (Test-Path -LiteralPath $p)) {
            Remove-Item -LiteralPath $p -Recurse -Force -ErrorAction SilentlyContinue
        }
    }.GetNewClosure()

    $resolvedToken = Resolve-RemoteRepoToken -Url $RepoUrl -Token $Token
    $authUrl = ConvertTo-AuthenticatedRemoteUrl -Url $RepoUrl -Token $resolvedToken

    try {
        $gitArgs = @('-c', 'credential.helper=', '-c', 'core.askPass=echo', 'clone', '--depth', '1', '--quiet', '--no-tags')
        if ($Branch) { $gitArgs += @('--branch', $Branch) }
        $gitArgs += @($authUrl, $tempRoot)

        $psi = [System.Diagnostics.ProcessStartInfo]::new()
        $psi.FileName = 'git'
        foreach ($arg in $gitArgs) { $psi.ArgumentList.Add($arg) }
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true

        $proc = [System.Diagnostics.Process]::new()
        $proc.StartInfo = $psi
        $null = $proc.Start()
        $exited = $proc.WaitForExit($TimeoutSec * 1000)
        if (-not $exited) {
            try { $proc.Kill($true) } catch {}
            throw "git clone timed out after $TimeoutSec seconds for $(Remove-Credentials $RepoUrl)."
        }

        $stdout = $proc.StandardOutput.ReadToEnd()
        $stderr = $proc.StandardError.ReadToEnd()
        if ($proc.ExitCode -ne 0) {
            $cleanErr = Remove-Credentials $stderr
            if (-not $cleanErr) { $cleanErr = 'unknown git clone error' }
            throw "git clone failed (exit $($proc.ExitCode)): $cleanErr"
        }

        if ($stdout) {
            Write-Verbose (Remove-Credentials "[remote-clone] git output: $stdout")
        }

        Remove-RemoteCloneCredentialsFromGitConfig -ClonePath $tempRoot

        return [PSCustomObject]@{
            Path    = $tempRoot
            Url     = $RepoUrl
            Cleanup = $cleanup
        }
    } catch {
        & $cleanup
        Write-Warning (Remove-Credentials "[remote-clone] $_")
        return $null
    }
}
