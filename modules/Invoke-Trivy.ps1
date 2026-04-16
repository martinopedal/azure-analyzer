#Requires -Version 7.0
<#
.SYNOPSIS
    Wrapper for Aqua Security Trivy CLI.
.DESCRIPTION
    Runs trivy filesystem or repo scan for dependency vulnerabilities and returns
    supply chain security findings as PSObjects. If trivy is not installed, writes
    a warning and returns an empty result.
    Never throws -- designed for graceful degradation in the orchestrator.
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
    [string] $ScanType = 'fs'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Test-TrivyInstalled {
    $null -ne (Get-Command trivy -ErrorAction SilentlyContinue)
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

try {
    Write-Verbose "Running trivy $ScanType scan on '$ScanPath'"
    $rawOutput = trivy $ScanType --format json --scanners vuln $ScanPath 2>&1
    $json = $rawOutput | Out-String | ConvertFrom-Json -ErrorAction Stop

    $findings = [System.Collections.Generic.List[PSCustomObject]]::new()

    $results = $null
    if ($json.PSObject.Properties['Results'] -and $json.Results) {
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
    Write-Warning "Trivy scan failed: $_"
    return [PSCustomObject]@{
        Source   = 'trivy'
        Status   = 'Failed'
        Message  = "$_"
        Findings = @()
    }
}
