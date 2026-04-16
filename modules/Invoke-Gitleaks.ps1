#Requires -Version 7.0
<#
.SYNOPSIS
    Wrapper for gitleaks CLI (secrets scanner).
.DESCRIPTION
    Runs the gitleaks CLI against a git repository to detect leaked secrets
    such as API keys, tokens, and passwords in git history.
    If gitleaks is not installed, writes a warning and returns an empty result.
    Never throws -- designed for graceful degradation in the orchestrator.
.PARAMETER RepoPath
    Path to the repository to scan. Defaults to the current directory.
.PARAMETER NoGit
    Switch for scanning non-git directories (uses --no-git flag).
#>
[CmdletBinding()]
param (
    [string] $RepoPath = '.',

    [switch] $NoGit
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Dot-source shared modules for Remove-Credentials and Invoke-WithRetry
$sharedDir = Join-Path (Split-Path $PSScriptRoot -Parent) 'modules' 'shared'
if (-not $sharedDir -or -not (Test-Path $sharedDir)) {
    $sharedDir = Join-Path $PSScriptRoot 'shared'
}
$sanitizePath = Join-Path $sharedDir 'Sanitize.ps1'
if (Test-Path $sanitizePath) { . $sanitizePath }
$retryPath = Join-Path $sharedDir 'Retry.ps1'
if (Test-Path $retryPath) { . $retryPath }

if (-not (Get-Command Remove-Credentials -ErrorAction SilentlyContinue)) {
    function Remove-Credentials { param ([string]$Text) return $Text }
}

function Test-GitleaksInstalled {
    $null -ne (Get-Command gitleaks -ErrorAction SilentlyContinue)
}

if (-not (Test-GitleaksInstalled)) {
    Write-Warning "gitleaks is not installed. Skipping gitleaks scan. Install from https://github.com/gitleaks/gitleaks/releases"
    return [PSCustomObject]@{
        Source   = 'gitleaks'
        Status   = 'Skipped'
        Message  = 'gitleaks CLI not installed. Install from https://github.com/gitleaks/gitleaks/releases'
        Findings = @()
    }
}

try {
    $resolvedPath = Resolve-Path $RepoPath -ErrorAction Stop | Select-Object -ExpandProperty Path
    Write-Verbose "Running gitleaks for path $resolvedPath"

    # gitleaks writes JSON report to a file; use a temp file in the scan directory
    $reportFile = Join-Path $resolvedPath ".gitleaks-report-$([guid]::NewGuid().ToString('N')).json"

    try {
        $gitleaksArgs = @('detect', '--source', $resolvedPath, '--report-format', 'json', '--report-path', $reportFile, '--no-banner', '--exit-code', '0')
        if ($NoGit) {
            $gitleaksArgs += '--no-git'
        }

        $useRetry = Get-Command Invoke-WithRetry -ErrorAction SilentlyContinue
        if ($useRetry) {
            Invoke-WithRetry -ScriptBlock {
                & gitleaks @gitleaksArgs 2>&1 | Out-Null
            }
        } else {
            & gitleaks @gitleaksArgs 2>&1 | Out-Null
        }

        $json = @()
        if (Test-Path $reportFile) {
            $jsonText = Get-Content $reportFile -Raw -ErrorAction SilentlyContinue
            if ($jsonText) {
                try {
                    $json = $jsonText | ConvertFrom-Json -ErrorAction Stop
                } catch {
                    $json = @()
                }
            }
        }
    } finally {
        Remove-Item $reportFile -ErrorAction SilentlyContinue
    }

    $findings = [System.Collections.Generic.List[PSCustomObject]]::new()

    $items = if ($json -is [System.Collections.IEnumerable] -and $json -isnot [string]) {
        @($json)
    } elseif ($null -ne $json) {
        @($json)
    } else {
        @()
    }

    foreach ($item in $items) {
        $ruleId = ''
        if ($item.PSObject.Properties['RuleID'] -and $item.RuleID) {
            $ruleId = [string]$item.RuleID
        }

        $description = ''
        if ($item.PSObject.Properties['Description'] -and $item.Description) {
            $description = [string]$item.Description
        }

        $filePath = ''
        if ($item.PSObject.Properties['File'] -and $item.File) {
            $filePath = [string]$item.File
        }

        $startLine = 0
        if ($item.PSObject.Properties['StartLine'] -and $item.StartLine) {
            $startLine = [int]$item.StartLine
        }

        $commit = ''
        if ($item.PSObject.Properties['Commit'] -and $item.Commit) {
            $commit = [string]$item.Commit
        }

        $fingerprint = ''
        if ($item.PSObject.Properties['Fingerprint'] -and $item.Fingerprint) {
            $fingerprint = [string]$item.Fingerprint
        }

        # Severity: Secret-type findings → High, everything else → Medium
        $severity = 'High'
        if ($item.PSObject.Properties['Tags'] -and $item.Tags) {
            $tags = @($item.Tags)
            $hasSecret = $tags | Where-Object { $_ -match '(?i)secret' }
            if (-not $hasSecret) {
                $severity = 'Medium'
            }
        }

        $title = if ($description -and $filePath) {
            "$description found in $filePath"
        } elseif ($description) {
            $description
        } elseif ($ruleId) {
            "Secret detected: $ruleId"
        } else {
            'Secret detected'
        }

        $commitRef = if ($commit) { $commit.Substring(0, [Math]::Min(7, $commit.Length)) } else { '' }
        $detail = "Rule '$ruleId' matched in file $filePath at line $startLine."
        if ($commitRef) {
            $detail += " Commit: $commitRef."
        }
        $detail = Remove-Credentials $detail

        $findings.Add([PSCustomObject]@{
            Id           = if ($fingerprint) { $fingerprint } else { [guid]::NewGuid().ToString() }
            Category     = 'Secret Detection'
            Title        = $title
            Severity     = $severity
            Compliant    = $false
            Detail       = $detail
            Remediation  = 'Rotate the exposed credential and remove it from git history using git-filter-repo or BFG Repo-Cleaner.'
            ResourceId   = $filePath
            LearnMoreUrl = 'https://github.com/gitleaks/gitleaks'
        })
    }

    return [PSCustomObject]@{
        Source   = 'gitleaks'
        Status   = 'Success'
        Message  = ''
        Findings = $findings
    }
} catch {
    Write-Warning (Remove-Credentials "gitleaks scan failed: $_")
    return [PSCustomObject]@{
        Source   = 'gitleaks'
        Status   = 'Failed'
        Message  = Remove-Credentials "$_"
        Findings = @()
    }
}
