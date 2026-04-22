#Requires -Version 7.0
<#
.SYNOPSIS
    Wrapper for Terraform IaC validation.
.DESCRIPTION
    Runs terraform validate (syntax-only, no init required for basic validation)
    and trivy config (which subsumes tfsec) for HCL security scanning. Returns
    findings as PSObjects in the standard v1 wrapper envelope.

    Design decision: uses trivy config instead of standalone tfsec because Aqua
    merged tfsec into trivy. Since trivy is already in the azure-analyzer tool
    manifest, this avoids adding another external dependency and keeps the
    tool surface smaller.

    Never throws -- designed for graceful degradation in the orchestrator.

    Security: All output passes through Remove-Credentials. Clones go through
    RemoteClone.ps1 (HTTPS-only, host allow-list).
.PARAMETER RepoPath
    Path to the repository root containing .tf files. Defaults to '.'.
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
$missingToolPath = Join-Path $sharedDir 'MissingTool.ps1'
if (Test-Path $missingToolPath) { . $missingToolPath }
if (-not (Get-Command Write-MissingToolNotice -ErrorAction SilentlyContinue)) {
    function Write-MissingToolNotice { param([string]$Tool, [string]$Message) Write-Warning $Message }
}

$adapterPath = Join-Path $PSScriptRoot 'iac' 'IaCAdapters.ps1'
if (Test-Path $adapterPath) { . $adapterPath }

if (-not (Get-Command Remove-Credentials -ErrorAction SilentlyContinue)) {
    function Remove-Credentials { param ([string]$Text) return $Text }
}

# At least one of terraform or trivy must be available
$hasTerraform = $null -ne (Get-Command terraform -ErrorAction SilentlyContinue)
$hasTrivy = $null -ne (Get-Command trivy -ErrorAction SilentlyContinue)

if (-not $hasTerraform -and -not $hasTrivy) {
    Write-MissingToolNotice -Tool 'terraform-iac' -Message "Neither terraform nor trivy CLI is installed. Skipping Terraform IaC validation."
    return [PSCustomObject]@{
        Source   = 'terraform-iac'
        SchemaVersion = '1.0'
        Status   = 'Skipped'
        Message  = 'Neither terraform nor trivy CLI installed. Install terraform from https://developer.hashicorp.com/terraform/install or trivy from https://github.com/aquasecurity/trivy/releases'
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
                Source = 'terraform-iac'
                SchemaVersion = '1.0'; Status = 'Failed'
                Message = 'RemoteClone helper unavailable'; Findings = @()
            }
        }
        $cloneInfo = Invoke-RemoteRepoClone -RepoUrl $RemoteUrl
        if (-not $cloneInfo) {
            return [PSCustomObject]@{
                Source = 'terraform-iac'
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
            Source = 'terraform-iac'
            SchemaVersion = '1.0'; Status = 'Failed'
            Message = "Repository path not found: $RepoPath"; Findings = @()
        }
    }

    Write-Verbose "Running Terraform IaC validation on '$RepoPath'"

    if (-not (Get-Command Invoke-IaCAdapter -ErrorAction SilentlyContinue)) {
        Write-Warning "IaCAdapters module not loaded. Terraform IaC validation cannot proceed."
        return [PSCustomObject]@{
            Source = 'terraform-iac'
            SchemaVersion = '1.0'; Status = 'Failed'
            Message = 'IaCAdapters module not loaded. Ensure modules/iac/IaCAdapters.ps1 is present.'
            Findings = @()
        }
    }

    return Invoke-IaCAdapter -Flavour 'terraform' -RepoPath $RepoPath -SourceRepoUrl $RemoteUrl
} catch {
    Write-Warning "Terraform IaC validation failed: $(Remove-Credentials -Text ([string]$_))"
    return [PSCustomObject]@{
        Source   = 'terraform-iac'
        SchemaVersion = '1.0'
        Status   = 'Failed'
        Message  = Remove-Credentials -Text ([string]$_)
        Findings = @()
    }
} finally {
    if ($cleanupClone) {
        try { & $cleanupClone } catch {
            Write-Verbose "Terraform clone cleanup failed: $(Remove-Credentials -Text ([string]$_.Exception.Message))"
        }
    }
}
