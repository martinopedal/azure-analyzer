#Requires -Version 7.0
<#
.SYNOPSIS
    Wrapper for zizmor CLI (GitHub Actions YAML scanner).
.DESCRIPTION
    Runs the zizmor CLI against GitHub Actions workflow files to detect security
    issues such as expression injection, untrusted input, and unpinned actions.
    If zizmor is not installed, writes a warning and returns an empty result.
    Never throws -- designed for graceful degradation in the orchestrator.

    JSON output is written to a temp file (--output) to avoid stderr/stdout
    mixing. The temp file is cleaned up in a finally block.
.PARAMETER Repository
    Path to the repository root to scan. Required.
.PARAMETER WorkflowPath
    Relative path to the workflows directory. Defaults to .github/workflows.
#>
[CmdletBinding()]
param (
    [string] $Repository,

    [string] $WorkflowPath = '.github/workflows',

    [string] $RemoteUrl
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Dot-source shared modules for Remove-Credentials, Invoke-WithRetry, Invoke-RemoteRepoClone
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

if (-not (Get-Command Remove-Credentials -ErrorAction SilentlyContinue)) {
    function Remove-Credentials { param ([string]$Text) return $Text }
}

function Test-ZizmorInstalled {
    $null -ne (Get-Command zizmor -ErrorAction SilentlyContinue)
}

if (-not (Test-ZizmorInstalled)) {
    Write-Warning "zizmor is not installed. Skipping zizmor scan. Install from https://github.com/woodruffw/zizmor/releases or: pip install zizmor"
    return [PSCustomObject]@{
        Source   = 'zizmor'
        Status   = 'Skipped'
        Message  = 'zizmor CLI not installed. Install from https://github.com/woodruffw/zizmor/releases or: pip install zizmor'
        Findings = @()
    }
}

# Remote-first: if -RemoteUrl provided, clone it and scan the clone path.
# Otherwise fall back to local -Repository.
$cloneInfo = $null
$cleanupClone = $null
try {
    if ($RemoteUrl) {
        if (-not (Get-Command Invoke-RemoteRepoClone -ErrorAction SilentlyContinue)) {
            Write-Warning "RemoteClone helper not loaded; cannot scan remote URL."
            return [PSCustomObject]@{
                Source = 'zizmor'; Status = 'Failed'
                Message = 'RemoteClone helper unavailable'; Findings = @()
            }
        }
        $cloneInfo = Invoke-RemoteRepoClone -RepoUrl $RemoteUrl
        if (-not $cloneInfo) {
            return [PSCustomObject]@{
                Source = 'zizmor'; Status = 'Failed'
                Message = "Remote clone failed or host not on allow-list: $RemoteUrl"
                Findings = @()
            }
        }
        $cleanupClone = $cloneInfo.Cleanup
        $Repository = $cloneInfo.Path
    }

    if (-not $Repository) {
        return [PSCustomObject]@{
            Source = 'zizmor'; Status = 'Skipped'
            Message = 'No -RemoteUrl or -Repository provided'; Findings = @()
        }
    }
    $scanPath = Join-Path $Repository $WorkflowPath
    if (-not (Test-Path $scanPath)) {
        Write-Warning "Workflow path not found: $scanPath"
        return [PSCustomObject]@{
            Source   = 'zizmor'
            Status   = 'Skipped'
            Message  = "Workflow path not found: $scanPath"
            Findings = @()
        }
    }

    Write-Verbose "Running zizmor for workflow path $scanPath"

    # Write JSON to a temp file to keep stderr separate from the JSON stream
    $reportFile = Join-Path ([System.IO.Path]::GetTempPath()) "zizmor-report-$([guid]::NewGuid().ToString('N')).json"

    try {
        $useRetry = Get-Command Invoke-WithRetry -ErrorAction SilentlyContinue
        if ($useRetry) {
            Invoke-WithRetry -ScriptBlock {
                & zizmor --format json --output $reportFile $scanPath 2>&1 | ForEach-Object {
                    if ($_ -is [System.Management.Automation.ErrorRecord]) {
                        Write-Verbose "zizmor stderr: $_"
                    }
                }
            }
        } else {
            & zizmor --format json --output $reportFile $scanPath 2>&1 | ForEach-Object {
                if ($_ -is [System.Management.Automation.ErrorRecord]) {
                    Write-Verbose "zizmor stderr: $_"
                }
            }
        }

        $exitCode = $LASTEXITCODE

        # Non-zero exit with no report = hard failure
        if ($exitCode -ne 0 -and -not (Test-Path $reportFile)) {
            Write-Warning (Remove-Credentials "zizmor exited with code $exitCode and produced no report")
            return [PSCustomObject]@{
                Source   = 'zizmor'
                Status   = 'Failed'
                Message  = Remove-Credentials "zizmor exited with code $exitCode and produced no report"
                Findings = @()
            }
        }

        $json = $null
        if (Test-Path $reportFile) {
            $jsonText = Get-Content $reportFile -Raw -ErrorAction SilentlyContinue
            if ($jsonText) {
                try {
                    $json = $jsonText | ConvertFrom-Json -ErrorAction Stop
                } catch {
                    Write-Warning (Remove-Credentials "zizmor report JSON parse failed: $_")
                    return [PSCustomObject]@{
                        Source   = 'zizmor'
                        Status   = 'Failed'
                        Message  = Remove-Credentials "Report JSON parse failed: $_"
                        Findings = @()
                    }
                }
            } else {
                # Empty report file — no findings
                $json = @()
            }
        } elseif ($exitCode -eq 0) {
            # exit 0 but no report file — zizmor found nothing
            $json = @()
        }
    } finally {
        Remove-Item $reportFile -Force -ErrorAction SilentlyContinue
    }

    $findings = [System.Collections.Generic.List[PSCustomObject]]::new()

    # zizmor JSON output is an array of finding objects
    $items = if ($json -is [System.Collections.IEnumerable] -and $json -isnot [string]) {
        @($json)
    } elseif ($null -ne $json) {
        @($json)
    } else {
        @()
    }

    foreach ($item in $items) {
        $ruleId = ''
        if ($item.PSObject.Properties['id'] -and $item.id) {
            $ruleId = [string]$item.id
        }

        $desc = ''
        if ($item.PSObject.Properties['desc'] -and $item.desc) {
            $desc = [string]$item.desc
        }

        $rawSev = 'Medium'
        if ($item.PSObject.Properties['severity'] -and $item.severity) {
            $rawSev = [string]$item.severity
        }
        $severity = switch -Regex ($rawSev.ToLowerInvariant()) {
            'critical'        { 'Critical' }
            'high'            { 'High' }
            'medium|moderate' { 'Medium' }
            'low'             { 'Low' }
            'info'            { 'Info' }
            default           { 'Medium' }
        }

        $learnMoreUrl = ''
        if ($item.PSObject.Properties['url'] -and $item.url) {
            $learnMoreUrl = [string]$item.url
        }

        # Extract file location from the finding
        $filePath = ''
        if ($item.PSObject.Properties['locations'] -and $item.locations) {
            $locs = @($item.locations)
            if ($locs.Count -gt 0) {
                $loc = $locs[0]
                if ($loc.PSObject.Properties['symbolic'] -and $loc.symbolic) {
                    if ($loc.symbolic.PSObject.Properties['key'] -and $loc.symbolic.key) {
                        $filePath = [string]$loc.symbolic.key
                    }
                }
                if (-not $filePath -and $loc.PSObject.Properties['path'] -and $loc.path) {
                    $filePath = [string]$loc.path
                }
            }
        }
        if (-not $filePath -and $item.PSObject.Properties['location'] -and $item.location) {
            if ($item.location.PSObject.Properties['path'] -and $item.location.path) {
                $filePath = [string]$item.location.path
            }
        }
        if (-not $filePath) {
            $filePath = $WorkflowPath
        }

        $title = if ($ruleId -and $desc) {
            "$ruleId`: $desc"
        } elseif ($ruleId) {
            $ruleId
        } elseif ($desc) {
            $desc
        } else {
            'Unknown zizmor finding'
        }

        $detail = Remove-Credentials $desc
        if ($filePath) {
            $detail = "$detail (file: $filePath)"
        }

        $findings.Add([PSCustomObject]@{
            Id           = [guid]::NewGuid().ToString()
            Category     = 'CI/CD Security'
            Title        = $title
            Severity     = $severity
            Compliant    = $false
            Detail       = $detail
            Remediation  = ''
            ResourceId   = $filePath
            LearnMoreUrl = $learnMoreUrl
        })
    }

    return [PSCustomObject]@{
        Source   = 'zizmor'
        Status   = 'Success'
        Message  = ''
        Findings = $findings
    }
} catch {
    Write-Warning (Remove-Credentials "zizmor scan failed: $_")
    return [PSCustomObject]@{
        Source   = 'zizmor'
        Status   = 'Failed'
        Message  = Remove-Credentials "$_"
        Findings = @()
    }
} finally {
    if ($cleanupClone) {
        try { & $cleanupClone } catch { Write-Verbose "zizmor clone cleanup failed: $(Remove-Credentials -Text ([string]$_.Exception.Message))" }
    }
}
