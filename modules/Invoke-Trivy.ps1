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
$missingToolPath = Join-Path $sharedDir 'MissingTool.ps1'
if (Test-Path $missingToolPath) { . $missingToolPath }
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

function Get-TrivyVersionInfo {
    $raw = ''
    $parsed = $null
    try {
        $versionOutput = & trivy --version 2>$null
        if ($versionOutput) {
            $raw = ($versionOutput | Out-String).Trim()
            # trivy --version outputs lines like "Version: 0.56.2"
            if ($raw -match '(\d+\.\d+\.\d+)') {
                $parsed = [version]$Matches[1]
            }
        }
    } catch {
        # Ignore version parse failures — proceed with warning
    }
    return [PSCustomObject]@{
        ParsedVersion = $parsed
        RawOutput     = $raw
    }
}

function Get-TextArray {
    param([object] $Value)
    if ($null -eq $Value) { return @() }
    if ($Value -is [string]) {
        if ([string]::IsNullOrWhiteSpace($Value)) { return @() }
        return @($Value.Trim())
    }
    if ($Value -is [System.Collections.IEnumerable]) {
        return @($Value | ForEach-Object {
                if ($null -eq $_) { return }
                $candidate = [string]$_
                if (-not [string]::IsNullOrWhiteSpace($candidate)) { $candidate.Trim() }
            } | Where-Object { $_ } | Select-Object -Unique)
    }
    return @([string]$Value)
}

function Get-TrivyScoreDelta {
    param([object] $Vuln)
    $cvss = if ($Vuln.PSObject.Properties['CVSS']) { $Vuln.CVSS } else { $null }
    if ($null -eq $cvss) { return $null }
    foreach ($entry in $cvss.PSObject.Properties) {
        if ($entry.Value -and $entry.Value.PSObject.Properties['V3Score'] -and $null -ne $entry.Value.V3Score) {
            try { return [double]$entry.Value.V3Score } catch { }
        }
        if ($entry.Value -and $entry.Value.PSObject.Properties['Score'] -and $null -ne $entry.Value.Score) {
            try { return [double]$entry.Value.Score } catch { }
        }
    }
    return $null
}

function Get-TrivyLanguageForTarget {
    param([string] $Target)
    if ([string]::IsNullOrWhiteSpace($Target)) { return 'json' }
    $leaf = [System.IO.Path]::GetFileName($Target).ToLowerInvariant()
    if ($leaf -eq 'dockerfile' -or $leaf -like 'dockerfile.*') { return 'dockerfile' }
    if ($leaf -like '*.yaml' -or $leaf -like '*.yml') { return 'yaml' }
    return 'json'
}

function Get-TrivyImpact {
    param([string] $Severity)
    switch (($Severity ?? '').ToUpperInvariant()) {
        'CRITICAL' { return 'High' }
        'HIGH' { return 'High' }
        'MEDIUM' { return 'Medium' }
        'LOW' { return 'Low' }
        default { return 'Low' }
    }
}

function Get-TrivyEntityRefs {
    param(
        [object] $Result,
        [string] $RemoteUrl
    )
    $refs = [System.Collections.Generic.List[string]]::new()
    if (-not [string]::IsNullOrWhiteSpace($RemoteUrl)) { $refs.Add($RemoteUrl) | Out-Null }
    $target = if ($Result.PSObject.Properties['Target']) { [string]$Result.Target } else { '' }
    if (-not [string]::IsNullOrWhiteSpace($target)) { $refs.Add($target) | Out-Null }
    $artifactName = if ($Result.PSObject.Properties['ArtifactName']) { [string]$Result.ArtifactName } else { '' }
    if (-not [string]::IsNullOrWhiteSpace($artifactName)) { $refs.Add($artifactName) | Out-Null }

    if ($target -match '(sha256:[A-Fa-f0-9]{64})') { $refs.Add($Matches[1].ToLowerInvariant()) | Out-Null }
    if ($artifactName -match '(sha256:[A-Fa-f0-9]{64})') { $refs.Add($Matches[1].ToLowerInvariant()) | Out-Null }

    return @($refs | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
}

function Get-TrivyDeepLinkUrl {
    param(
        [string] $CheckId,
        [string] $Class
    )
    if ([string]::IsNullOrWhiteSpace($CheckId)) {
        return if ($Class -eq 'misconfig') {
            'https://aquasecurity.github.io/trivy/latest/docs/scanner/misconfiguration/'
        } else {
            'https://aquasecurity.github.io/trivy/latest/docs/scanner/vulnerability/'
        }
    }
    $id = $CheckId.ToLowerInvariant()
    if ($Class -eq 'misconfig') {
        return "https://aquasecurity.github.io/trivy/latest/docs/scanner/misconfiguration/#$id"
    }
    return "https://aquasecurity.github.io/trivy/latest/docs/scanner/vulnerability/#$id"
}

function Get-TrivyFrameworks {
    param(
        [string] $VulnerabilityId,
        [string[]] $CweIds,
        [string] $IacCheckId
    )
    $frameworks = [System.Collections.Generic.List[hashtable]]::new()
    if ($VulnerabilityId -match '^CVE-') {
        $frameworks.Add(@{ kind = 'CVE'; controlId = $VulnerabilityId.ToUpperInvariant() }) | Out-Null
    } elseif ($VulnerabilityId -match '^GHSA-') {
        $frameworks.Add(@{ kind = 'GHSA'; controlId = $VulnerabilityId.ToUpperInvariant() }) | Out-Null
    }
    foreach ($cwe in @($CweIds)) {
        if ([string]::IsNullOrWhiteSpace($cwe)) { continue }
        $frameworks.Add(@{ kind = 'CWE'; controlId = $cwe.ToUpperInvariant() }) | Out-Null
    }
    if (-not [string]::IsNullOrWhiteSpace($IacCheckId)) {
        $frameworks.Add(@{ kind = 'TrivyIaC'; controlId = $IacCheckId }) | Out-Null
    }
    return @($frameworks | Sort-Object { "$($_.kind)|$($_.controlId)" } -Unique)
}

function Get-TrivyBaselineTags {
    param(
        [string] $Target,
        [string[]] $Texts
    )
    $tags = [System.Collections.Generic.List[string]]::new()
    $isDockerfile = -not [string]::IsNullOrWhiteSpace($Target) -and ([System.IO.Path]::GetFileName($Target).ToLowerInvariant() -like 'dockerfile*')
    if (-not $isDockerfile) { return @() }

    foreach ($text in @($Texts)) {
        if ([string]::IsNullOrWhiteSpace($text)) { continue }
        foreach ($m in [regex]::Matches($text, '(CIS-DI-[0-9.]+)', 'IgnoreCase')) {
            $tags.Add($m.Groups[1].Value.ToUpperInvariant()) | Out-Null
        }
    }
    return @($tags | Select-Object -Unique)
}

function Get-TrivyEvidenceUris {
    param(
        [string] $VulnerabilityId,
        [string] $PrimaryUrl,
        [string[]] $References
    )
    $uris = [System.Collections.Generic.List[string]]::new()
    foreach ($candidate in @($PrimaryUrl) + @($References)) {
        if ([string]::IsNullOrWhiteSpace($candidate)) { continue }
        if ($candidate -match '^https://') { $uris.Add($candidate.Trim()) | Out-Null }
    }

    if ($VulnerabilityId -match '^CVE-(\d{4})-(\d+)$') {
        $uris.Add("https://nvd.nist.gov/vuln/detail/$($VulnerabilityId.ToUpperInvariant())") | Out-Null
    } elseif ($VulnerabilityId -match '^GHSA-') {
        $uris.Add("https://github.com/advisories/$($VulnerabilityId.ToUpperInvariant())") | Out-Null
    }

    return @($uris | Select-Object -Unique)
}

if (-not (Test-TrivyInstalled)) {
    Write-MissingToolNotice -Tool 'trivy' -Message "trivy is not installed. Skipping Trivy scan. Install from https://github.com/aquasecurity/trivy/releases or: brew install trivy / choco install trivy"
    return [PSCustomObject]@{
        Source   = 'trivy'
        SchemaVersion = '1.0'
        Status   = 'Skipped'
        Message  = 'trivy CLI not installed. Download from https://github.com/aquasecurity/trivy/releases'
        Findings = @()
    }
}

# Version safety check — warn (but proceed) if below minimum known-safe version
$trivyVersionInfo = Get-TrivyVersionInfo
$trivyVersion = $trivyVersionInfo.ParsedVersion
$trivyToolVersion = if ($trivyVersionInfo.RawOutput) { $trivyVersionInfo.RawOutput } elseif ($trivyVersion) { "Version: $trivyVersion" } else { '' }
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
                Source = 'trivy'
                SchemaVersion = '1.0'; Status = 'Failed'
                Message = 'RemoteClone helper unavailable'; Findings = @()
            }
        }
        $cloneInfo = Invoke-RemoteRepoClone -RepoUrl $RemoteUrl
        if (-not $cloneInfo) {
            return [PSCustomObject]@{
                Source = 'trivy'
                SchemaVersion = '1.0'; Status = 'Failed'
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
        & trivy $ScanType --format json --scanners vuln,misconfig --output $reportFile $ScanPath 2>&1 | ForEach-Object {
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
                SchemaVersion = '1.0'
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
                    Write-Warning "trivy report JSON parse failed: $(Remove-Credentials -Text ([string]$_))"
                    return [PSCustomObject]@{
                        Source   = 'trivy'
                        SchemaVersion = '1.0'
                        Status   = 'Failed'
                        Message  = Remove-Credentials -Text "Report JSON parse failed: $([string]$_)"
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
            foreach ($vuln in @($vulns)) {
                if ($null -eq $vuln) { continue }
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
                $references = if ($vuln.PSObject.Properties['References']) { Get-TextArray -Value $vuln.References } else { @() }
                $cweIds = if ($vuln.PSObject.Properties['CweIDs']) { Get-TextArray -Value $vuln.CweIDs } elseif ($vuln.PSObject.Properties['CWEIDs']) { Get-TextArray -Value $vuln.CWEIDs } else { @() }
                $frameworks = Get-TrivyFrameworks -VulnerabilityId $cveId -CweIds $cweIds -IacCheckId ''
                $evidenceUris = Get-TrivyEvidenceUris -VulnerabilityId $cveId -PrimaryUrl $learnMoreUrl -References $references
                $baselineTags = Get-TrivyBaselineTags -Target $target -Texts @($detail, $description, $vulnTitle)
                $entityRefs = Get-TrivyEntityRefs -Result $result -RemoteUrl $RemoteUrl
                $deepLinkUrl = Get-TrivyDeepLinkUrl -CheckId $cveId -Class 'vuln'
                $scoreDelta = Get-TrivyScoreDelta -Vuln $vuln
                $effort = if (-not [string]::IsNullOrWhiteSpace($fixedVer)) { 'Low' } else { 'Medium' }
                $impact = Get-TrivyImpact -Severity $rawSev
                $remediationSnippets = @()
                if (-not [string]::IsNullOrWhiteSpace($fixedVer) -and -not [string]::IsNullOrWhiteSpace($pkgName)) {
                    $remediationSnippets = @(
                        @{
                            language = Get-TrivyLanguageForTarget -Target $target
                            before   = if (-not [string]::IsNullOrWhiteSpace($installedVer)) { "${pkgName}:${installedVer}" } else { $pkgName }
                            after    = "${pkgName}:${fixedVer}"
                        }
                    )
                }
                $resourceId = if (-not [string]::IsNullOrWhiteSpace($target)) { $target } else { $ScanPath }
                if ($resourceId -match '(sha256:[A-Fa-f0-9]{64})') { $resourceId = $Matches[1].ToLowerInvariant() }

                $findings.Add([PSCustomObject]@{
                    Id           = [guid]::NewGuid().ToString()
                    Category     = 'Supply Chain'
                    Title        = $title
                    RuleId       = $cveId
                    Severity     = $severity
                    Compliant    = $false
                    Detail       = $detail
                    Remediation  = $remediation
                    ResourceId   = $resourceId
                    LearnMoreUrl = $learnMoreUrl
                    Pillar       = 'Security'
                    Impact       = $impact
                    Effort       = $effort
                    DeepLinkUrl  = $deepLinkUrl
                    RemediationSnippets = @($remediationSnippets)
                    EvidenceUris = @($evidenceUris)
                    BaselineTags = @($baselineTags)
                    ScoreDelta   = $scoreDelta
                    Frameworks   = @($frameworks)
                    EntityRefs   = @($entityRefs)
                    ToolVersion  = $trivyToolVersion
                })
            }

            $misconfigs = $null
            if ($result.PSObject.Properties['Misconfigurations'] -and $result.Misconfigurations) {
                $misconfigs = $result.Misconfigurations
            }
            foreach ($misconfig in @($misconfigs)) {
                if ($null -eq $misconfig) { continue }
                $checkId = if ($misconfig.PSObject.Properties['ID'] -and $misconfig.ID) { [string]$misconfig.ID } else { '' }
                $title = if ($misconfig.PSObject.Properties['Title'] -and $misconfig.Title) { [string]$misconfig.Title } elseif ($checkId) { $checkId } else { 'Unknown misconfiguration' }
                $rawSev = if ($misconfig.PSObject.Properties['Severity'] -and $misconfig.Severity) { [string]$misconfig.Severity } else { 'MEDIUM' }
                $severity = switch ($rawSev.ToUpperInvariant()) {
                    'CRITICAL' { 'Critical' }
                    'HIGH'     { 'High' }
                    'MEDIUM'   { 'Medium' }
                    'LOW'      { 'Low' }
                    default    { 'Info' }
                }
                $description = if ($misconfig.PSObject.Properties['Description'] -and $misconfig.Description) { [string]$misconfig.Description } else { '' }
                $resolution = if ($misconfig.PSObject.Properties['Resolution'] -and $misconfig.Resolution) { [string]$misconfig.Resolution } else { '' }
                $primaryUrl = if ($misconfig.PSObject.Properties['PrimaryURL'] -and $misconfig.PrimaryURL) { [string]$misconfig.PrimaryURL } else { '' }
                $references = if ($misconfig.PSObject.Properties['References']) { Get-TextArray -Value $misconfig.References } else { @() }
                $frameworks = Get-TrivyFrameworks -VulnerabilityId '' -CweIds @() -IacCheckId $checkId
                $evidenceUris = Get-TrivyEvidenceUris -VulnerabilityId '' -PrimaryUrl $primaryUrl -References $references
                $baselineTags = Get-TrivyBaselineTags -Target $target -Texts @($title, $description, $resolution)
                $entityRefs = Get-TrivyEntityRefs -Result $result -RemoteUrl $RemoteUrl
                $resourceId = if (-not [string]::IsNullOrWhiteSpace($target)) { $target } else { $ScanPath }
                if ($resourceId -match '(sha256:[A-Fa-f0-9]{64})') { $resourceId = $Matches[1].ToLowerInvariant() }
                $detail = @(
                    if (-not [string]::IsNullOrWhiteSpace($description)) { $description }
                    if (-not [string]::IsNullOrWhiteSpace($target)) { "File: $target" }
                ) -join '. '

                $findings.Add([PSCustomObject]@{
                    Id           = [guid]::NewGuid().ToString()
                    Category     = 'Supply Chain'
                    Title        = $title
                    RuleId       = $checkId
                    Severity     = $severity
                    Compliant    = $false
                    Detail       = $detail
                    Remediation  = $resolution
                    ResourceId   = $resourceId
                    LearnMoreUrl = $primaryUrl
                    Pillar       = 'Security'
                    Impact       = Get-TrivyImpact -Severity $rawSev
                    Effort       = if (-not [string]::IsNullOrWhiteSpace($resolution)) { 'Low' } else { 'Medium' }
                    DeepLinkUrl  = Get-TrivyDeepLinkUrl -CheckId $checkId -Class 'misconfig'
                    RemediationSnippets = @()
                    EvidenceUris = @($evidenceUris)
                    BaselineTags = @($baselineTags)
                    ScoreDelta   = $null
                    Frameworks   = @($frameworks)
                    EntityRefs   = @($entityRefs)
                    ToolVersion  = $trivyToolVersion
                })
            }
        }
    }

    return [PSCustomObject]@{
        Source   = 'trivy'
        SchemaVersion = '1.0'
        Status   = 'Success'
        Message  = ''
        Findings = $findings
    }
} catch {
    Write-Warning "Trivy scan failed: $(Remove-Credentials -Text ([string]$_))"
    return [PSCustomObject]@{
        Source   = 'trivy'
        SchemaVersion = '1.0'
        Status   = 'Failed'
        Message  = Remove-Credentials -Text ([string]$_)
        Findings = @()
    }
}finally {
    if ($cleanupClone) {
        try { & $cleanupClone } catch { Write-Verbose "trivy clone cleanup failed: $(Remove-Credentials -Text ([string]$_.Exception.Message))" }
    }
}
