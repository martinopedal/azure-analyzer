#Requires -Version 7.4
<#
.SYNOPSIS
    Sync canonical ALZ query JSON from upstream into local queries/.
.DESCRIPTION
    Reads tools/tool-manifest.json to resolve the alz-queries upstream repo,
    clones upstream via modules/shared/RemoteClone.ps1, and syncs
    queries/alz_additional_queries.json in an idempotent way.
#>
[CmdletBinding()]
param(
    [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path,
    [string]$ManifestPath,
    [string]$ToolName = 'alz-queries',
    [string]$SourceRelativePath = 'queries\alz_additional_queries.json',
    [string]$DestinationRelativePath = 'queries\alz_additional_queries.json',
    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $ManifestPath) {
    $ManifestPath = Join-Path $RepoRoot 'tools\tool-manifest.json'
}

. (Join-Path $RepoRoot 'modules\shared\Sanitize.ps1')
. (Join-Path $RepoRoot 'modules\shared\Retry.ps1')
. (Join-Path $RepoRoot 'modules\shared\RemoteClone.ps1')
. (Join-Path $RepoRoot 'modules\shared\Installer.ps1')

function Resolve-UpstreamRepoUrl {
    param([Parameter(Mandatory)][string]$Repo)
    if ($Repo -match '^https://') {
        return $Repo.TrimEnd('/')
    }
    $normalized = $Repo.Trim('/')
    return "https://github.com/$normalized"
}

function Throw-SyncInstallerError {
    param(
        [Parameter(Mandatory)][string]$Reason,
        [Parameter(Mandatory)][string]$Category,
        [string]$Details,
        [string]$Url,
        [string]$Remediation = 'Verify tools/tool-manifest.json, git connectivity, and upstream query file path.'
    )

    $err = New-InstallerError `
        -Tool $ToolName `
        -Kind 'gitclone' `
        -Reason $Reason `
        -Category $Category `
        -Url $Url `
        -Remediation $Remediation `
        -Output (Remove-Credentials -Text ([string]$Details))
    throw $err
}

function Invoke-SyncAlzQueries {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepoRootPath,
        [Parameter(Mandatory)][string]$ManifestFilePath,
        [Parameter(Mandatory)][string]$SelectedToolName,
        [Parameter(Mandatory)][string]$SourceRelativeFilePath,
        [Parameter(Mandatory)][string]$DestinationPathRelative,
        [switch]$WhatIfDryRun
    )

    if (-not (Test-Path -LiteralPath $ManifestFilePath)) {
        Throw-SyncInstallerError -Reason 'Manifest file not found.' -Category 'ManifestMissing' -Details $ManifestFilePath
    }

    $manifest = $null
    try {
        $manifest = Get-Content -LiteralPath $ManifestFilePath -Raw | ConvertFrom-Json -ErrorAction Stop
    } catch {
        Throw-SyncInstallerError -Reason 'Failed to parse manifest JSON.' -Category 'ManifestParseFailed' -Details $_.Exception.Message
    }

    $toolEntry = @($manifest.tools | Where-Object { $_.name -eq $SelectedToolName } | Select-Object -First 1)
    if ($toolEntry.Count -eq 0) {
        Throw-SyncInstallerError -Reason "Tool '$SelectedToolName' not found in manifest." -Category 'ToolMissing' -Details $ManifestFilePath
    }

    $upstreamRepoRef = [string]$toolEntry[0].upstream.repo
    if ([string]::IsNullOrWhiteSpace($upstreamRepoRef)) {
        Throw-SyncInstallerError -Reason "Tool '$SelectedToolName' is missing upstream.repo." -Category 'UpstreamMissing' -Details $ManifestFilePath
    }

    $upstreamUrl = Resolve-UpstreamRepoUrl -Repo $upstreamRepoRef
    if (-not (Test-RemoteRepoUrl -Url $upstreamUrl)) {
        Throw-SyncInstallerError -Reason 'Upstream URL failed HTTPS/allow-list validation.' -Category 'UnsafeUpstream' -Details $upstreamUrl -Url $upstreamUrl
    }

    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        Throw-SyncInstallerError -Reason 'git CLI is required for query sync.' -Category 'MissingDependency' -Details 'Install git and rerun.'
    }

    Write-Verbose (Remove-Credentials -Text "[sync-alz-queries] Upstream: $upstreamUrl")

    try {
        Invoke-WithRetry -MaxAttempts 3 -InitialDelaySeconds 1 -MaxDelaySeconds 5 -ScriptBlock {
            $lsRemote = Invoke-WithTimeout -Command 'git' -Arguments @('ls-remote', '--heads', $upstreamUrl) -TimeoutSec 60
            if ($lsRemote.ExitCode -ne 0) {
                throw [System.Exception]::new("git ls-remote failed: $($lsRemote.Output)")
            }
            return $true
        } | Out-Null
    } catch {
        Throw-SyncInstallerError -Reason 'Failed to reach upstream repository.' -Category 'UpstreamUnavailable' -Details $_.Exception.Message -Url $upstreamUrl -Remediation 'Check network access and repository visibility, then retry.'
    }

    $clone = $null
    try {
        $clone = Invoke-WithRetry -MaxAttempts 3 -InitialDelaySeconds 1 -MaxDelaySeconds 10 -ScriptBlock {
            $cloneResult = Invoke-RemoteRepoClone -RepoUrl $upstreamUrl -TimeoutSec 120
            if ($null -eq $cloneResult -or [string]::IsNullOrWhiteSpace([string]$cloneResult.Path)) {
                throw [System.Exception]::new("Timed out while cloning $upstreamUrl")
            }
            return $cloneResult
        }
    } catch {
        Throw-SyncInstallerError -Reason 'Failed to clone upstream repository.' -Category 'CloneFailed' -Details $_.Exception.Message -Url $upstreamUrl
    }

    try {
        $sourcePath = Join-Path $clone.Path $SourceRelativeFilePath
        $destinationPath = Join-Path $RepoRootPath $DestinationPathRelative
        $destinationDir = Split-Path -Parent $destinationPath

        Write-Verbose (Remove-Credentials -Text "[sync-alz-queries] Source: $sourcePath")
        Write-Verbose (Remove-Credentials -Text "[sync-alz-queries] Destination: $destinationPath")

        if (-not (Test-Path -LiteralPath $sourcePath)) {
            Throw-SyncInstallerError -Reason "Upstream query file '$SourceRelativeFilePath' not found." -Category 'UpstreamContentMissing' -Details $sourcePath -Url $upstreamUrl
        }

        if (-not (Test-Path -LiteralPath $destinationDir) -and -not $WhatIfDryRun) {
            New-Item -ItemType Directory -Path $destinationDir -Force | Out-Null
        }

        $sourceHash = (Get-FileHash -LiteralPath $sourcePath -Algorithm SHA256).Hash
        $destinationExists = Test-Path -LiteralPath $destinationPath
        $destinationHash = if ($destinationExists) {
            (Get-FileHash -LiteralPath $destinationPath -Algorithm SHA256).Hash
        } else {
            ''
        }

        if ($destinationExists -and $sourceHash -eq $destinationHash) {
            Write-Host "[sync-alz-queries] No changes detected for $DestinationPathRelative."
            return [PSCustomObject]@{
                Changed        = $false
                DryRun         = [bool]$WhatIfDryRun
                Action         = 'NoChange'
                UpstreamRepo   = $upstreamUrl
                SourceFile     = (Remove-Credentials -Text $sourcePath)
                DestinationFile= (Remove-Credentials -Text $destinationPath)
            }
        }

        if ($WhatIfDryRun) {
            $action = if ($destinationExists) { 'would update' } else { 'would create' }
            Write-Host "[sync-alz-queries] DryRun: $action $DestinationPathRelative."
            return [PSCustomObject]@{
                Changed        = $true
                DryRun         = $true
                Action         = if ($destinationExists) { 'WouldUpdate' } else { 'WouldCreate' }
                UpstreamRepo   = $upstreamUrl
                SourceFile     = (Remove-Credentials -Text $sourcePath)
                DestinationFile= (Remove-Credentials -Text $destinationPath)
            }
        }

        try {
            Invoke-WithRetry -MaxAttempts 3 -InitialDelaySeconds 1 -MaxDelaySeconds 5 -ScriptBlock {
                Copy-Item -LiteralPath $sourcePath -Destination $destinationPath -Force -ErrorAction Stop
                $updatedHash = (Get-FileHash -LiteralPath $destinationPath -Algorithm SHA256).Hash
                if ($updatedHash -ne $sourceHash) {
                    throw [System.Exception]::new('Hash mismatch after copy operation.')
                }
                $verifyResult = Invoke-WithTimeout -Command 'git' -Arguments @('hash-object', $destinationPath) -TimeoutSec 30
                if ($verifyResult.ExitCode -ne 0) {
                    throw [System.Exception]::new("git hash-object verification failed: $($verifyResult.Output)")
                }
                return $true
            } | Out-Null
        } catch {
            Throw-SyncInstallerError -Reason 'Failed while writing destination query file.' -Category 'WriteFailed' -Details $_.Exception.Message -Url $upstreamUrl -Remediation 'Verify file permissions and rerun the sync.'
        }

        Write-Host "[sync-alz-queries] Updated $DestinationPathRelative from upstream."
        return [PSCustomObject]@{
            Changed         = $true
            DryRun          = $false
            Action          = if ($destinationExists) { 'Updated' } else { 'Created' }
            UpstreamRepo    = $upstreamUrl
            SourceFile      = (Remove-Credentials -Text $sourcePath)
            DestinationFile = (Remove-Credentials -Text $destinationPath)
        }
    } finally {
        if ($clone -and $clone.PSObject.Properties.Name -contains 'Cleanup' -and $clone.Cleanup) {
            & $clone.Cleanup
        }
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    Invoke-SyncAlzQueries `
        -RepoRootPath $RepoRoot `
        -ManifestFilePath $ManifestPath `
        -SelectedToolName $ToolName `
        -SourceRelativeFilePath $SourceRelativePath `
        -DestinationPathRelative $DestinationRelativePath `
        -WhatIfDryRun:$DryRun
}
