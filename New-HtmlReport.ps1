#Requires -Version 7.4
<#
.SYNOPSIS
    Generate an offline HTML report from azure-analyzer results.
.DESCRIPTION
    Reads output/results.json and writes a single self-contained HTML file
    to output/report.html. No CDN dependencies. All CSS is inline.
.PARAMETER InputPath
    Path to results.json. Defaults to .\output\results.json.
.PARAMETER OutputPath
    Path for report.html. Defaults to .\output\report.html.
.PARAMETER Trend
    Optional array of run-trend objects from Get-RunTrend. When provided, an inline
    SVG sparkline is rendered alongside the delta banner showing NonCompliant counts
    across the last N runs (oldest left, newest right). Omit to suppress the sparkline.
#>
[CmdletBinding()]
param (
    [string] $InputPath = (Join-Path $PSScriptRoot 'output' 'results.json'),
    [string] $OutputPath = (Join-Path $PSScriptRoot 'output' 'report.html'),
    [string] $TriagePath = '',
    [string] $PreviousRun = '',
    [object[]] $Trend = @()
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
$reportDeltaPath = Join-Path $PSScriptRoot 'modules' 'shared' 'ReportDelta.ps1'
if (Test-Path $reportDeltaPath) {
    . $reportDeltaPath
}
if (-not (Get-Command Remove-Credentials -ErrorAction SilentlyContinue)) {
    function Remove-Credentials { param ([string]$Text) return $Text }
}

if (-not (Test-Path $InputPath)) {
    throw "Results file not found: $InputPath. Run Invoke-AzureAnalyzer.ps1 first."
}

$findings = @(Get-Content $InputPath -Raw | ConvertFrom-Json -ErrorAction Stop)

# --- Run-mode metadata (incremental / scheduled — issue #94) ---
$runMetadata = $null
$runMetadataPath = Join-Path (Split-Path $InputPath -Parent) 'run-metadata.json'
if (Test-Path $runMetadataPath) {
    try { $runMetadata = Get-Content $runMetadataPath -Raw | ConvertFrom-Json -ErrorAction Stop }
    catch { Write-Warning (Remove-Credentials "Failed to read run-metadata.json: $_") }
}

# --- Report v2 delta vs previous run ---
$deltaStatus  = @{}
$deltaSummary = $null
$resolvedRows = @()
if ($PreviousRun -and (Test-Path $PreviousRun) -and (Get-Command Get-ReportDelta -ErrorAction SilentlyContinue)) {
    try {
        $prev = @(Get-Content $PreviousRun -Raw | ConvertFrom-Json -ErrorAction Stop)
        $delta = Get-ReportDelta -Current $findings -Previous $prev
        $deltaStatus  = $delta.Status
        $deltaSummary = $delta.Summary
        $resolvedRows = @($delta.Resolved)
        # Fold resolved synthetic rows so they render with status=Resolved badges.
        if ($resolvedRows.Count -gt 0) {
            foreach ($r in $resolvedRows) {
                $r | Add-Member -NotePropertyName Compliant -NotePropertyValue $true -Force
            }
            $findings = @($findings + $resolvedRows)
        }
    } catch {
        Write-Warning (Remove-Credentials "Report delta computation failed: $_")
    }
}

$date = Get-Date -Format 'yyyy-MM-dd HH:mm UTC'
$total = @($findings).Count
$high = @($findings | Where-Object { $_.Severity -eq 'High' -and -not $_.Compliant }).Count
$medium = @($findings | Where-Object { $_.Severity -eq 'Medium' -and -not $_.Compliant }).Count
$low = @($findings | Where-Object { $_.Severity -eq 'Low' -and -not $_.Compliant }).Count
$compliantCount = @($findings | Where-Object { $_.Compliant -eq $true }).Count
$compliantPct = if ($total -gt 0) { [math]::Round(($compliantCount / $total) * 100) } else { 0 }

function HE([string]$s) {
    $s -replace '&', '&amp;' -replace '<', '&lt;' -replace '>', '&gt;' -replace '"', '&quot;'
}

function SeverityClass([string]$s) {
    switch ($s) {
        'High'   { return 'sev-high' }
        'Medium' { return 'sev-medium' }
        'Low'    { return 'sev-low' }
        default  { return 'sev-info' }
    }
}

# --- Load triage data if available ---
$triageFindings = @()
$hasTriage = $false
if ($TriagePath -and (Test-Path $TriagePath)) {
    try {
        $triageFindings = @(Get-Content $TriagePath -Raw | ConvertFrom-Json -ErrorAction Stop)
        $triageFindings = @($triageFindings | Where-Object { $null -ne $_.AiPriority } | Sort-Object AiPriority)
        if ($triageFindings.Count -gt 0) { $hasTriage = $true }
    } catch {
        Write-Warning "Could not load triage data from ${TriagePath}: $_"
    }
}

# --- Per-source breakdown data (manifest-driven) ---
$manifestPath = Join-Path $PSScriptRoot 'tools' 'tool-manifest.json'
$allSources   = @()
$sourceLabels = @{}
$sourceColors = @{}
if (Test-Path $manifestPath) {
    try {
        $manifest = Get-Content $manifestPath -Raw | ConvertFrom-Json
        foreach ($t in $manifest.tools) {
            if (-not $t.enabled) { continue }
            $allSources += $t.name
            $sourceLabels[$t.name] = $t.displayName
            if ($t.PSObject.Properties['report'] -and $t.report.PSObject.Properties['color']) {
                $sourceColors[$t.name] = [string]$t.report.color
            } else {
                $sourceColors[$t.name] = '#546e7a'
            }
        }
    } catch {
        Write-Warning "Could not parse tool-manifest.json; falling back to built-in source list. $_"
    }
}
# Safety net: if manifest is missing, keep the legacy hardcoded set so a
# report can still be generated in degraded environments.
if ($allSources.Count -eq 0) {
    $allSources   = @('azqr','psrule','azgovviz','alz-queries','wara','defender-for-cloud','kubescape','kube-bench','falco','maester','scorecard','ado-connections','identity-correlator','zizmor','gitleaks','trivy')
    $sourceLabels = @{ 'azqr'='Azure Quick Review'; 'psrule'='PSRule'; 'azgovviz'='AzGovViz'; 'alz-queries'='ALZ Queries'; 'wara'='WARA'; 'defender-for-cloud'='Defender for Cloud'; 'kubescape'='Kubescape'; 'kube-bench'='kube-bench'; 'falco'='Falco'; 'maester'='Maester'; 'scorecard'='Scorecard'; 'ado-connections'='ADO Service Connections'; 'identity-correlator'='Identity Correlator'; 'zizmor'='zizmor'; 'gitleaks'='gitleaks'; 'trivy'='Trivy' }
    $sourceColors = @{ 'azqr'='#1565c0'; 'psrule'='#6a1b9a'; 'azgovviz'='#00838f'; 'alz-queries'='#e65100'; 'wara'='#2e7d32'; 'defender-for-cloud'='#0078d4'; 'kubescape'='#7b1fa2'; 'kube-bench'='#5e35b1'; 'falco'='#ef6c00'; 'maester'='#7b1fa2'; 'scorecard'='#ff6f00'; 'ado-connections'='#0277bd'; 'identity-correlator'='#ad1457'; 'zizmor'='#4527a0'; 'gitleaks'='#c62828'; 'trivy'='#00695c' }
}
$sourceGroups = $findings | Group-Object -Property Source
$sourceCountMap = @{}
foreach ($sg in $sourceGroups) { $sourceCountMap[$sg.Name] = $sg.Count }
$maxSourceCount = if ($sourceGroups.Count -gt 0) { ($sourceGroups | Measure-Object -Property Count -Maximum).Maximum } else { 1 }
if ($maxSourceCount -eq 0) { $maxSourceCount = 1 }

# Load tool status metadata if available (written by orchestrator)
$toolStatusMap = @{}
$statusJsonPath = Join-Path (Split-Path $InputPath -Parent) 'tool-status.json'
if (Test-Path $statusJsonPath) {
    try {
        $statusData = @(Get-Content $statusJsonPath -Raw | ConvertFrom-Json -ErrorAction Stop)
        foreach ($ts in $statusData) { $toolStatusMap[$ts.Tool] = $ts.Status }
    } catch {
        Write-Warning "Could not load tool status: $_"
    }
}

$sourcesWithResults = @($sourceGroups | ForEach-Object { $_.Name })
$sourcesSkipped = @($allSources | Where-Object { $_ -notin $sourcesWithResults })

# --- Linkify helper: wrap URLs in anchor tags ---
function Linkify([string]$text) {
    if ([string]::IsNullOrWhiteSpace($text)) { return HE $text }
    $escaped = HE $text
    $escaped -replace '(https?://[^\s&lt;&quot;]+)', '<a href="$1" target="_blank" rel="noopener noreferrer">$1</a>'
}

$rowsJson = ($findings | ForEach-Object {
    @"
{
  id: `"$(HE $_.Id)`",
  source: `"$(HE $_.Source)`",
  category: `"$(HE $_.Category)`",
  title: `"$(HE $_.Title)`",
  severity: `"$(HE $_.Severity)`",
  compliant: $($_.Compliant.ToString().ToLower()),
  detail: `"$(HE $_.Detail)`",
  remediation: `"$(HE $_.Remediation)`",
  resourceId: `"$(HE $_.ResourceId)`",
  learnMoreUrl: `"$(HE $_.LearnMoreUrl)`"
}
"@
}) -join ','

$byCategory = $findings | Group-Object -Property Category | Sort-Object Name
$tableIndex = 0

$categoryHtml = foreach ($cat in $byCategory) {
    $catId = ($cat.Name -replace '[^a-zA-Z0-9]', '-').ToLower()
    $tblId = "tbl-$catId-$tableIndex"
    $tableIndex++
    $catRows = foreach ($f in ($cat.Group | Sort-Object Severity, Title)) {
        $sevClass = SeverityClass $f.Severity
        $sevBorder = "sev-border-$($f.Severity.ToLower())"
        $compliantBool = if ($f.Compliant) { 'true' } else { 'false' }
        $compliantStr = if ($f.Compliant) { '<span class="badge badge-ok">Yes</span>' } else { '<span class="badge badge-fail">No</span>' }
        $remediationHtml = Linkify $f.Remediation
        $resourceIdHtml = HE $f.ResourceId
        $learnMoreHtml = if ([string]::IsNullOrWhiteSpace($f.LearnMoreUrl)) { '' } else { "<a href=`"$(HE $f.LearnMoreUrl)`" target=`"_blank`" rel=`"noopener noreferrer`">Learn more</a>" }
        $rowStatus = ''
        $statusBadge = ''
        if ($deltaSummary) {
            $k = Get-ReportDeltaKey -Row $f
            if ($deltaStatus.ContainsKey($k)) { $rowStatus = $deltaStatus[$k] }
            switch ($rowStatus) {
                'New'       { $statusBadge = ' <span class="badge badge-new">New</span>' }
                'Resolved'  { $statusBadge = ' <span class="badge badge-resolved">Resolved</span>' }
                'Unchanged' { $statusBadge = ' <span class="badge badge-unchanged">Unchanged</span>' }
            }
        }
        "<tr class='$sevBorder' data-severity='$(HE $f.Severity)' data-compliant='$compliantBool' data-source='$(HE $f.Source)' data-status='$(HE $rowStatus)'><td>$(HE $f.Title)$statusBadge</td><td><span class='badge $sevClass'>$(HE $f.Severity)</span></td><td>$(HE $f.Source)</td><td>$compliantStr</td><td>$(HE $f.Detail)</td><td>$remediationHtml</td><td class=`"resource-id`">$resourceIdHtml</td><td>$learnMoreHtml</td></tr>"
    }
    @"
<details id="cat-$catId">
  <summary><strong>$(HE $cat.Name)</strong> <span class="cat-count">($($cat.Count))</span></summary>
  <div class="filter-box no-print"><input type="text" placeholder="Filter rows..." onkeyup="filterTable(this,'$tblId')" class="filter-input"></div>
  <table id="$tblId" class="findings-table sortable">
    <thead>
      <tr>
        <th onclick="sortTable(this)">Title</th>
        <th onclick="sortTable(this)">Severity</th>
        <th onclick="sortTable(this)">Source</th>
        <th onclick="sortTable(this)">Compliant</th>
        <th>Detail</th>
        <th>Remediation</th>
        <th onclick="sortTable(this)">Resource ID</th>
        <th>Learn More</th>
      </tr>
    </thead>
    <tbody>
      $($catRows -join "`n      ")
    </tbody>
  </table>
</details>
"@
}

# --- Per-source horizontal bars ---
$sourceBarHtml = foreach ($src in $allSources) {
    $cnt = if ($sourceCountMap.ContainsKey($src)) { $sourceCountMap[$src] } else { 0 }
    $label = $sourceLabels[$src]
    $color = $sourceColors[$src]
    $widthPct = if ($cnt -gt 0) { [math]::Round(($cnt / $maxSourceCount) * 100) } else { 0 }
    @"
<div class="bar-row">
  <span class="bar-label">$label</span>
  <div class="bar-track">
    <div class="bar-fill" style="width:${widthPct}%;background:$color;"></div>
  </div>
  <span class="bar-count">$cnt</span>
</div>
"@
}

# --- Tool coverage summary (status-aware) ---
$toolCoverageHtml = foreach ($src in $allSources) {
    $label = $sourceLabels[$src]
    $status = if ($toolStatusMap.ContainsKey($src)) { $toolStatusMap[$src] } else { $null }
    if ($status -eq 'Success' -or ($null -eq $status -and $src -in $sourcesWithResults)) {
        "<span class='tool-badge tool-active' title='Ran successfully'>&#x2705; $label</span>"
    } elseif ($status -eq 'Failed') {
        "<span class='tool-badge tool-skipped' title='Failed to run'>&#x274C; $label (failed)</span>"
    } elseif ($status -eq 'Excluded') {
        "<span class='tool-badge tool-skipped' title='Excluded by user'>&#x2796; $label (excluded)</span>"
    } else {
        "<span class='tool-badge tool-skipped' title='Skipped (not configured or prereq missing)'>&#x26A0;&#xFE0F; $label (skipped)</span>"
    }
}

# --- Unique resource count estimate (unique Detail values as proxy) ---
$uniqueResources = @($findings | Select-Object -ExpandProperty Detail -ErrorAction SilentlyContinue | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique).Count
if ($uniqueResources -eq 0) { $uniqueResources = $total }
$toolsUsed = $sourcesWithResults.Count

# --- Compliance framework coverage ---
$complianceHtml = ''
if (Get-Command Get-FrameworkCoverage -ErrorAction SilentlyContinue) {
    try {
        $coverage = @(Get-FrameworkCoverage -Findings $findings)
        if ($coverage.Count -gt 0) {
            $rows = foreach ($c in $coverage) {
                $colorMap = @{ green='#2e7d32'; yellow='#e65100'; red='#d32f2f' }
                $barColor = $colorMap[$c.Status]
                $label = HE "$($c.DisplayName) $($c.Version)"
                @"
<div class='bar-row' data-framework='$(HE $c.Framework)'>
  <span class='bar-label'>$label</span>
  <div class='bar-track'><div class='bar-fill' style='width:$($c.PercentCovered)%;background:$barColor;'></div></div>
  <span class='bar-count'>$($c.ControlsHit) / $($c.ControlsTotal) ($($c.PercentCovered)%)</span>
</div>
"@
            }
            $complianceHtml = @"
<h2>Compliance coverage</h2>
<div class='source-section' id='complianceSection'>
$($rows -join "`n")
</div>
"@
        }
    } catch {
        Write-Warning (Remove-Credentials "Compliance coverage computation failed: $_")
    }
}

$deltaBannerHtml = ''
$runModeBannerHtml = ''
if ($runMetadata) {
    $rmMode = if ($runMetadata.PSObject.Properties['runMode'] -and $runMetadata.runMode) { [string]$runMetadata.runMode } else { 'Full' }
    $rmSince = if ($runMetadata.PSObject.Properties['sinceUtc'] -and $runMetadata.sinceUtc) { [string]$runMetadata.sinceUtc } else { '' }
    $rmBaseline = if ($runMetadata.PSObject.Properties['baselineUtc'] -and $runMetadata.baselineUtc) { [string]$runMetadata.baselineUtc } else { '' }
    $rmModeClass = ($rmMode -replace '\s','').ToLowerInvariant()
    $sinceChip = if ($rmSince) { "<span class='run-chip since'>Since: $(HE $rmSince)</span>" } else { '' }
    $baseChip  = if ($rmBaseline) { "<span class='run-chip baseline'>Baseline: $(HE $rmBaseline)</span>" } else { '' }
    $toolBadges = ''
    if ($runMetadata.PSObject.Properties['tools'] -and $runMetadata.tools) {
        $perTool = foreach ($t in @($runMetadata.tools)) {
            $toolName = if ($t.PSObject.Properties['tool']) { [string]$t.tool } else { '' }
            $toolMode = if ($t.PSObject.Properties['runMode'] -and $t.runMode) { [string]$t.runMode } else { 'Full' }
            $cls = ($toolMode -replace '\s','').ToLowerInvariant()
            "<span class='run-chip mode-$cls' title='$(HE $toolName) - $(HE $toolMode)'>$(HE $toolName): $(HE $toolMode)</span>"
        }
        $toolBadges = $perTool -join ' '
    }
    $runModeBannerHtml = @"
<div class="run-mode-banner" role="region" aria-label="Run mode">
  <strong>Run mode:</strong>
  <span class="run-chip mode-$rmModeClass">$(HE $rmMode)</span>
  $sinceChip
  $baseChip
  <div class="run-tool-badges">$toolBadges</div>
</div>
"@
}
if ($deltaSummary) {
    $netClass = if ($deltaSummary.NetNonCompliantDelta -gt 0) { 'net-up' } elseif ($deltaSummary.NetNonCompliantDelta -lt 0) { 'net-down' } else { 'unchanged' }
    $netSign  = if ($deltaSummary.NetNonCompliantDelta -gt 0) { '+' } else { '' }
    $deltaBannerHtml = @"
<div class="delta-summary" role="region" aria-label="Delta vs previous run">
  <strong>Delta vs previous run:</strong>
  <span class="delta-chip new">$($deltaSummary.New) new</span>
  <span class="delta-chip resolved">$($deltaSummary.Resolved) resolved</span>
  <span class="delta-chip unchanged">$($deltaSummary.Unchanged) unchanged</span>
  <span class="delta-chip $netClass">Net non-compliant: $netSign$($deltaSummary.NetNonCompliantDelta)</span>
</div>
"@
}

# Build inline SVG sparkline when trend data is provided (one point per run).
$sparklineHtml = ''
$trendArr = @($Trend | Where-Object { $_ })
if ($trendArr.Count -ge 2) {
    $svgW   = 200
    $svgH   = 40
    $padX   = 4
    $padY   = 4
    $plotW  = $svgW - 2 * $padX
    $plotH  = $svgH - 2 * $padY
    $vals   = @($trendArr | ForEach-Object { [int]$_.NonCompliant })
    $maxVal = ($vals | Measure-Object -Maximum).Maximum
    if ($maxVal -eq 0) { $maxVal = 1 }
    $step   = if ($vals.Count -gt 1) { $plotW / ($vals.Count - 1) } else { $plotW }
    $points = for ($i = 0; $i -lt $vals.Count; $i++) {
        $x = [math]::Round($padX + $i * $step, 1)
        $y = [math]::Round($padY + $plotH - ($vals[$i] / $maxVal) * $plotH, 1)
        "$x,$y"
    }
    $firstLabel = [string]$trendArr[0].RunId
    $lastLabel  = [string]$trendArr[-1].RunId
    $sparklineHtml = @"
<div class="trend-sparkline-wrap" role="img" aria-label="Trend: non-compliant findings over last $($trendArr.Count) runs">
  <span class="trend-label">Trend ($($trendArr.Count) runs):</span>
  <svg class="trend-sparkline" width="$svgW" height="$svgH" viewBox="0 0 $svgW $svgH" xmlns="http://www.w3.org/2000/svg">
    <polyline points="$($points -join ' ')" fill="none" stroke="#1565c0" stroke-width="1.5" stroke-linejoin="round" stroke-linecap="round"/>
    <text x="$padX" y="$($svgH - 1)" font-size="8" fill="#666">$(HE $firstLabel)</text>
    <text x="$($svgW - $padX)" y="$($svgH - 1)" font-size="8" fill="#666" text-anchor="end">$(HE $lastLabel)</text>
  </svg>
</div>
"@
}

$html = @"
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Azure Analyzer Report</title>
<style>
  *, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }
  body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Arial, sans-serif; font-size: 14px; color: #1a1a1a; background: #f5f5f5; padding: 24px; }
  h1 { font-size: 22px; margin-bottom: 4px; }
  h2 { font-size: 16px; margin: 24px 0 12px; border-bottom: 1px solid #ddd; padding-bottom: 6px; }
  .subtitle { color: #666; font-size: 12px; margin-bottom: 24px; }

  /* Executive summary */
  .exec-summary { background: #fff; border-radius: 8px; padding: 24px 28px; margin-bottom: 24px; box-shadow: 0 2px 6px rgba(0,0,0,0.08); display: flex; gap: 28px; align-items: center; flex-wrap: wrap; }
  .donut { width: 140px; height: 140px; border-radius: 50%; display: flex; align-items: center; justify-content: center; flex-shrink: 0; }
  .donut-inner { width: 90px; height: 90px; border-radius: 50%; background: #fff; display: flex; align-items: center; justify-content: center; font-size: 24px; font-weight: 700; }
  .exec-text { flex: 1; min-width: 200px; }
  .exec-text p { font-size: 15px; line-height: 1.6; color: #333; margin-bottom: 6px; }
  .exec-text .exec-highlight { font-size: 17px; font-weight: 600; color: #1a1a1a; }

  /* Stat cards */
  .cards { display: flex; gap: 12px; flex-wrap: wrap; margin-bottom: 24px; }
  .card { background: #fff; border-radius: 6px; padding: 16px 20px; min-width: 120px; box-shadow: 0 1px 3px rgba(0,0,0,0.08); border: 2px solid transparent; cursor: pointer; transition: border-color 0.2s, box-shadow 0.2s; }
  .card:hover { box-shadow: 0 2px 8px rgba(0,0,0,0.15); }
  .card:focus { outline: 2px solid #1565c0; outline-offset: 2px; }
  .card[aria-pressed="true"] { border-color: #1565c0; box-shadow: 0 2px 8px rgba(21,101,192,0.3); }
  .card-label { font-size: 11px; color: #666; text-transform: uppercase; letter-spacing: 0.5px; }
  .card-value { font-size: 28px; font-weight: 700; margin-top: 2px; }
  .card-total .card-value { color: #1a1a1a; }
  .card-high .card-value { color: #d32f2f; }
  .card-medium .card-value { color: #e65100; }
  .card-low .card-value { color: #f9a825; }
  .card-ok .card-value { color: #2e7d32; }

  /* Per-source bars */
  .source-section { background: #fff; border-radius: 8px; padding: 20px 24px; margin-bottom: 24px; box-shadow: 0 1px 3px rgba(0,0,0,0.06); }
  .bar-row { display: flex; align-items: center; margin-bottom: 8px; }
  .bar-label { width: 130px; font-size: 13px; font-weight: 500; flex-shrink: 0; }
  .bar-track { flex: 1; height: 20px; background: #eee; border-radius: 4px; overflow: hidden; margin: 0 10px; }
  .bar-fill { height: 100%; border-radius: 4px; transition: width 0.3s; }
  .bar-count { width: 40px; text-align: right; font-size: 13px; font-weight: 600; }

  /* Tool coverage */
  .tool-coverage { display: flex; gap: 10px; flex-wrap: wrap; margin-bottom: 24px; }
  .tool-badge { display: inline-block; padding: 6px 14px; border-radius: 5px; font-size: 13px; font-weight: 500; }
  .tool-active { background: #e8f5e9; color: #1b5e20; }
  .tool-skipped { background: #fff3e0; color: #bf360c; }

  /* Findings tables */
  details { background: #fff; border-radius: 6px; margin-bottom: 8px; box-shadow: 0 1px 3px rgba(0,0,0,0.06); }
  summary { padding: 12px 16px; cursor: pointer; user-select: none; font-size: 14px; }
  summary:hover { background: #f9f9f9; }
  .cat-count { font-size: 12px; color: #888; font-weight: 400; }
  .filter-box { padding: 8px 16px 4px; }
  .filter-input { width: 100%; max-width: 360px; padding: 6px 10px; border: 1px solid #ddd; border-radius: 4px; font-size: 13px; }
  .filter-input:focus { outline: none; border-color: #90caf9; box-shadow: 0 0 0 2px rgba(33,150,243,0.15); }
  .findings-table { width: 100%; border-collapse: collapse; margin: 0 0 12px; font-size: 13px; }
  .findings-table th { background: #f0f0f0; padding: 8px 10px; text-align: left; font-weight: 600; cursor: pointer; white-space: nowrap; }
  .findings-table th:hover { background: #e0e0e0; }
  .findings-table td { padding: 7px 10px; border-top: 1px solid #f0f0f0; vertical-align: top; }
  .findings-table tr:nth-child(even) td { background: #fafafa; }
  .findings-table tr.sev-border-high td:first-child { border-left: 3px solid #d32f2f; }
  .findings-table tr.sev-border-medium td:first-child { border-left: 3px solid #e65100; }
  .findings-table tr.sev-border-low td:first-child { border-left: 3px solid #f9a825; }
  .findings-table tr.sev-border-info td:first-child { border-left: 3px solid #bdbdbd; }
  .findings-table td a { color: #1565c0; word-break: break-all; }
  .findings-table td.resource-id { font-size: 11px; max-width: 220px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .findings-table tr:hover td { background: #fafafa; }
  .badge { display: inline-block; padding: 2px 7px; border-radius: 3px; font-size: 11px; font-weight: 600; }
  .sev-high { background: #fde8e8; color: #c62828; }
  .sev-medium { background: #fff3e0; color: #bf360c; }
  .sev-low { background: #fff9c4; color: #827717; }
  .sev-info { background: #eeeeee; color: #555; }
  .badge-ok { background: #e8f5e9; color: #1b5e20; }
  .badge-fail { background: #fce4ec; color: #880e4f; }
  .badge-new { background: #ffebee; color: #b71c1c; }
  .badge-resolved { background: #e8f5e9; color: #1b5e20; }
  .badge-unchanged { background: #eceff1; color: #37474f; }

  /* Run mode banner */
  .run-mode-banner { background: #fff; border-radius: 8px; padding: 14px 20px; margin-bottom: 16px; box-shadow: 0 1px 3px rgba(0,0,0,0.06); display: flex; gap: 12px; flex-wrap: wrap; align-items: center; }
  .run-mode-banner strong { font-size: 14px; }
  .run-chip { display: inline-block; padding: 3px 9px; border-radius: 4px; font-size: 12px; font-weight: 600; background: #eceff1; color: #37474f; }
  .run-chip.mode-full { background: #e3f2fd; color: #0d47a1; }
  .run-chip.mode-incremental { background: #e8f5e9; color: #1b5e20; }
  .run-chip.mode-cached { background: #fff8e1; color: #6d4c41; }
  .run-chip.mode-fullfallback { background: #fff3e0; color: #bf360c; }
  .run-chip.mode-partial { background: #f3e5f5; color: #4a148c; }
  .run-chip.since, .run-chip.baseline { background: #f5f5f5; color: #424242; font-weight: 500; }
  .run-tool-badges { display: flex; flex-wrap: wrap; gap: 6px; width: 100%; margin-top: 4px; }
  /* Delta summary */
  .delta-summary { background: #fff; border-radius: 8px; padding: 16px 20px; margin-bottom: 24px; box-shadow: 0 1px 3px rgba(0,0,0,0.06); display: flex; gap: 20px; flex-wrap: wrap; align-items: center; }
  .delta-summary strong { font-size: 16px; }
  .delta-chip { display: inline-block; padding: 4px 10px; border-radius: 4px; font-size: 13px; font-weight: 600; }
  .delta-chip.new { background: #ffebee; color: #b71c1c; }
  .delta-chip.resolved { background: #e8f5e9; color: #1b5e20; }
  .delta-chip.unchanged { background: #eceff1; color: #37474f; }
  .delta-chip.net-up { background: #ffebee; color: #b71c1c; }
  .delta-chip.net-down { background: #e8f5e9; color: #1b5e20; }
  .trend-sparkline-wrap { background: #fff; border-radius: 8px; padding: 12px 20px; margin-bottom: 24px; box-shadow: 0 1px 3px rgba(0,0,0,0.06); display: flex; gap: 12px; align-items: center; }
  .trend-label { font-size: 13px; font-weight: 600; color: #37474f; white-space: nowrap; }
  .trend-sparkline { display: block; overflow: visible; }

  /* Filter banner */
  .filter-banner { display: none; background: #e3f2fd; padding: 8px 16px; border-radius: 4px; margin-bottom: 16px; font-size: 13px; align-items: center; gap: 8px; }
  .filter-banner.active { display: flex; }
  .filter-banner button { background: #1565c0; color: #fff; border: none; border-radius: 3px; padding: 4px 10px; cursor: pointer; font-size: 12px; }
  .filter-banner button:hover { background: #0d47a1; }

  /* Print-friendly styles */
  @media print {
    body { background: #fff; padding: 12px; }
    .no-print, .filter-box, .filter-input { display: none !important; }
    .findings-table th { cursor: default; }
    .findings-table th:hover { background: #f0f0f0; }
    details { break-inside: avoid; }
    .findings-table tr { page-break-inside: avoid; }
    .exec-summary, .source-section, .card, details { box-shadow: none; border: 1px solid #ddd; }
    a { color: #1a1a1a; text-decoration: underline; }
  }
</style>
</head>
<body>
<h1>Azure Analyzer Report</h1>
<p class="subtitle">Generated: $date</p>

<!-- Executive Summary with Donut Chart -->
<div class="exec-summary">
  <div class="donut" style="background:conic-gradient(#2e7d32 0% $compliantPct%, #d32f2f $compliantPct% 100%);">
    <div class="donut-inner">$compliantPct%</div>
  </div>
  <div class="exec-text">
    <p class="exec-highlight">Scanned $uniqueResources resources across $toolsUsed tools. $compliantPct% compliant overall.</p>
    <p>$high high-severity findings require immediate action.</p>
    <p>$medium medium-severity and $low low-severity findings also detected across $($byCategory.Count) categories.</p>
  </div>
</div>

<div class="cards">
  <button class="card card-total" onclick="filterBySeverity(this,'all')" aria-pressed="false"><div class="card-label">Total findings</div><div class="card-value">$total</div></button>
  <button class="card card-high" onclick="filterBySeverity(this,'High')" aria-pressed="false"><div class="card-label">High (non-compliant)</div><div class="card-value">$high</div></button>
  <button class="card card-medium" onclick="filterBySeverity(this,'Medium')" aria-pressed="false"><div class="card-label">Medium (non-compliant)</div><div class="card-value">$medium</div></button>
  <button class="card card-low" onclick="filterBySeverity(this,'Low')" aria-pressed="false"><div class="card-label">Low (non-compliant)</div><div class="card-value">$low</div></button>
  <button class="card card-ok" onclick="filterBySeverity(this,'compliant')" aria-pressed="false"><div class="card-label">Compliant %</div><div class="card-value">$compliantPct%</div></button>
</div>
<div class="filter-banner" id="filterBanner">
  <span id="filterBannerText"></span>
  <button onclick="clearSeverityFilter()">Clear filter</button>
</div>

$runModeBannerHtml
$deltaBannerHtml

$sparklineHtml

<!-- Per-Source Breakdown -->
<h2>Findings by source</h2>
<div class="source-section">
$($sourceBarHtml -join "`n")
</div>

<!-- Tool Coverage Summary -->
<h2>Tool coverage</h2>
<div class="tool-coverage">
$($toolCoverageHtml -join "`n")
</div>

$complianceHtml

<h2>Findings by category</h2>
$($categoryHtml -join "`n")

<script>
var activeSevFilter = null;
function filterBySeverity(btn, severity) {
  var cards = document.querySelectorAll('.card');
  var rows = document.querySelectorAll('.findings-table tbody tr');
  var banner = document.getElementById('filterBanner');
  var bannerText = document.getElementById('filterBannerText');
  if (activeSevFilter === severity) { clearSeverityFilter(); return; }
  activeSevFilter = severity;
  cards.forEach(function(c) { c.setAttribute('aria-pressed', 'false'); });
  btn.setAttribute('aria-pressed', 'true');
  rows.forEach(function(r) {
    if (severity === 'all') { r.style.display = ''; }
    else if (severity === 'compliant') { r.style.display = r.dataset.compliant === 'true' ? '' : 'none'; }
    else { r.style.display = (r.dataset.severity === severity && r.dataset.compliant === 'false') ? '' : 'none'; }
  });
  bannerText.textContent = severity === 'all' ? 'Showing all findings' : severity === 'compliant' ? 'Showing compliant findings only' : 'Showing ' + severity + ' severity findings only';
  banner.classList.add('active');
}
function clearSeverityFilter() {
  activeSevFilter = null;
  document.querySelectorAll('.card').forEach(function(c) { c.setAttribute('aria-pressed', 'false'); });
  document.querySelectorAll('.findings-table tbody tr').forEach(function(r) { r.style.display = ''; });
  document.getElementById('filterBanner').classList.remove('active');
}
function sortTable(th) {
  const table = th.closest('table');
  const tbody = table.querySelector('tbody');
  const rows = Array.from(tbody.querySelectorAll('tr'));
  const idx = Array.from(th.parentNode.children).indexOf(th);
  const asc = th.dataset.sort !== 'asc';
  th.dataset.sort = asc ? 'asc' : 'desc';
  rows.sort((a, b) => {
    const ta = a.cells[idx].textContent.trim();
    const tb = b.cells[idx].textContent.trim();
    return asc ? ta.localeCompare(tb) : tb.localeCompare(ta);
  });
  rows.forEach(r => tbody.appendChild(r));
}
function filterTable(input, tableId) {
  var filter = input.value.toLowerCase();
  var rows = document.getElementById(tableId).getElementsByTagName('tr');
  for (var i = 1; i < rows.length; i++) {
    rows[i].style.display = rows[i].textContent.toLowerCase().includes(filter) ? '' : 'none';
  }
}
</script>
</body>
</html>
"@

try {
    $outputDir = Split-Path $OutputPath -Parent
    if (-not (Test-Path $outputDir)) {
        $null = New-Item -ItemType Directory -Path $outputDir -Force
    }
    $html = Remove-Credentials $html
    $html | Set-Content -Path $OutputPath -Encoding UTF8
} catch {
    Write-Error (Remove-Credentials "Failed to write HTML report to ${OutputPath}: $_")
    return
}
Write-Host "HTML report written to: $OutputPath" -ForegroundColor Green
