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
                Source = 'bicep-iac'; Status = 'Failed'
                Message = 'RemoteClone helper unavailable'; Findings = @()
            }
        }
        $cloneInfo = Invoke-RemoteRepoClone -RepoUrl $RemoteUrl
        if (-not $cloneInfo) {
            return [PSCustomObject]@{
                Source = 'bicep-iac'; Status = 'Failed'
                Message = "Remote clone failed or host not on allow-list: $RemoteUrl"
                Findings = @()
            }
        }
        $cleanupClone = $cloneInfo.Cleanup
        $RepoPath = $cloneInfo.Path
    }

    if (-not (Test-Path $RepoPath)) {
        return [PSCustomObject]@{
            Source = 'bicep-iac'; Status = 'Failed'
            Message = "Repository path not found: $RepoPath"; Findings = @()
        }
    }

    Write-Verbose "Running Bicep IaC validation on '$RepoPath'"

    if (Get-Command Invoke-IaCAdapter -ErrorAction SilentlyContinue) {
        return Invoke-IaCAdapter -Flavour 'bicep' -RepoPath $RepoPath
    }

    # Fallback: direct call if adapter not loaded
    $findings = [System.Collections.Generic.List[PSCustomObject]]::new()
    $bicepFiles = Get-ChildItem -Path $RepoPath -Filter '*.bicep' -Recurse -File -ErrorAction SilentlyContinue

    if (-not $bicepFiles -or $bicepFiles.Count -eq 0) {
        return [PSCustomObject]@{
            Source = 'bicep-iac'; Status = 'Success'
            Message = 'No .bicep files found'; Findings = @()
        }
    }

    foreach ($file in $bicepFiles) {
        $relativePath = $file.FullName.Substring($RepoPath.Length).TrimStart('\', '/')
        try {
            $output = & bicep build $file.FullName 2>&1
            $exitCode = $LASTEXITCODE

            if ($exitCode -ne 0) {
                $findings.Add([PSCustomObject]@{
                    Id          = [guid]::NewGuid().ToString()
                    Category    = 'IaC Validation'
                    Title       = "Bicep build failed: $relativePath"
                    Severity    = 'High'
                    Compliant   = $false
                    Detail      = Remove-Credentials ($output | Out-String)
                    Remediation = "Fix the Bicep file at $relativePath"
                    ResourceId  = $relativePath
                    LearnMoreUrl = 'https://learn.microsoft.com/azure/azure-resource-manager/bicep/overview'
                })
            }
        } catch {
            $findings.Add([PSCustomObject]@{
                Id          = [guid]::NewGuid().ToString()
                Category    = 'IaC Validation'
                Title       = "Bicep validation error: $relativePath"
                Severity    = 'High'
                Compliant   = $false
                Detail      = Remove-Credentials ([string]$_)
                Remediation = "Ensure bicep CLI is available and the file is valid"
                ResourceId  = $relativePath
                LearnMoreUrl = 'https://learn.microsoft.com/azure/azure-resource-manager/bicep/overview'
            })
        }
    }

    return [PSCustomObject]@{
        Source   = 'bicep-iac'
        Status   = 'Success'
        Message  = ''
        Findings = $findings
    }
} catch {
    Write-Warning "Bicep IaC validation failed: $(Remove-Credentials -Text ([string]$_))"
    return [PSCustomObject]@{
        Source   = 'bicep-iac'
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
