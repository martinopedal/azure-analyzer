#Requires -Version 7.0
<#
.SYNOPSIS
    Wrapper for Aqua Security Trivy CLI.
.DESCRIPTION
    Runs trivy filesystem or repo scan for dependency vulnerabilities and returns
    supply chain security findings as PSObjects. If trivy is not installed, writes
    a warning and returns an empty result.
    Never throws -- designed for graceful degradation in the orchestrator.

    Security: Verify trivy binary integrity. Download from official GitHub
    releases only: https://github.com/aquasecurity/trivy/releases

    JSON output is written to a temp file (--output) to avoid stderr/stdout
    mixing. The temp file is cleaned up in a finally block.
.PARAMETER ScanPath
    Path to scan for vulnerabilities. Defaults to current directory.
.PARAMETER ScanType
    Type of scan to perform: 'fs' (filesystem) or 'repo' (remote repository).
    Defaults to 'fs'.
#>
[CmdletBinding()]
param (
    [string] $ScanPath = '.',

    [ValidateSet('fs', 'repo')]
    [string] $ScanType = 'fs',

    [string] $RemoteUrl
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Dot-source shared modules for Remove-Credentials, Invoke-RemoteRepoClone
$sharedDir = Join-Path (Split-Path $PSScriptRoot -Parent) 'modules' 'shared'
if (-not $sharedDir -or -not (Test-Path $sharedDir)) {
    $sharedDir = Join-Path $PSScriptRoot 'shared'
}
$sanitizePath = Join-Path $sharedDir 'Sanitize.ps1'
if (Test-Path $sanitizePath) { . $sanitizePath }
$remoteClonePath = Join-Path $sharedDir 'RemoteClone.ps1'
if (Test-Path $remoteClonePath) { . $remoteClonePath }

if (-not (Get-Command Remove-Credentials -ErrorAction SilentlyContinue)) {
    function Remove-Credentials { param ([string]$Text) return $Text }
}

# Minimum trivy version known to produce reliable JSON output
$script:MinTrivyVersion = [version]'0.50.0'

function Test-TrivyInstalled {
    $null -ne (Get-Command trivy -ErrorAction SilentlyContinue)
}

function Get-TrivyVersion {
    try {
        $versionOutput = & trivy --version 2>$null
        if ($versionOutput) {
            $versionText = ($versionOutput | Out-String)
            # trivy --version outputs lines like "Version: 0.56.2"
            if ($versionText -match '(\d+\.\d+\.\d+)') {
                return [version]$Matches[1]
            }
        }
    } catch {
        # Ignore version parse failures — proceed with warning
    }
    return $null
}

if (-not (Test-TrivyInstalled)) {
    Write-Warning "trivy is not installed. Skipping Trivy scan. Install from https://github.com/aquasecurity/trivy/releases or: brew install trivy / choco install trivy"
    return [PSCustomObject]@{
        Source   = 'trivy'
        Status   = 'Skipped'
        Message  = 'trivy CLI not installed. Download from https://github.com/aquasecurity/trivy/releases'
        Findings = @()
    }
}

# Version safety check — warn (but proceed) if below minimum known-safe version
$trivyVersion = Get-TrivyVersion
if ($null -ne $trivyVersion -and $trivyVersion -lt $script:MinTrivyVersion) {
    Write-Warning "trivy version $trivyVersion is below the recommended minimum ($script:MinTrivyVersion). Update from https://github.com/aquasecurity/trivy/releases"
}
if ($null -eq $trivyVersion) {
    Write-Warning "Could not determine trivy version. Verify binary integrity — download from https://github.com/aquasecurity/trivy/releases"
}

$cloneInfo = $null
$cleanupClone = $null
try {
    if ($RemoteUrl) {
        if (-not (Get-Command Invoke-RemoteRepoClone -ErrorAction SilentlyContinue)) {
            Write-Warning "RemoteClone helper not loaded; cannot scan remote URL."
            return [PSCustomObject]@{
                Source = 'trivy'; Status = 'Failed'
                Message = 'RemoteClone helper unavailable'; Findings = @()
            }
        }
        $cloneInfo = Invoke-RemoteRepoClone -RepoUrl $RemoteUrl
        if (-not $cloneInfo) {
            return [PSCustomObject]@{
                Source = 'trivy'; Status = 'Failed'
                Message = "Remote clone failed or host not on allow-list: $RemoteUrl"
                Findings = @()
            }
        }
        $cleanupClone = $cloneInfo.Cleanup
        $ScanPath = $cloneInfo.Path
        $ScanType = 'fs'
    }

    Write-Verbose "Running trivy $ScanType scan on '$ScanPath'"

    # Write JSON to a temp file to keep stderr separate from the JSON stream
    $reportFile = Join-Path ([System.IO.Path]::GetTempPath()) "trivy-report-$([guid]::NewGuid().ToString('N')).json"

    try {
        & trivy $ScanType --format json --scanners vuln --output $reportFile $ScanPath 2>&1 | ForEach-Object {
            if ($_ -is [System.Management.Automation.ErrorRecord]) {
                Write-Verbose "trivy stderr: $_"
            }
        }

        $exitCode = $LASTEXITCODE

        # Non-zero exit with no report = hard failure
        if ($exitCode -ne 0 -and -not (Test-Path $reportFile)) {
            Write-Warning (Remove-Credentials "trivy exited with code $exitCode and produced no report")
            return [PSCustomObject]@{
                Source   = 'trivy'
                Status   = 'Failed'
                Message  = (Remove-Credentials "trivy exited with code $exitCode and produced no report")
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
                    Write-Warning (Remove-Credentials "trivy report JSON parse failed: $_")
                    return [PSCustomObject]@{
                        Source   = 'trivy'
                        Status   = 'Failed'
                        Message  = (Remove-Credentials "Report JSON parse failed: $_")
                        Findings = @()
                    }
                }
            }
        }
    } finally {
        Remove-Item $reportFile -Force -ErrorAction SilentlyContinue
    }

    $findings = [System.Collections.Generic.List[PSCustomObject]]::new()

    $results = $null
    if ($null -ne $json -and $json.PSObject.Properties['Results'] -and $json.Results) {
        $results = $json.Results
    }

    if ($results) {
        foreach ($result in $results) {
            $target = ''
            if ($result.PSObject.Properties['Target'] -and $result.Target) {
                $target = $result.Target
            }

            $vulns = $null
            if ($result.PSObject.Properties['Vulnerabilities'] -and $result.Vulnerabilities) {
                $vulns = $result.Vulnerabilities
            }
            if (-not $vulns) { continue }

            foreach ($vuln in $vulns) {
                $cveId = ''
                if ($vuln.PSObject.Properties['VulnerabilityID'] -and $vuln.VulnerabilityID) {
                    $cveId = $vuln.VulnerabilityID
                }

                $pkgName = ''
                if ($vuln.PSObject.Properties['PkgName'] -and $vuln.PkgName) {
                    $pkgName = $vuln.PkgName
                }

                $title = if ($cveId -and $pkgName) { "$cveId ($pkgName)" }
                         elseif ($cveId) { $cveId }
                         elseif ($pkgName) { $pkgName }
                         else { 'Unknown vulnerability' }

                # Map trivy severity (CRITICAL/HIGH/MEDIUM/LOW/UNKNOWN) to schema severity
                $rawSev = ''
                if ($vuln.PSObject.Properties['Severity'] -and $vuln.Severity) {
                    $rawSev = $vuln.Severity
                }
                $severity = switch ($rawSev.ToUpperInvariant()) {
                    'CRITICAL' { 'Critical' }
                    'HIGH'     { 'High' }
                    'MEDIUM'   { 'Medium' }
                    'LOW'      { 'Low' }
                    default    { 'Info' }
                }

                $installedVer = ''
                if ($vuln.PSObject.Properties['InstalledVersion'] -and $vuln.InstalledVersion) {
                    $installedVer = $vuln.InstalledVersion
                }
                $fixedVer = ''
                if ($vuln.PSObject.Properties['FixedVersion'] -and $vuln.FixedVersion) {
                    $fixedVer = $vuln.FixedVersion
                }

                $description = ''
                if ($vuln.PSObject.Properties['Description'] -and $vuln.Description) {
                    $description = $vuln.Description
                }
                $vulnTitle = ''
                if ($vuln.PSObject.Properties['Title'] -and $vuln.Title) {
                    $vulnTitle = $vuln.Title
                }

                # Build detail string
                $detailParts = [System.Collections.Generic.List[string]]::new()
                if ($vulnTitle) { $detailParts.Add($vulnTitle) }
                if ($target) { $detailParts.Add("File: $target") }
                if ($installedVer) { $detailParts.Add("Installed: $installedVer") }
                if ($fixedVer) { $detailParts.Add("Fixed: $fixedVer") }
                if ($description -and -not $vulnTitle) {
                    # Truncate long descriptions
                    $desc = if ($description.Length -gt 200) { $description.Substring(0, 200) + '...' } else { $description }
                    $detailParts.Add($desc)
                }
                $detail = $detailParts -join '. '

                # Build remediation
                $remediation = ''
                if ($fixedVer -and $pkgName) {
                    $remediation = "Upgrade $pkgName to $fixedVer or later."
                } elseif ($fixedVer) {
                    $remediation = "Upgrade to version $fixedVer or later."
                }

                $learnMoreUrl = ''
                if ($vuln.PSObject.Properties['PrimaryURL'] -and $vuln.PrimaryURL) {
                    $learnMoreUrl = $vuln.PrimaryURL
                }

                $findings.Add([PSCustomObject]@{
                    Id           = [guid]::NewGuid().ToString()
                    Category     = 'Supply Chain'
                    Title        = $title
                    Severity     = $severity
                    Compliant    = $false
                    Detail       = $detail
                    Remediation  = $remediation
                    ResourceId   = $ScanPath
                    LearnMoreUrl = $learnMoreUrl
                })
            }
        }
    }

    return [PSCustomObject]@{
        Source   = 'trivy'
        Status   = 'Success'
        Message  = ''
        Findings = $findings
    }
} catch {
    Write-Warning (Remove-Credentials "Trivy scan failed: $_")
    return [PSCustomObject]@{
        Source   = 'trivy'
        Status   = 'Failed'
        Message  = (Remove-Credentials "$_")
        Findings = @()
    }
} finally {
    if ($cleanupClone) {
        try { & $cleanupClone } catch { Write-Verbose (Remove-Credentials "trivy clone cleanup failed: $($_.Exception.Message)") }
    }
}
