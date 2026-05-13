#Requires -Version 7.4
<#
.SYNOPSIS
    Shallow-clone helper for cloud-first scanners (zizmor, gitleaks, trivy).
.DESCRIPTION
    azure-analyzer is a cloud-posture tool. The repository scanners are
    primarily invoked against remote git endpoints (GitHub, Azure DevOps,
    GitHub Enterprise). This helper performs a minimal, authenticated,
    HTTPS-only shallow clone into a per-invocation temp directory and
    returns an IDisposable-style cleanup scriptblock.

    Security:
      - Only HTTPS URLs are accepted (no git://, ssh://, file://).
      - Host is allow-listed (github.com, dev.azure.com, *.visualstudio.com,
        *.ghe.com by default).
      - Auth tokens are injected into the URL via the x-access-token /
        basic-auth pattern and NEVER logged. The cloned ".git/config" is
        rewritten to scrub the embedded credential after clone so that
        downstream scanners cannot read it back.
      - All output is piped through Remove-Credentials before being
        surfaced.
      - Timeout and retry are provided via Invoke-WithRetry; transient
        failures (429/503/timeouts) are retried, permanent failures
        (auth/not-found) surface immediately.
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Import shared infrastructure
$script:sharedRoot = Split-Path $PSCommandPath -Parent
. (Join-Path $script:sharedRoot 'Retry.ps1')
. (Join-Path $script:sharedRoot 'CliTimeout.ps1')
. (Join-Path $script:sharedRoot 'Sanitize.ps1')

$script:RemoteCloneAllowedHosts = @(
    'github.com',
    'api.github.com',
    'dev.azure.com',
    'ssh.dev.azure.com'
)
# Suffix-based allow-list for Azure DevOps legacy hosts + GHES.
$script:RemoteCloneAllowedHostSuffixes = @(
    '.visualstudio.com',
    '.ghe.com',
    '.githubenterprise.com'
)

function Test-RemoteRepoUrl {
    <#
    .SYNOPSIS
        Returns $true if the URL is an HTTPS URL on an allow-listed host.
    #>
    param ([Parameter(Mandatory)][string] $Url)
    if ($Url -notmatch '^https://') { return $false }
    $hostPart = ($Url -replace '^https://', '').Split('/')[0].Split('@')[-1].ToLowerInvariant()
    if ($script:RemoteCloneAllowedHosts -contains $hostPart) { return $true }
    foreach ($suffix in $script:RemoteCloneAllowedHostSuffixes) {
        if ($hostPart.EndsWith($suffix)) { return $true }
    }
    return $false
}

function ConvertTo-AuthenticatedRemoteUrl {
    <#
    .SYNOPSIS
        Inject a bearer token into an HTTPS clone URL using the pattern git
        natively supports: https://<user>:<token>@host/path.git. Returns
        the rewritten URL; tokens are never written to log output.
    #>
    param (
        [Parameter(Mandatory)][string] $Url,
        [string] $Token,
        [string] $User = 'x-access-token'
    )
    if ([string]::IsNullOrEmpty($Token)) { return $Url }
    if ($Url -notmatch '^https://') { return $Url }
    $scheme = 'https://'
    $rest   = $Url.Substring($scheme.Length)
    # If auth already embedded, don't double it.
    if ($rest.Contains('@')) { return $Url }
    # URL-encode user+token to avoid ':' and '@' corrupting the URL.
    $u = [System.Net.WebUtility]::UrlEncode($User)
    $t = [System.Net.WebUtility]::UrlEncode($Token)
    return "$scheme${u}:${t}@$rest"
}

function Resolve-RemoteRepoToken {
    <#
    .SYNOPSIS
        Pick the right env var token for a given remote URL. Callers can
        also pass an explicit -Token override.
    #>
    param (
        [Parameter(Mandatory)][string] $Url,
        [string] $Token
    )
    if (-not [string]::IsNullOrEmpty($Token)) { return $Token }
    $hostPart = ($Url -replace '^https://', '').Split('/')[0].Split('@')[-1].ToLowerInvariant()
    if ($hostPart -eq 'github.com' -or $hostPart.EndsWith('.ghe.com') -or $hostPart.EndsWith('.githubenterprise.com')) {
        if ($env:GITHUB_TOKEN)      { return $env:GITHUB_TOKEN }
        if ($env:GH_TOKEN)          { return $env:GH_TOKEN }
    }
    if ($hostPart -eq 'dev.azure.com' -or $hostPart.EndsWith('.visualstudio.com')) {
        if ($env:AZURE_DEVOPS_EXT_PAT) { return $env:AZURE_DEVOPS_EXT_PAT }
        if ($env:SYSTEM_ACCESSTOKEN)   { return $env:SYSTEM_ACCESSTOKEN }
    }
    return ''
}

function Resolve-ScanTargetUrl {
    <#
    .SYNOPSIS
        Normalize a -Repository argument (either 'owner/repo' shorthand or a
        full HTTPS URL) into a full HTTPS URL suitable for Invoke-RemoteRepoClone.
        Returns $null for invalid / disallowed inputs.
    #>
    param (
        [string] $Repository,
        [string] $AdoRepoUrl,
        [string] $GitHubHost = 'github.com'
    )
    if ($AdoRepoUrl) {
        if (Test-RemoteRepoUrl -Url $AdoRepoUrl) { return $AdoRepoUrl }
        return $null
    }
    if (-not $Repository) { return $null }
    if ($Repository -match '^https://') {
        if (Test-RemoteRepoUrl -Url $Repository) { return $Repository }
        return $null
    }
    # Shorthand: owner/repo -> https://<host>/owner/repo
    if ($Repository -match '^[^/\s]+/[^/\s]+$') {
        $hostPart = if ($GitHubHost) { $GitHubHost } else { 'github.com' }
        $candidate = "https://$hostPart/$Repository"
        if (Test-RemoteRepoUrl -Url $candidate) { return $candidate }
    }
    return $null
}

function Invoke-RemoteRepoClone {
    <#
    .SYNOPSIS
        Shallow-clone a remote repository into a per-invocation temp dir.
        Returns [PSCustomObject]@{ Path; Url; Cleanup } where Cleanup is a
        scriptblock the caller MUST invoke in a finally block.

        Never throws. On failure, returns $null and writes a sanitized
        warning.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)][string] $RepoUrl,
        [string] $Token,
        [string] $Branch,
        [int] $TimeoutSec = 300
    )

    if (-not (Test-RemoteRepoUrl -Url $RepoUrl)) {
        Write-Warning "[remote-clone] Refusing to clone from non-HTTPS or disallowed host URL. Allowed: github.com, dev.azure.com, *.visualstudio.com, *.ghe.com."
        return $null
    }

    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        Write-Warning "[remote-clone] git CLI not installed; cannot clone $RepoUrl."
        return $null
    }

    $resolvedToken = Resolve-RemoteRepoToken -Url $RepoUrl -Token $Token
    $authUrl = ConvertTo-AuthenticatedRemoteUrl -Url $RepoUrl -Token $resolvedToken

    $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) "azanz-remote-$([guid]::NewGuid().ToString('N'))"
    $null = New-Item -ItemType Directory -Path $tempRoot -Force

    $cleanup = {
        param($p = $tempRoot)
        if ($p -and (Test-Path $p)) {
            Remove-Item $p -Recurse -Force -ErrorAction SilentlyContinue
        }
    }.GetNewClosure()

    $gitArgs = @('-c', 'credential.helper=', '-c', 'core.askPass=echo',
                 'clone', '--depth', '1', '--quiet', '--no-tags')
    if ($Branch) { $gitArgs += @('--branch', $Branch) }
    $gitArgs += @($authUrl, $tempRoot)

    try {
        $cloneResult = Invoke-WithRetry -MaxAttempts 3 -InitialDelaySeconds 2 -MaxDelaySeconds 20 -ScriptBlock {
            $timeoutResult = Invoke-WithTimeout -Command 'git' -Arguments $gitArgs -TimeoutSec $TimeoutSec
            if ($timeoutResult.ExitCode -ne 0) {
                $sanitized = Remove-Credentials $timeoutResult.Output
                throw [System.Exception]::new("git clone failed: $sanitized")
            }
            return $timeoutResult
        }

        # Scrub credentials out of the cloned .git/config so downstream
        # scanners reading repo metadata cannot recover the token.
        $gitConfig = Join-Path $tempRoot '.git' 'config'
        if (Test-Path $gitConfig) {
            try {
                $cfg = Get-Content $gitConfig -Raw
                $scrubbed = [Regex]::Replace($cfg, 'https://[^@/:\s]+:[^@/:\s]+@', 'https://')
                if ($scrubbed -ne $cfg) {
                    Set-Content $gitConfig -Value $scrubbed -NoNewline
                }
            } catch {
                Write-Verbose "[remote-clone] failed to scrub .git/config: $($_.Exception.Message)"
            }
        }

        return [PSCustomObject]@{
            Path    = $tempRoot
            Url     = $RepoUrl
            Cleanup = $cleanup
        }
    } catch {
        Write-Warning (Remove-Credentials "[remote-clone] clone error for ${RepoUrl}: $($_.Exception.Message)")
        & $cleanup
        return $null
    }
}
