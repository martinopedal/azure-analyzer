#Requires -Version 7.0
<#
.SYNOPSIS
    Wrapper for Bicep IaC validation.
.DESCRIPTION
    Runs bicep build against .bicep files in a repository to detect syntax
    errors, unresolved references, and structural issues. Returns findings as
    PSObjects in the standard v1 wrapper envelope.

    Never throws -- designed for graceful degradation in the orchestrator.

    Security: All output passes through Remove-Credentials. Clones go through
    RemoteClone.ps1 (HTTPS-only, host allow-list).
.PARAMETER RepoPath
    Path to the repository root containing .bicep files. Defaults to '.'.
.PARAMETER RemoteUrl
    Remote repository URL to clone and scan.
#>
[CmdletBinding()]
param (
    [string] $RepoPath = '.',

    [string] $RemoteUrl
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Dot-source shared modules
$sharedDir = Join-Path (Split-Path $PSScriptRoot -Parent) 'modules' 'shared'
if (-not $sharedDir -or -not (Test-Path $sharedDir)) {
    $sharedDir = Join-Path $PSScriptRoot 'shared'
}
$sanitizePath = Join-Path $sharedDir 'Sanitize.ps1'
if (Test-Path $sanitizePath) { . $sanitizePath }
$retryPath = Join-Path $sharedDir 'Retry.ps1'
if (Test-Path $retryPath) { . $retryPath }
$remoteClonePath = Join-Path $sharedDir 'RemoteClone.ps1'
if (Test-Path $remoteClonePath) { . $remoteClonePath }

# Load the adapter
$adapterPath = Join-Path $PSScriptRoot 'iac' 'IaCAdapters.ps1'
if (Test-Path $adapterPath) { . $adapterPath }

if (-not (Get-Command Remove-Credentials -ErrorAction SilentlyContinue)) {
    function Remove-Credentials { param ([string]$Text) return $Text }
}

if (-not (Get-Command bicep -ErrorAction SilentlyContinue)) {
    Write-Warning "bicep CLI is not installed. Skipping Bicep IaC validation. Install from https://learn.microsoft.com/azure/azure-resource-manager/bicep/install"
    return [PSCustomObject]@{
        Source   = 'bicep-iac'
        SchemaVersion = '1.0'
        Status   = 'Skipped'
        Message  = 'bicep CLI not installed. Install from https://learn.microsoft.com/azure/azure-resource-manager/bicep/install'
        Findings = @()
    }
}

$cloneInfo = $null
$cleanupClone = $null
try {
    if ($RemoteUrl) {
        if (-not (Get-Command Invoke-RemoteRepoClone -ErrorAction SilentlyContinue)) {
            Write-Warning "RemoteClone helper not loaded; cannot scan remote URL."
            return [PSCustomObject]@{
                Source = 'bicep-iac'
                SchemaVersion = '1.0'; Status = 'Failed'
                Message = 'RemoteClone helper unavailable'; Findings = @()
            }
        }
        $cloneInfo = Invoke-RemoteRepoClone -RepoUrl $RemoteUrl
        if (-not $cloneInfo) {
            return [PSCustomObject]@{
                Source = 'bicep-iac'
                SchemaVersion = '1.0'; Status = 'Failed'
                Message = "Remote clone failed or host not on allow-list: $RemoteUrl"
                Findings = @()
            }
        }
        $cleanupClone = $cloneInfo.Cleanup
        $RepoPath = $cloneInfo.Path
    }

    if (-not (Test-Path $RepoPath)) {
        return [PSCustomObject]@{
            Source = 'bicep-iac'
            SchemaVersion = '1.0'; Status = 'Failed'
            Message = "Repository path not found: $RepoPath"; Findings = @()
        }
    }

    Write-Verbose "Running Bicep IaC validation on '$RepoPath'"

    if (-not (Get-Command Invoke-IaCAdapter -ErrorAction SilentlyContinue)) {
        Write-Warning "IaCAdapters module not loaded. Bicep IaC validation cannot proceed."
        return [PSCustomObject]@{
            Source = 'bicep-iac'
            SchemaVersion = '1.0'; Status = 'Failed'
            Message = 'IaCAdapters module not loaded. Ensure modules/iac/IaCAdapters.ps1 is present.'
            Findings = @()
        }
    }

    return Invoke-IaCAdapter -Flavour 'bicep' -RepoPath $RepoPath
} catch {
    Write-Warning "Bicep IaC validation failed: $(Remove-Credentials -Text ([string]$_))"
    return [PSCustomObject]@{
        Source   = 'bicep-iac'
        SchemaVersion = '1.0'
        Status   = 'Failed'
        Message  = Remove-Credentials -Text ([string]$_)
        Findings = @()
    }
} finally {
    if ($cleanupClone) {
        try { & $cleanupClone } catch {
            Write-Verbose "Bicep clone cleanup failed: $(Remove-Credentials -Text ([string]$_.Exception.Message))"
        }
    }
}
