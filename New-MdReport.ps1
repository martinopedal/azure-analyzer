#Requires -Version 7.4
<#
.SYNOPSIS
    Generate a Markdown report from azure-analyzer results.
.DESCRIPTION
    Reads output/results.json (or a specified file) and writes a Markdown
    report to output/report.md.
    Sections: summary table, per-category findings, and Fix Now / Plan / Track.
.PARAMETER InputPath
    Path to results.json. Defaults to .\output\results.json.
.PARAMETER OutputPath
    Path for report.md. Defaults to .\output\report.md.
#>
[CmdletBinding()]
param (
    [string] $InputPath = (Join-Path $PSScriptRoot 'output' 'results.json'),
    [string] $OutputPath = (Join-Path $PSScriptRoot 'output' 'report.md'),
    [string] $TriagePath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$sanitizePath = Join-Path $PSScriptRoot 'modules' 'shared' 'Sanitize.ps1'
if (Test-Path $sanitizePath) {
    . $sanitizePath
}
$frameworkMapperPath = Join-Path $PSScriptRoot 'modules' 'shared' 'FrameworkMapper.ps1'
if (Test-Path $frameworkMapperPath) {
    . $frameworkMapperPath
}
if (-not (Get-Command Remove-Credentials -ErrorAction SilentlyContinue)) {
    function Remove-Credentials { param ([string]$Text) return $Text }
}

if (-not (Test-Path $InputPath)) {
    throw "Results file not found: $InputPath. Run Invoke-AzureAnalyzer.ps1 first."
}

$findings = @(Get-Content $InputPath -Raw | ConvertFrom-Json -ErrorAction Stop)

$date = Get-Date -Format 'yyyy-MM-dd HH:mm UTC'
$total = @($findings).Count
$high = @($findings | Where-Object { $_.Severity -eq 'High' }).Count
$medium = @($findings | Where-Object { $_.Severity -eq 'Medium' }).Count
$low = @($findings | Where-Object { $_.Severity -eq 'Low' }).Count
$info = @($findings | Where-Object { $_.Severity -eq 'Info' }).Count
$compliantCount = @($findings | Where-Object { $_.Compliant -eq $true }).Count
$nonCompliantCount = $total - $compliantCount

$lines = [System.Collections.Generic.List[string]]::new()
$lines.Add("# Azure Analyzer Report — $date")
$lines.Add('')

# Run-mode metadata (incremental / scheduled — issue #94)
$runMetadata = $null
$runMetadataPath = Join-Path (Split-Path $InputPath -Parent) 'run-metadata.json'
if (Test-Path $runMetadataPath) {
    try { $runMetadata = Get-Content $runMetadataPath -Raw | ConvertFrom-Json -ErrorAction Stop }
    catch { Write-Warning (Remove-Credentials "Failed to read run-metadata.json: $_") }
}
if ($runMetadata) {
    $rmMode = if ($runMetadata.PSObject.Properties['runMode'] -and $runMetadata.runMode) { [string]$runMetadata.runMode } else { 'Full' }
    $rmSince = if ($runMetadata.PSObject.Properties['sinceUtc'] -and $runMetadata.sinceUtc) { [string]$runMetadata.sinceUtc } else { '' }
    $rmBaseline = if ($runMetadata.PSObject.Properties['baselineUtc'] -and $runMetadata.baselineUtc) { [string]$runMetadata.baselineUtc } else { '' }
    $lines.Add("**Run mode:** $rmMode" + $(if ($rmSince) { " | **Since:** $rmSince" } else { '' }) + $(if ($rmBaseline) { " | **Baseline:** $rmBaseline" } else { '' }))
    $lines.Add('')
}

$lines.Add('## Summary')
$lines.Add('')
$lines.Add('| Metric | Count |')
$lines.Add('|---|---|')
$lines.Add("| Total findings | $total |")
$lines.Add("| Non-compliant | $nonCompliantCount |")
$lines.Add("| Compliant | $compliantCount |")
$lines.Add("| High severity | $high |")
$lines.Add("| Medium severity | $medium |")
$lines.Add("| Low severity | $low |")
$lines.Add("| Info | $info |")
$lines.Add('')

$bySource = $findings | Group-Object -Property Source
$sourceCountMap = @{}
foreach ($sg in $bySource) { $sourceCountMap[$sg.Name] = $sg }

# Load tool status metadata if available (manifest-driven source list)
$manifestPath = Join-Path $PSScriptRoot 'tools' 'tool-manifest.json'
$allSources   = @()
$sourceLabels = @{}
if (Test-Path $manifestPath) {
    try {
        $manifest = Get-Content $manifestPath -Raw | ConvertFrom-Json
        foreach ($t in $manifest.tools) {
            if (-not $t.enabled) { continue }
            $allSources += $t.name
            $sourceLabels[$t.name] = $t.displayName
        }
    } catch {
        Write-Warning "Could not parse tool-manifest.json; falling back to built-in source list. $_"
    }
}
if ($allSources.Count -eq 0) {
    $allSources   = @('azqr','psrule','azgovviz','alz-queries','wara','defender-for-cloud','kubescape','kube-bench','falco','maester','scorecard','ado-connections','identity-correlator','zizmor','gitleaks','trivy')
    $sourceLabels = @{ 'azqr'='Azure Quick Review'; 'psrule'='PSRule'; 'azgovviz'='AzGovViz'; 'alz-queries'='ALZ Queries'; 'wara'='WARA'; 'defender-for-cloud'='Defender for Cloud'; 'kubescape'='Kubescape'; 'kube-bench'='kube-bench'; 'falco'='Falco'; 'maester'='Maester'; 'scorecard'='Scorecard'; 'ado-connections'='ADO Service Connections'; 'identity-correlator'='Identity Correlator'; 'zizmor'='zizmor'; 'gitleaks'='gitleaks'; 'trivy'='Trivy' }
}
$toolStatusMap = @{}
$toolRunModeMap = @{}
if ($runMetadata -and $runMetadata.PSObject.Properties['tools'] -and $runMetadata.tools) {
    foreach ($rt in @($runMetadata.tools)) {
        if ($rt.PSObject.Properties['tool']) {
            $toolRunModeMap[[string]$rt.tool] = if ($rt.PSObject.Properties['runMode']) { [string]$rt.runMode } else { '' }
        }
    }
}
$statusJsonPath = Join-Path (Split-Path $InputPath -Parent) 'tool-status.json'
if (Test-Path $statusJsonPath) {
    try {
        $statusData = @(Get-Content $statusJsonPath -Raw | ConvertFrom-Json -ErrorAction Stop)
        foreach ($ts in $statusData) { $toolStatusMap[$ts.Tool] = $ts.Status }
    } catch { }
}

$lines.Add('### By source')
$lines.Add('')
$lines.Add('| Source | Status | Mode | Findings | Non-compliant |')
$lines.Add('|---|---|---|---|---|')
foreach ($src in $allSources) {
    $label = $sourceLabels[$src]
    $status = if ($toolStatusMap.ContainsKey($src)) { $toolStatusMap[$src] } else { if ($sourceCountMap.ContainsKey($src)) { 'Success' } else { 'Skipped' } }
    $mode   = if ($toolRunModeMap.ContainsKey($src) -and $toolRunModeMap[$src]) { $toolRunModeMap[$src] } else { '-' }
    if ($sourceCountMap.ContainsKey($src)) {
        $grp = $sourceCountMap[$src]
        $nc = @($grp.Group | Where-Object { -not $_.Compliant }).Count
        $lines.Add("| $label | $status | $mode | $($grp.Count) | $nc |")
    } else {
        $lines.Add("| $label | $status | $mode | 0 | 0 |")
    }
}
$lines.Add('')

# AI Triage section
if ($TriagePath -and (Test-Path $TriagePath)) {
    try {
        $td = @(Get-Content $TriagePath -Raw | ConvertFrom-Json -ErrorAction Stop)
        $te = @($td | Where-Object { $null -ne $_.AiPriority } | Sort-Object AiPriority)
        if ($te.Count -gt 0) {
            $lines.Add('## AI-Assisted Triage')
            $lines.Add('')
            $lines.Add('| # | Finding | Severity | Source | Risk | Remediation |')
            $lines.Add('|---|---|---|---|---|---|')
            foreach ($t in $te) {
                $title = ($t.Title -replace '\|', '\\|')
                $risk = ($t.AiRiskContext -replace '\|', '\\|' -replace "`n|`r", ' ')
                $rem = ($t.AiRemediation -replace '\|', '\\|' -replace "`n|`r", ' ')
                $lines.Add("| $($t.AiPriority) | $title | $($t.Severity) | $($t.Source) | $risk | $rem |")
            }
            $lines.Add('')
        }
    } catch { }
}

# Compliance framework coverage
if (Get-Command Get-FrameworkCoverage -ErrorAction SilentlyContinue) {
    try {
        $coverage = @(Get-FrameworkCoverage -Findings $findings)
        if ($coverage.Count -gt 0) {
            $lines.Add('## Compliance coverage')
            $lines.Add('')
            $lines.Add('| Framework | Version | Controls hit | Total controls | Coverage | Status |')
            $lines.Add('|---|---|---:|---:|---:|---|')
            foreach ($c in $coverage) {
                $icon = switch ($c.Status) { 'green' { '🟢' } 'yellow' { '🟡' } 'red' { '🔴' } default { '⚪' } }
                $lines.Add("| $($c.DisplayName) | $($c.Version) | $($c.ControlsHit) | $($c.ControlsTotal) | $($c.PercentCovered)% | $icon |")
            }
            $lines.Add('')
        }
    } catch { }
}

# Per-category sections
$lines.Add('## Findings by category')
$lines.Add('')
$byCategory = $findings | Group-Object -Property Category | Sort-Object Name
foreach ($cat in $byCategory) {
    $lines.Add("### $($cat.Name)")
    $lines.Add('')
    $lines.Add('| Title | Severity | Source | Compliant | Detail | Resource ID | Learn More |')
    $lines.Add('|---|---|---|---|---|---|---|')
    foreach ($f in ($cat.Group | Sort-Object Severity, Title)) {
        $compliantStr = if ($f.Compliant) { 'Yes' } else { 'No' }
        $detail = ($f.Detail -replace '\|', '\\|' -replace "`n|`r", ' ')
        $title = ($f.Title -replace '\|', '\\|' -replace "`n|`r", ' ')
        $resId = ($f.ResourceId -replace '\|', '\\|')
        $learnMore = if ([string]::IsNullOrWhiteSpace($f.LearnMoreUrl)) { '' } else { "[$($f.LearnMoreUrl)]($($f.LearnMoreUrl))" }
        $lines.Add("| $title | $($f.Severity) | $($f.Source) | $compliantStr | $detail | $resId | $learnMore |")
    }
    $lines.Add('')
}

# Action sections
$fixNow = $findings | Where-Object { $_.Severity -eq 'High' -and -not $_.Compliant } | Sort-Object Title
$planFix = $findings | Where-Object { $_.Severity -eq 'Medium' -and -not $_.Compliant } | Sort-Object Title
$track = $findings | Where-Object { ($_.Severity -eq 'Low' -or $_.Severity -eq 'Info') -and -not $_.Compliant } | Sort-Object Title

$lines.Add('## Action plan')
$lines.Add('')
$lines.Add('### Fix now (High, non-compliant)')
$lines.Add('')
if ($fixNow.Count -eq 0) {
    $lines.Add('No high-severity non-compliant findings.')
} else {
    $lines.Add('| Title | Source | Detail | Remediation | Resource ID | Learn More |')
    $lines.Add('|---|---|---|---|---|---|')
    foreach ($f in $fixNow) {
        $title = ($f.Title -replace '\|', '\\|')
        $detail = ($f.Detail -replace '\|', '\\|' -replace "`n|`r", ' ')
        $rem = ($f.Remediation -replace '\|', '\\|')
        $resId = ($f.ResourceId -replace '\|', '\\|')
        $learnMore = if ([string]::IsNullOrWhiteSpace($f.LearnMoreUrl)) { '' } else { "[$($f.LearnMoreUrl)]($($f.LearnMoreUrl))" }
        $lines.Add("| $title | $($f.Source) | $detail | $rem | $resId | $learnMore |")
    }
}
$lines.Add('')

$lines.Add('### Plan to fix (Medium, non-compliant)')
$lines.Add('')
if ($planFix.Count -eq 0) {
    $lines.Add('No medium-severity non-compliant findings.')
} else {
    $lines.Add('| Title | Source | Detail | Resource ID | Learn More |')
    $lines.Add('|---|---|---|---|---|')
    foreach ($f in $planFix) {
        $title = ($f.Title -replace '\|', '\\|')
        $detail = ($f.Detail -replace '\|', '\\|' -replace "`n|`r", ' ')
        $resId = ($f.ResourceId -replace '\|', '\\|')
        $learnMore = if ([string]::IsNullOrWhiteSpace($f.LearnMoreUrl)) { '' } else { "[$($f.LearnMoreUrl)]($($f.LearnMoreUrl))" }
        $lines.Add("| $title | $($f.Source) | $detail | $resId | $learnMore |")
    }
}
$lines.Add('')

$lines.Add('### Track (Low/Info, non-compliant)')
$lines.Add('')
if ($track.Count -eq 0) {
    $lines.Add('No low/info non-compliant findings.')
} else {
    $lines.Add('| Title | Severity | Source | Detail | Resource ID | Learn More |')
    $lines.Add('|---|---|---|---|---|---|')
    foreach ($f in $track) {
        $title = ($f.Title -replace '\|', '\\|')
        $detail = ($f.Detail -replace '\|', '\\|' -replace "`n|`r", ' ')
        $resId = ($f.ResourceId -replace '\|', '\\|')
        $learnMore = if ([string]::IsNullOrWhiteSpace($f.LearnMoreUrl)) { '' } else { "[$($f.LearnMoreUrl)]($($f.LearnMoreUrl))" }
        $lines.Add("| $title | $($f.Severity) | $($f.Source) | $detail | $resId | $learnMore |")
    }
}
$lines.Add('')

try {
    $outputDir = Split-Path $OutputPath -Parent
    if (-not (Test-Path $outputDir)) {
        $null = New-Item -ItemType Directory -Path $outputDir -Force
    }
    $output = Remove-Credentials ($lines -join "`n")
    $output | Set-Content -Path $OutputPath -Encoding UTF8 -NoNewline
} catch {
    Write-Error (Remove-Credentials "Failed to write Markdown report to ${OutputPath}: $_")
    return
}
Write-Host "Markdown report written to: $OutputPath" -ForegroundColor Green
