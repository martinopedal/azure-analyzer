#Requires -Version 7.0
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
    [string] $OutputPath = (Join-Path $PSScriptRoot 'output' 'report.md')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not (Test-Path $InputPath)) {
    throw "Results file not found: $InputPath. Run Invoke-AzureAnalyzer.ps1 first."
}

$findings = Get-Content $InputPath -Raw | ConvertFrom-Json -ErrorAction Stop

$date = Get-Date -Format 'yyyy-MM-dd HH:mm UTC'
$total = $findings.Count
$high = ($findings | Where-Object { $_.Severity -eq 'High' }).Count
$medium = ($findings | Where-Object { $_.Severity -eq 'Medium' }).Count
$low = ($findings | Where-Object { $_.Severity -eq 'Low' }).Count
$info = ($findings | Where-Object { $_.Severity -eq 'Info' }).Count
$compliantCount = ($findings | Where-Object { $_.Compliant -eq $true }).Count
$nonCompliantCount = $total - $compliantCount

$lines = [System.Collections.Generic.List[string]]::new()
$lines.Add("# Azure Analyzer Report — $date")
$lines.Add('')
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
$lines.Add('### By source')
$lines.Add('')
$lines.Add('| Source | Findings | Non-compliant |')
$lines.Add('|---|---|---|')
foreach ($src in $bySource) {
    $nc = ($src.Group | Where-Object { -not $_.Compliant }).Count
    $lines.Add("| $($src.Name) | $($src.Count) | $nc |")
}
$lines.Add('')

# Per-category sections
$lines.Add('## Findings by category')
$lines.Add('')
$byCategory = $findings | Group-Object -Property Category | Sort-Object Name
foreach ($cat in $byCategory) {
    $lines.Add("### $($cat.Name)")
    $lines.Add('')
    $lines.Add('| Title | Severity | Source | Compliant | Detail |')
    $lines.Add('|---|---|---|---|---|')
    foreach ($f in ($cat.Group | Sort-Object Severity, Title)) {
        $compliantStr = if ($f.Compliant) { 'Yes' } else { 'No' }
        $detail = ($f.Detail -replace '\|', '\\|' -replace "`n|`r", ' ')
        $title = ($f.Title -replace '\|', '\\|' -replace "`n|`r", ' ')
        $lines.Add("| $title | $($f.Severity) | $($f.Source) | $compliantStr | $detail |")
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
    $lines.Add('| Title | Source | Detail | Remediation |')
    $lines.Add('|---|---|---|---|')
    foreach ($f in $fixNow) {
        $title = ($f.Title -replace '\|', '\\|')
        $detail = ($f.Detail -replace '\|', '\\|' -replace "`n|`r", ' ')
        $rem = ($f.Remediation -replace '\|', '\\|')
        $lines.Add("| $title | $($f.Source) | $detail | $rem |")
    }
}
$lines.Add('')

$lines.Add('### Plan to fix (Medium, non-compliant)')
$lines.Add('')
if ($planFix.Count -eq 0) {
    $lines.Add('No medium-severity non-compliant findings.')
} else {
    $lines.Add('| Title | Source | Detail |')
    $lines.Add('|---|---|---|')
    foreach ($f in $planFix) {
        $title = ($f.Title -replace '\|', '\\|')
        $detail = ($f.Detail -replace '\|', '\\|' -replace "`n|`r", ' ')
        $lines.Add("| $title | $($f.Source) | $detail |")
    }
}
$lines.Add('')

$lines.Add('### Track (Low/Info, non-compliant)')
$lines.Add('')
if ($track.Count -eq 0) {
    $lines.Add('No low/info non-compliant findings.')
} else {
    $lines.Add('| Title | Severity | Source | Detail |')
    $lines.Add('|---|---|---|---|')
    foreach ($f in $track) {
        $title = ($f.Title -replace '\|', '\\|')
        $detail = ($f.Detail -replace '\|', '\\|' -replace "`n|`r", ' ')
        $lines.Add("| $title | $($f.Severity) | $($f.Source) | $detail |")
    }
}
$lines.Add('')

$outputDir = Split-Path $OutputPath -Parent
if (-not (Test-Path $outputDir)) {
    $null = New-Item -ItemType Directory -Path $outputDir -Force
}

$lines -join "`n" | Set-Content -Path $OutputPath -Encoding UTF8 -NoNewline
Write-Host "Markdown report written to: $OutputPath" -ForegroundColor Green
