#Requires -Version 7.4
<#
.SYNOPSIS
    Wrapper for Infracost CLI pre-deploy IaC cost estimation.
.DESCRIPTION
    Runs `infracost breakdown` against Terraform/Bicep source and emits a v1
    wrapper envelope with one finding per resource estimate.

    Cloud-first behavior:
    - `-Repository` clones a remote repo through RemoteClone.ps1 (HTTPS-only,
      host allow-list, token-safe cleanup).
    - `-Path` scans a local directory (fallback mode).

    Resilience and security:
    - Infracost CLI invocation is wrapped with Invoke-WithRetry.
    - CLI process is executed through Invoke-WithTimeout with 300s timeout.
    - Any surfaced message is passed through Remove-Credentials.

    Never throws -- designed for graceful degradation in the orchestrator.
.PARAMETER Path
    Local directory containing Terraform/Bicep files. Defaults to current dir.
.PARAMETER Repository
    Remote HTTPS repository URL to clone and scan.
#>
[CmdletBinding()]
param (
    [Alias('RepoPath')]
    [string] $Path = '.',
    [Alias('RemoteUrl')]
    [string] $Repository
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

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
$installerPath = Join-Path $sharedDir 'Installer.ps1'
if (-not (Get-Command Invoke-WithTimeout -ErrorAction SilentlyContinue) -and (Test-Path $installerPath)) {
    . $installerPath
}

if (-not (Get-Command Remove-Credentials -ErrorAction SilentlyContinue)) {
    function Remove-Credentials { param ([string]$Text) return $Text }
}
if (-not (Get-Command Invoke-WithRetry -ErrorAction SilentlyContinue)) {
    function Invoke-WithRetry { param([scriptblock]$ScriptBlock, [int]$MaxAttempts = 3) & $ScriptBlock }
}
if (-not (Get-Command Invoke-WithTimeout -ErrorAction SilentlyContinue)) {
    function Invoke-WithTimeout {
        param (
            [Parameter(Mandatory)][string]$Command,
            [Parameter(Mandatory)][string[]]$Arguments,
            [int]$TimeoutSec = 300
        )
        $output = & $Command @Arguments 2>&1 | Out-String
        [PSCustomObject]@{
            ExitCode = $LASTEXITCODE
            Output   = Remove-Credentials $output
        }
    }
}

function Test-InfracostInstalled {
    return $null -ne (Get-Command infracost -ErrorAction SilentlyContinue)
}

function Get-FirstJsonObjectText {
    param([AllowNull()][string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    $start = $Text.IndexOf('{')
    $end = $Text.LastIndexOf('}')
    if ($start -lt 0 -or $end -lt $start) { return $null }
    return $Text.Substring($start, ($end - $start) + 1)
}

if (-not (Test-InfracostInstalled)) {
    Write-Warning "infracost CLI is not installed. Skipping Infracost scan."
    return [PSCustomObject]@{
        Source        = 'infracost'
        SchemaVersion = '1.0'
        Status        = 'Skipped'
        Message       = 'infracost CLI not installed. Install from https://www.infracost.io/docs/'
        Findings      = @()
    }
}

$cloneInfo = $null
$cleanupClone = $null
try {
    if ($Repository) {
        if (-not (Get-Command Invoke-RemoteRepoClone -ErrorAction SilentlyContinue)) {
            Write-Warning "RemoteClone helper not loaded; cannot scan remote repository."
            return [PSCustomObject]@{
                Source        = 'infracost'
                SchemaVersion = '1.0'
                Status        = 'Failed'
                Message       = 'RemoteClone helper unavailable'
                Findings      = @()
            }
        }
        $cloneInfo = Invoke-RemoteRepoClone -RepoUrl $Repository -TimeoutSec 300
        if (-not $cloneInfo) {
            return [PSCustomObject]@{
                Source        = 'infracost'
                SchemaVersion = '1.0'
                Status        = 'Failed'
                Message       = "Remote clone failed or host not on allow-list: $Repository"
                Findings      = @()
            }
        }
        $cleanupClone = $cloneInfo.Cleanup
        $Path = $cloneInfo.Path
    }

    if (-not (Test-Path -LiteralPath $Path)) {
        return [PSCustomObject]@{
            Source        = 'infracost'
            SchemaVersion = '1.0'
            Status        = 'Failed'
            Message       = "Path not found: $Path"
            Findings      = @()
        }
    }

    $iacFiles = @(Get-ChildItem -Path $Path -Recurse -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Extension -in @('.tf', '.bicep') })
    if ($iacFiles.Count -eq 0) {
        return [PSCustomObject]@{
            Source        = 'infracost'
            SchemaVersion = '1.0'
            Status        = 'Skipped'
            Message       = 'No Terraform or Bicep files found under scan path.'
            Findings      = @()
        }
    }

    $args = @('breakdown', '--path', $Path, '--format', 'json', '--no-color')
    $exec = Invoke-WithRetry -MaxAttempts 3 -InitialDelaySeconds 2 -MaxDelaySeconds 30 -ScriptBlock {
        Invoke-WithTimeout -Command 'infracost' -Arguments $args -TimeoutSec 300
    }

    if (-not $exec -or $exec.ExitCode -ne 0) {
        $safeOutput = if ($exec) { Remove-Credentials ([string]$exec.Output) } else { '' }
        return [PSCustomObject]@{
            Source        = 'infracost'
            SchemaVersion = '1.0'
            Status        = 'Failed'
            Message       = "infracost breakdown failed (exit code $($exec.ExitCode)): $safeOutput"
            Findings      = @()
        }
    }

    $jsonText = Get-FirstJsonObjectText -Text ([string]$exec.Output)
    if (-not $jsonText) {
        return [PSCustomObject]@{
            Source        = 'infracost'
            SchemaVersion = '1.0'
            Status        = 'Failed'
            Message       = 'infracost output did not contain a JSON object.'
            Findings      = @()
        }
    }

    $parsed = $null
    try {
        $parsed = $jsonText | ConvertFrom-Json -Depth 100 -ErrorAction Stop
    } catch {
        return [PSCustomObject]@{
            Source        = 'infracost'
            SchemaVersion = '1.0'
            Status        = 'Failed'
            Message       = Remove-Credentials "Failed to parse infracost JSON: $($_.Exception.Message)"
            Findings      = @()
        }
    }

    $findings = [System.Collections.Generic.List[PSCustomObject]]::new()
    foreach ($project in @($parsed.projects)) {
        if (-not $project) { continue }
        $projectName = if ($project.PSObject.Properties['name'] -and $project.name) { [string]$project.name } else { 'project' }
        $projectPath = if ($project.PSObject.Properties['path'] -and $project.path) { [string]$project.path } else { [string]$Path }
        $resources = @()
        if ($project.PSObject.Properties['breakdown'] -and $project.breakdown -and
            $project.breakdown.PSObject.Properties['resources']) {
            $resources = @($project.breakdown.resources)
        }

        foreach ($resource in $resources) {
            if (-not $resource) { continue }
            $resourceName = if ($resource.PSObject.Properties['name'] -and $resource.name) { [string]$resource.name } else { 'resource' }
            $resourceType = if ($resource.PSObject.Properties['resourceType'] -and $resource.resourceType) { [string]$resource.resourceType } else { 'unknown' }
            $monthlyRaw = if ($resource.PSObject.Properties['monthlyCost']) { [string]$resource.monthlyCost } else { '0' }
            $monthlyCost = 0.0
            [void][double]::TryParse($monthlyRaw, [System.Globalization.NumberStyles]::Any, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$monthlyCost)

            $findings.Add([PSCustomObject]@{
                    Id            = [guid]::NewGuid().ToString()
                    Category      = 'Cost'
                    Title         = "Estimated monthly cost: $([string]::Format([System.Globalization.CultureInfo]::InvariantCulture, '{0:0.00}', $monthlyCost)) for $resourceType"
                    Severity      = 'Info'
                    Compliant     = $false
                    Detail        = "Infracost estimate for $resourceName in project $projectName."
                    Remediation   = 'Review right-sizing, SKU choice, and environment count before deployment.'
                    ResourceId    = $projectPath
                    LearnMoreUrl  = 'https://www.infracost.io/docs/'
                    ResourceType  = $resourceType
                    ResourceName  = $resourceName
                    ProjectName   = $projectName
                    ProjectPath   = $projectPath
                    MonthlyCost   = [math]::Round($monthlyCost, 2)
                    Currency      = if ($resource.PSObject.Properties['currency'] -and $resource.currency) { [string]$resource.currency } else { 'USD' }
                })
        }
    }

    return [PSCustomObject]@{
        Source        = 'infracost'
        SchemaVersion = '1.0'
        Status        = 'Success'
        Message       = "Parsed $($findings.Count) resource cost estimate(s)."
        Findings      = @($findings)
    }
} catch {
    Write-Warning "Infracost scan failed: $(Remove-Credentials -Text ([string]$_.Exception.Message))"
    return [PSCustomObject]@{
        Source        = 'infracost'
        SchemaVersion = '1.0'
        Status        = 'Failed'
        Message       = Remove-Credentials -Text ([string]$_.Exception.Message)
        Findings      = @()
    }
} finally {
    if ($cleanupClone) {
        try { & $cleanupClone } catch {
            Write-Verbose "Infracost clone cleanup failed: $(Remove-Credentials -Text ([string]$_.Exception.Message))"
        }
    }
}
