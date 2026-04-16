#Requires -Version 7.0
<#
.SYNOPSIS
    Wrapper for gitleaks CLI (secrets scanner).
.DESCRIPTION
    Runs the gitleaks CLI against a git repository to detect leaked secrets
    such as API keys, tokens, and passwords in git history.
    If gitleaks is not installed, writes a warning and returns an empty result.
    Never throws -- designed for graceful degradation in the orchestrator.

    Security: The --redact flag ensures the report file never contains plaintext
    secret values. Secret/Match fields are also stripped during post-processing
    as a defense-in-depth layer. The report is written to the system temp
    directory (not inside the scanned repo).
.PARAMETER RepoPath
    Local repository path fallback when no remote target is provided.
.PARAMETER Repository
    Remote repository identifier/URL for cloud-first scanning
    (e.g. "github.com/org/repo" or "https://github.com/org/repo.git").
.PARAMETER AdoRepoUrl
    Azure DevOps HTTPS repository URL for remote clone mode.
.PARAMETER NoGit
    Switch for scanning non-git directories (uses --no-git flag).
#>
[CmdletBinding()]
param (
    [string] $RepoPath = '.',

    [string] $Repository,

    [string] $AdoRepoUrl,

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
$remoteClonePath = Join-Path $sharedDir 'RemoteClone.ps1'
if ((-not (Get-Command Invoke-RemoteRepoClone -ErrorAction SilentlyContinue)) -and (Test-Path $remoteClonePath)) {
    . $remoteClonePath
}

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

$resolvedRemoteUrl = ''
if ($AdoRepoUrl) {
    $resolvedRemoteUrl = $AdoRepoUrl
} elseif ($Repository) {
    if ($Repository -match '^https://') {
        $resolvedRemoteUrl = $Repository
    } elseif (($Repository -match '^[^/\s]+/[^/\s]+/[^/\s]+$') -and -not (Test-Path -LiteralPath $Repository)) {
        $resolvedRemoteUrl = "https://$Repository"
    } elseif (-not $PSBoundParameters.ContainsKey('RepoPath')) {
        $RepoPath = $Repository
    }
}

$remoteClone = $null
try {
    if ($resolvedRemoteUrl) {
        $cloneFn = Get-Command Invoke-RemoteRepoClone -ErrorAction SilentlyContinue
        if (-not $cloneFn) {
            return [PSCustomObject]@{
                Source   = 'gitleaks'
                Status   = 'Failed'
                Message  = 'Remote clone helper not available (modules/shared/RemoteClone.ps1 not found).'
                Findings = @()
            }
        }

        $remoteClone = Invoke-RemoteRepoClone -RepoUrl $resolvedRemoteUrl
        if (-not $remoteClone -or -not $remoteClone.Path) {
            return [PSCustomObject]@{
                Source   = 'gitleaks'
                Status   = 'Failed'
                Message  = "Failed to clone remote repository '$resolvedRemoteUrl'. Allowed hosts: github.com, dev.azure.com, *.visualstudio.com, *.ghe.com."
                Findings = @()
            }
        }
        $resolvedPath = $remoteClone.Path
    } else {
        $resolvedPath = Resolve-Path $RepoPath -ErrorAction Stop | Select-Object -ExpandProperty Path
    }

    Write-Verbose "Running gitleaks for path $resolvedPath"

    # Write report to system temp dir — never inside the scanned repo
    $reportFile = Join-Path ([System.IO.Path]::GetTempPath()) "gitleaks-report-$([guid]::NewGuid().ToString('N')).json"

    try {
        # --redact: gitleaks replaces secret values with REDACTED in the report so plaintext secrets are never written to disk
        $gitleaksArgs = @('detect', '--source', $resolvedPath, '--report-format', 'json', '--report-path', $reportFile, '--no-banner', '--redact', '--exit-code', '0')
        if ($NoGit) {
            $gitleaksArgs += '--no-git'
        }

        $useRetry = Get-Command Invoke-WithRetry -ErrorAction SilentlyContinue
        if ($useRetry) {
            Invoke-WithRetry -ScriptBlock {
                $stderrLines = & gitleaks @gitleaksArgs 2>&1 | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] }
                if ($stderrLines) {
                    Write-Verbose "gitleaks stderr: $($stderrLines -join '; ')"
                }
            }
        } else {
            $stderrLines = & gitleaks @gitleaksArgs 2>&1 | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] }
            if ($stderrLines) {
                Write-Verbose "gitleaks stderr: $($stderrLines -join '; ')"
            }
        }

        $exitCode = $LASTEXITCODE

        # Validate: non-zero exit code with no report = hard failure
        if ($exitCode -ne 0 -and -not (Test-Path $reportFile)) {
            Write-Warning (Remove-Credentials "gitleaks exited with code $exitCode and produced no report")
            return [PSCustomObject]@{
                Source   = 'gitleaks'
                Status   = 'Failed'
                Message  = Remove-Credentials "gitleaks exited with code $exitCode and produced no report"
                Findings = @()
            }
        }

        $json = @()
        if (Test-Path $reportFile) {
            $jsonText = Get-Content $reportFile -Raw -ErrorAction SilentlyContinue
            if ($jsonText) {
                try {
                    $json = $jsonText | ConvertFrom-Json -ErrorAction Stop
                } catch {
                    Write-Warning (Remove-Credentials "gitleaks report JSON parse failed: $_")
                    return [PSCustomObject]@{
                        Source   = 'gitleaks'
                        Status   = 'Failed'
                        Message  = Remove-Credentials "Report JSON parse failed: $_"
                        Findings = @()
                    }
                }
            }
        } elseif ($exitCode -eq 0) {
            # exit 0 but no report file — gitleaks found nothing; treat as success
            $json = @()
        }
    } finally {
        Remove-Item $reportFile -Force -ErrorAction SilentlyContinue
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

        # Strip Secret/Match fields — defense-in-depth; --redact already replaces values in the report

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
} finally {
    if ($remoteClone -and $remoteClone.Cleanup) {
        & $remoteClone.Cleanup
    }
}
