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
$missingToolPath = Join-Path $sharedDir 'MissingTool.ps1'
if (Test-Path $missingToolPath) { . $missingToolPath }
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

function Get-BicepToolVersion {
    try {
        $raw = bicep --version 2>&1
        if ($LASTEXITCODE -ne 0) { return '' }
        $text = if ($raw -is [array]) { ($raw -join ' ') } else { [string]$raw }
        $match = [regex]::Match($text, '(\d+\.\d+\.\d+(?:[-+][A-Za-z0-9\.-]+)?)')
        if ($match.Success) { return $match.Groups[1].Value }
        return $text.Trim()
    } catch {
        return ''
    }
}

function Get-PsRuleAzureVersion {
    try {
        $module = Get-Module PSRule.Rules.Azure -ListAvailable | Sort-Object Version -Descending | Select-Object -First 1
        if ($module -and $module.Version) { return [string]$module.Version }
        return ''
    } catch {
        return ''
    }
}

function ConvertTo-RepositoryWebUrl {
    param ([string] $Url)
    if ([string]::IsNullOrWhiteSpace($Url)) { return '' }
    $normalized = $Url.Trim()
    if ($normalized -match '^git@([^:]+):(.+)$') {
        return "https://$($Matches[1])/$($Matches[2] -replace '\.git$','')"
    }
    if ($normalized -match '^https?://') {
        return ($normalized -replace '\.git$','').TrimEnd('/')
    }
    return ''
}

if (-not (Get-Command bicep -ErrorAction SilentlyContinue)) {
    Write-MissingToolNotice -Tool 'iac-bicep' -Message "bicep CLI is not installed. Skipping Bicep IaC validation. Install from https://learn.microsoft.com/azure/azure-resource-manager/bicep/install"
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
    $bicepVersion = Get-BicepToolVersion
    $psRuleVersion = Get-PsRuleAzureVersion
    $toolVersionParts = [System.Collections.Generic.List[string]]::new()
    if (-not [string]::IsNullOrWhiteSpace($bicepVersion)) { $toolVersionParts.Add("bicep:$bicepVersion") | Out-Null }
    if (-not [string]::IsNullOrWhiteSpace($psRuleVersion)) { $toolVersionParts.Add("psrule.rules.azure:$psRuleVersion") | Out-Null }
    $toolVersion = ($toolVersionParts -join ';')
    $repositoryUrl = ''

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
        if ($cloneInfo.PSObject.Properties['Url']) {
            $repositoryUrl = ConvertTo-RepositoryWebUrl -Url ([string]$cloneInfo.Url)
        }
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

    if ([string]::IsNullOrWhiteSpace($repositoryUrl)) {
        try {
            $origin = git -C $RepoPath config --get remote.origin.url 2>$null
            if ($origin) { $repositoryUrl = ConvertTo-RepositoryWebUrl -Url ([string]$origin) }
        } catch {}
    }

    $result = Invoke-IaCAdapter -Flavour 'bicep' -RepoPath $RepoPath
    if ($result -and $result.PSObject) {
        if (-not $result.PSObject.Properties['ToolVersion']) {
            $result | Add-Member -NotePropertyName ToolVersion -NotePropertyValue $toolVersion
        } elseif ([string]::IsNullOrWhiteSpace([string]$result.ToolVersion)) {
            $result.ToolVersion = $toolVersion
        }

        if (-not [string]::IsNullOrWhiteSpace($repositoryUrl)) {
            if (-not $result.PSObject.Properties['RepositoryUrl']) {
                $result | Add-Member -NotePropertyName RepositoryUrl -NotePropertyValue $repositoryUrl
            } else {
                $result.RepositoryUrl = $repositoryUrl
            }
            if (-not $result.PSObject.Properties['RepositoryRef']) {
                $result | Add-Member -NotePropertyName RepositoryRef -NotePropertyValue 'main'
            }
        }

        foreach ($finding in @($result.Findings)) {
            if (-not $finding) { continue }
            if (-not $finding.PSObject.Properties['ToolVersion']) {
                $finding | Add-Member -NotePropertyName ToolVersion -NotePropertyValue $toolVersion
            } elseif ([string]::IsNullOrWhiteSpace([string]$finding.ToolVersion)) {
                $finding.ToolVersion = $toolVersion
            }
        }
    }

    return $result
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
