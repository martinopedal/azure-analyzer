#Requires -Version 7.4
<#
.SYNOPSIS
    Generate a single-page executive dashboard (Phase 11 / #97) from current run +
    historical snapshots.

.DESCRIPTION
    Reads:
      - output/results.json            (current run findings)
      - output/history/                (prior snapshots written by RunHistory.ps1)
      - output/entities.json           (optional v3 entity store, for subscription view)
      - tools/framework-mappings.json  (WAF pillar coverage + framework gap)

    Writes a single self-contained dashboard.html (no CDN, inline CSS + inline SVG
    sparklines). Layout follows the issue #97 plan:
      - Compliance score + signed delta tile
      - Severity mix sparklines (Critical/High/Medium/Low/Info)
      - Top-10 risky resources
      - Subscription R/A/G heat map
      - WAF 5-pillar coverage tiles
      - Framework gap analysis table
      - MTTR by severity table
      - Tool execution status row
      - Net change summary (signed deltas)

.PARAMETER InputPath
    Current run results.json. Defaults to .\output\results.json.

.PARAMETER OutputPath
    Path for dashboard.html. Defaults to .\output\dashboard.html.

.PARAMETER HistoryPath
    Override for the history root. Defaults to <InputPath dir>\history.

.PARAMETER EntitiesPath
    Optional v3 entities.json. Defaults to <InputPath dir>\entities.json.

.PARAMETER ToolStatusPath
    Optional tool-status.json. Defaults to <InputPath dir>\tool-status.json.
#>
[CmdletBinding()]
param (
    [string] $InputPath      = (Join-Path $PSScriptRoot 'output' 'results.json'),
    [string] $OutputPath     = (Join-Path $PSScriptRoot 'output' 'dashboard.html'),
    [string] $HistoryPath    = '',
    [string] $EntitiesPath   = '',
    [string] $ToolStatusPath = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Dot-source dependencies (best effort - graceful degradation when missing)
# ---------------------------------------------------------------------------
$sharedDir = Join-Path $PSScriptRoot 'modules' 'shared'
foreach ($mod in @('Sanitize','FrameworkMapper','ReportDelta','RunHistory')) {
    $p = Join-Path $sharedDir "$mod.ps1"
    if (Test-Path $p) { . $p }
}
if (-not (Get-Command Remove-Credentials -ErrorAction SilentlyContinue)) {
    function Remove-Credentials { param ([string]$Text) return $Text }
}

if (-not (Test-Path $InputPath)) {
    throw "Results file not found: $InputPath. Run Invoke-AzureAnalyzer.ps1 first."
}

$inputDir = Split-Path $InputPath -Parent
if (-not $HistoryPath)    { $HistoryPath    = Join-Path $inputDir 'history' }
if (-not $EntitiesPath)   { $EntitiesPath   = Join-Path $inputDir 'entities.json' }
if (-not $ToolStatusPath) { $ToolStatusPath = Join-Path $inputDir 'tool-status.json' }

# ---------------------------------------------------------------------------
# Load data
# ---------------------------------------------------------------------------
$findings = @(Get-Content $InputPath -Raw | ConvertFrom-Json -ErrorAction Stop)
$history  = @()
if (Get-Command Get-RunHistory -ErrorAction SilentlyContinue) {
    $history = @(Get-RunHistory -OutputPath $inputDir -HistoryPath $HistoryPath)
}

$entities = @()
if (Test-Path $EntitiesPath) {
    try { $entities = @(Get-Content $EntitiesPath -Raw | ConvertFrom-Json -ErrorAction Stop) }
    catch { Write-Warning "Could not parse entities.json: $_" }
}

$toolStatus = @()
if (Test-Path $ToolStatusPath) {
    try { $toolStatus = @(Get-Content $ToolStatusPath -Raw | ConvertFrom-Json -ErrorAction Stop) }
    catch { Write-Warning "Could not parse tool-status.json: $_" }
}

# ---------------------------------------------------------------------------
# Derived metrics
# ---------------------------------------------------------------------------
function HE([string]$s) {
    if ($null -eq $s) { return '' }
    $s -replace '&','&amp;' -replace '<','&lt;' -replace '>','&gt;' -replace '"','&quot;' -replace "'", '&#39;'
}

# Whitelist-normalize severity -> lowercase token safe for CSS class interpolation.
# Anything off-list (including tool-injected noise) collapses to 'info'.
function Get-SafeSeverityClass([string]$Raw) {
    if (-not $Raw) { return 'info' }
    switch -Regex ($Raw.ToLowerInvariant()) {
        '^critical$' { return 'critical' }
        '^high$'     { return 'high' }
        '^medium$'   { return 'medium' }
        '^low$'      { return 'low' }
        '^info$'     { return 'info' }
        default      { return 'info' }
    }
}

function Get-SeverityCounts {
    <#
    .SYNOPSIS
        Bucket Critical/High/Medium/Low/Info counts from a finding array.
    .PARAMETER NonCompliantOnly
        When set (default for the dashboard - risk-over-time view), only findings where
        Compliant -eq $false are counted. Off for volume-over-time views.
    #>
    param (
        [object[]] $Rows,
        [switch]   $NonCompliantOnly
    )
    $sev = [ordered]@{ Critical = 0; High = 0; Medium = 0; Low = 0; Info = 0 }
    foreach ($r in $Rows) {
        if (-not $r) { continue }
        if ($NonCompliantOnly) {
            if (-not ($r.PSObject.Properties['Compliant']) -or $r.Compliant) { continue }
        }
        $s = if ($r.PSObject.Properties['Severity']) { [string]$r.Severity } else { '' }
        switch -Regex ($s) {
            '^(?i)critical$' { $sev['Critical']++ ; break }
            '^(?i)high$'     { $sev['High']++ ; break }
            '^(?i)medium$'   { $sev['Medium']++ ; break }
            '^(?i)low$'      { $sev['Low']++ ; break }
            '^(?i)info$'     { $sev['Info']++ ; break }
        }
    }
    return $sev
}

$total          = @($findings).Count
$compliantCount = @($findings | Where-Object { $_.PSObject.Properties['Compliant'] -and $_.Compliant }).Count
$nonCompliant   = $total - $compliantCount
$compliancePct  = if ($total -gt 0) { [math]::Round(($compliantCount / $total) * 100, 1) } else { 0 }
# Risk-over-time view: severity trend uses non-compliant counts for BOTH current + history
# points to keep the sparkline math consistent (fix for PR #149 R1 correctness #1).
$currentSev     = Get-SeverityCounts -Rows $findings -NonCompliantOnly

# Previous run (for delta + signed compliance change)
$prevRun  = if ($history.Count -ge 2) { $history[$history.Count - 2] } else { $null }
$delta    = $null
$prevPct  = $null
if ($prevRun -and (Test-Path $prevRun.ResultsPath)) {
    try {
        $prev = @(Get-Content $prevRun.ResultsPath -Raw | ConvertFrom-Json -ErrorAction Stop)
        if (Get-Command Get-ReportDelta -ErrorAction SilentlyContinue) {
            $delta = Get-ReportDelta -Current $findings -Previous $prev
        }
        $prevTotal = @($prev).Count
        $prevComp  = @($prev | Where-Object { $_.PSObject.Properties['Compliant'] -and $_.Compliant }).Count
        if ($prevTotal -gt 0) { $prevPct = [math]::Round(($prevComp / $prevTotal) * 100, 1) }
    } catch {
        Write-Warning (Remove-Credentials "Delta computation failed: $_")
    }
}
$pctDelta = if ($null -ne $prevPct) { [math]::Round($compliancePct - $prevPct, 1) } else { $null }

# Build per-run severity history using non-compliant counts ONLY for both history +
# current point (risk-over-time). Prefer run-meta.NonCompliantSeverityCounts; fall back
# to recomputing from the snapshot's results.json when the meta predates schema 1.1.
$historyPoints = [System.Collections.Generic.List[object]]::new()
foreach ($h in $history) {
    $sev = $null
    $sc = $null
    if ($h.Meta -and $h.Meta.PSObject.Properties['NonCompliantSeverityCounts']) {
        $sc = $h.Meta.NonCompliantSeverityCounts
    }
    if ($sc) {
        $sev = [ordered]@{
            Critical = if ($sc.PSObject.Properties['Critical']) { [int]$sc.Critical } else { 0 }
            High     = if ($sc.PSObject.Properties['High'])     { [int]$sc.High }     else { 0 }
            Medium   = if ($sc.PSObject.Properties['Medium'])   { [int]$sc.Medium }   else { 0 }
            Low      = if ($sc.PSObject.Properties['Low'])      { [int]$sc.Low }      else { 0 }
            Info     = if ($sc.PSObject.Properties['Info'])     { [int]$sc.Info }     else { 0 }
        }
    } else {
        # Older snapshot (pre schema 1.1) - recompute non-compliant counts from the snapshot rows
        # so the trend line stays apples-to-apples with the current run.
        try {
            $rows = @(Get-Content $h.ResultsPath -Raw | ConvertFrom-Json -ErrorAction Stop)
            $sev = Get-SeverityCounts -Rows $rows -NonCompliantOnly
        } catch { $sev = [ordered]@{ Critical = 0; High = 0; Medium = 0; Low = 0; Info = 0 } }
    }
    $historyPoints.Add([pscustomobject]@{ Stamp = $h.Stamp; Timestamp = $h.Timestamp; Severity = $sev }) | Out-Null
}
# Always include current run as the latest point (it may not yet be snapshotted)
$lastStamp = if ($historyPoints.Count -gt 0) { $historyPoints[-1].Stamp } else { '' }
$nowStamp  = (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd-HHmmss')
if ($lastStamp -ne $nowStamp) {
    $historyPoints.Add([pscustomobject]@{ Stamp = 'current'; Timestamp = (Get-Date).ToUniversalTime(); Severity = $currentSev }) | Out-Null
}

# Top-10 risky resources
$riskBySev = @{ Critical = 4; High = 3; Medium = 2; Low = 1; Info = 0 }
$resourceGroups = @{}
foreach ($f in $findings) {
    if (-not $f) { continue }
    if ($f.PSObject.Properties['Compliant'] -and $f.Compliant) { continue }
    $rid = if ($f.PSObject.Properties['ResourceId'] -and $f.ResourceId) {
        [string]$f.ResourceId
    } elseif ($f.PSObject.Properties['EntityId'] -and $f.EntityId) {
        [string]$f.EntityId
    } else { '' }
    if (-not $rid) { continue }
    $sev = if ($f.PSObject.Properties['Severity']) { [string]$f.Severity } else { '' }
    $score = 0
    foreach ($k in $riskBySev.Keys) { if ($sev -match "^(?i)$k$") { $score = $riskBySev[$k]; break } }
    if (-not $resourceGroups.ContainsKey($rid)) {
        $resourceGroups[$rid] = [pscustomobject]@{
            ResourceId    = $rid
            FindingCount  = 0
            HighestSev    = ''
            HighestScore  = -1
            Sources       = [System.Collections.Generic.HashSet[string]]::new()
        }
    }
    $g = $resourceGroups[$rid]
    $g.FindingCount++
    if ($score -gt $g.HighestScore) {
        $g.HighestScore = $score
        $g.HighestSev   = $sev
    }
    if ($f.PSObject.Properties['Source'] -and $f.Source) { [void]$g.Sources.Add([string]$f.Source) }
}
# Acceptance criterion (issue #97): Top-10 is sorted by finding count descending.
# HighestScore is only used as a tiebreaker so that equal-count rows order by severity.
$topResources = @($resourceGroups.Values |
    Sort-Object -Property @{ Expression = 'FindingCount'; Descending = $true }, @{ Expression = 'HighestScore'; Descending = $true } |
    Select-Object -First 10)

# Subscription heat map (group by subscription GUID parsed from /subscriptions/{guid}/...)
$subAggs = @{}
foreach ($f in $findings) {
    if (-not $f) { continue }
    $rid = if ($f.PSObject.Properties['ResourceId']) { [string]$f.ResourceId } else { '' }
    if (-not $rid) { continue }
    if ($rid -notmatch '/subscriptions/([0-9a-fA-F-]{36})') { continue }
    $sub = $Matches[1].ToLowerInvariant()
    if (-not $subAggs.ContainsKey($sub)) {
        $subAggs[$sub] = [pscustomobject]@{
            SubscriptionId = $sub
            Total          = 0
            NonCompliant   = 0
            Critical       = 0
            High           = 0
        }
    }
    $a = $subAggs[$sub]
    $a.Total++
    if ($f.PSObject.Properties['Compliant'] -and -not $f.Compliant) {
        $a.NonCompliant++
        $sev = if ($f.PSObject.Properties['Severity']) { [string]$f.Severity } else { '' }
        if ($sev -match '^(?i)critical$') { $a.Critical++ }
        elseif ($sev -match '^(?i)high$') { $a.High++ }
    }
}
$subRows = @($subAggs.Values | Sort-Object -Property @{ Expression = 'Critical'; Descending = $true }, @{ Expression = 'High'; Descending = $true }, @{ Expression = 'NonCompliant'; Descending = $true })

# WAF pillar coverage. Compare each pillar's coverage % vs the previous snapshot so we can
# render an up/down/flat trend arrow (issue #97 acceptance: "coverage % and up/down trend").
$wafRows = @()
$prevWafByPillar = @{}
if ($findings -and @($findings).Count -gt 0 -and (Get-Command Get-WafPillarCoverage -ErrorAction SilentlyContinue)) {
    try { $wafRows = @(Get-WafPillarCoverage -Findings $findings) } catch { Write-Warning "WAF coverage failed: $_" }
    if ($prevRun -and (Test-Path $prevRun.ResultsPath)) {
        try {
            $prevFindings = @(Get-Content $prevRun.ResultsPath -Raw | ConvertFrom-Json -ErrorAction Stop)
            $prevWafRows = @(Get-WafPillarCoverage -Findings $prevFindings)
            foreach ($r in $prevWafRows) { $prevWafByPillar[$r.Pillar] = $r }
        } catch {
            Write-Warning (Remove-Credentials "Previous WAF coverage computation failed: $_")
        }
    }
}
foreach ($r in $wafRows) {
    $prev = if ($prevWafByPillar.ContainsKey($r.Pillar)) { $prevWafByPillar[$r.Pillar] } else { $null }
    $trend = 'flat'
    $trendGlyph = '→'
    $trendDelta = $null
    if ($prev) {
        $d = [math]::Round($r.CoveragePercent - $prev.CoveragePercent, 1)
        $trendDelta = $d
        if     ($d -gt 0) { $trend = 'up';   $trendGlyph = '↑' }
        elseif ($d -lt 0) { $trend = 'down'; $trendGlyph = '↓' }
    }
    $r | Add-Member -NotePropertyName Trend      -NotePropertyValue $trend      -Force
    $r | Add-Member -NotePropertyName TrendGlyph -NotePropertyValue $trendGlyph -Force
    $r | Add-Member -NotePropertyName TrendDelta -NotePropertyValue $trendDelta -Force
}

# Framework gap analysis
$frameworkRows = @()
if ($findings -and @($findings).Count -gt 0 -and (Get-Command Get-FrameworkCoverage -ErrorAction SilentlyContinue)) {
    try { $frameworkRows = @(Get-FrameworkCoverage -Findings $findings) } catch { Write-Warning "Framework coverage failed: $_" }
}

# MTTR
$mttrRows = @()
if (Get-Command Get-MttrBySeverity -ErrorAction SilentlyContinue) {
    try { $mttrRows = @(Get-MttrBySeverity -History $history) } catch { Write-Warning "MTTR computation failed: $_" }
}

# ---------------------------------------------------------------------------
# Inline SVG sparkline helper
# ---------------------------------------------------------------------------
function New-Sparkline {
    param (
        [int[]] $Values,
        [int]   $Width  = 120,
        [int]   $Height = 28,
        [string]$Color  = '#0078d4'
    )
    if (-not $Values -or $Values.Count -eq 0) {
        return "<span class='spark-na'>no data</span>"
    }
    if ($Values.Count -eq 1) {
        return "<svg width='$Width' height='$Height' viewBox='0 0 $Width $Height' xmlns='http://www.w3.org/2000/svg'><line x1='0' y1='$($Height/2)' x2='$Width' y2='$($Height/2)' stroke='$Color' stroke-width='2'/><circle cx='$($Width/2)' cy='$($Height/2)' r='3' fill='$Color'/></svg>"
    }
    $max = ($Values | Measure-Object -Maximum).Maximum
    $min = ($Values | Measure-Object -Minimum).Minimum
    if ($max -eq $min) { $max = $min + 1 }
    $stepX = if ($Values.Count -gt 1) { $Width / ($Values.Count - 1) } else { 0 }
    $points = for ($i = 0; $i -lt $Values.Count; $i++) {
        $x = [math]::Round($i * $stepX, 2)
        $y = [math]::Round($Height - (($Values[$i] - $min) / ($max - $min)) * ($Height - 4) - 2, 2)
        "$x,$y"
    }
    $polyline = ($points -join ' ')
    $lastX = ($points[-1] -split ',')[0]
    $lastY = ($points[-1] -split ',')[1]
    return "<svg width='$Width' height='$Height' viewBox='0 0 $Width $Height' xmlns='http://www.w3.org/2000/svg'><polyline points='$polyline' fill='none' stroke='$Color' stroke-width='1.6'/><circle cx='$lastX' cy='$lastY' r='2.5' fill='$Color'/></svg>"
}

function Format-SignedDelta([double] $Val, [string] $Suffix = '') {
    if ($Val -gt 0) { return "+{0}{1}" -f $Val, $Suffix }
    if ($Val -lt 0) { return "{0}{1}"  -f $Val, $Suffix }
    return "0$Suffix"
}

# ---------------------------------------------------------------------------
# Compose HTML
# ---------------------------------------------------------------------------
$date = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd HH:mm 'UTC'")

$severitiesForTrend = @('Critical','High','Medium','Low','Info')
$sevColor = @{
    Critical = '#a80000'
    High     = '#d83b01'
    Medium   = '#ca5010'
    Low      = '#107c10'
    Info     = '#5c5c5c'
}

$sparklinesHtml = ($severitiesForTrend | ForEach-Object {
    $sev = $_
    $vals = @($historyPoints | ForEach-Object { [int]$_.Severity[$sev] })
    $latest = if ($vals.Count -gt 0) { $vals[-1] } else { 0 }
    @"
  <div class="spark-row">
    <span class="spark-label" style="color:$($sevColor[$sev])">$sev</span>
    <span class="spark-svg">$(New-Sparkline -Values $vals -Color $sevColor[$sev])</span>
    <span class="spark-val">$latest</span>
  </div>
"@
}) -join ''

$topResourcesRows = ($topResources | ForEach-Object {
    $sevBadge = if ($_.HighestSev) { $_.HighestSev } else { '-' }
    $sevClass = Get-SafeSeverityClass $_.HighestSev
    $srcs = ($_.Sources | Sort-Object) -join ', '
    @"
    <tr>
      <td class="ridcol" title="$(HE $_.ResourceId)">$(HE $_.ResourceId)</td>
      <td>$([int]$_.FindingCount)</td>
      <td><span class="sev sev-$sevClass">$(HE $sevBadge)</span></td>
      <td class="src">$(HE $srcs)</td>
    </tr>
"@
}) -join ''
if (-not $topResourcesRows) { $topResourcesRows = "<tr><td colspan='4' class='empty'>No non-compliant resources in current run.</td></tr>" }

function Get-SubStatus($a) {
    if ($a.Critical -gt 0)        { return 'red' }
    if ($a.High -gt 0)            { return 'amber' }
    if ($a.NonCompliant -gt 0)    { return 'amber' }
    return 'green'
}
$subTilesHtml = ($subRows | ForEach-Object {
    $status = Get-SubStatus $_
    @"
    <div class="sub-tile sub-$status">
      <div class="sub-id" title="$(HE $_.SubscriptionId)">$(HE ($_.SubscriptionId.Substring(0, [math]::Min(8, $_.SubscriptionId.Length))))…</div>
      <div class="sub-counts">
        <span class="cnt-c">C: $($_.Critical)</span>
        <span class="cnt-h">H: $($_.High)</span>
        <span class="cnt-n">N/C: $($_.NonCompliant)</span>
      </div>
    </div>
"@
}) -join ''
if (-not $subTilesHtml) { $subTilesHtml = "<div class='empty'>No subscription-scoped findings in current run.</div>" }

$wafTilesHtml = ($wafRows | ForEach-Object {
    $statusClass = "waf-$($_.Status)"
    $trendClass  = "trend-$($_.Trend)"
    $trendTitle  = if ($null -eq $_.TrendDelta) { 'no prior run' } else {
        $sign = if ($_.TrendDelta -ge 0) { '+' } else { '' }
        "$sign$($_.TrendDelta)% vs previous run"
    }
    @"
    <div class="waf-tile $statusClass" style="border-top-color:$($_.Color)">
      <div class="waf-name">$(HE $_.DisplayName)</div>
      <div class="waf-num">$($_.CoveragePercent)% <span class="waf-trend $trendClass" title="$(HE $trendTitle)">$($_.TrendGlyph)</span></div>
      <div class="waf-sub">$($_.NonCompliant) non-compliant of $($_.Total) • $($_.CriticalHigh) C/H</div>
    </div>
"@
}) -join ''
if (-not $wafTilesHtml) { $wafTilesHtml = "<div class='empty'>WAF mappings not loaded.</div>" }

$frameworkTableRows = ($frameworkRows | ForEach-Object {
    @"
    <tr>
      <td>$(HE $_.DisplayName) <span class="muted">v$(HE $_.Version)</span></td>
      <td>$($_.ControlsHit) / $($_.ControlsTotal)</td>
      <td><span class="cov cov-$($_.Status)">$($_.PercentCovered)%</span></td>
    </tr>
"@
}) -join ''
if (-not $frameworkTableRows) { $frameworkTableRows = "<tr><td colspan='3' class='empty'>No framework mappings loaded.</td></tr>" }

$mttrTableRows = ($mttrRows | ForEach-Object {
    $median = if ($null -eq $_.MedianDays) { 'N/A' } else { "$($_.MedianDays) d" }
    $mean   = if ($null -eq $_.MeanDays)   { 'N/A' } else { "$($_.MeanDays) d" }
    $sevClass = Get-SafeSeverityClass $_.Severity
    @"
    <tr>
      <td><span class="sev sev-$sevClass">$(HE $_.Severity)</span></td>
      <td>$($_.ResolvedCount)</td>
      <td>$median</td>
      <td>$mean</td>
    </tr>
"@
}) -join ''
if (-not $mttrTableRows) { $mttrTableRows = "<tr><td colspan='4' class='empty'>Run history insufficient - MTTR available after 2+ runs with resolved findings.</td></tr>" }

$toolStatusHtml = ''
if ($toolStatus -and @($toolStatus).Count -gt 0) {
    $toolStatusHtml = ($toolStatus | ForEach-Object {
        $status = if ($_.PSObject.Properties['Status']) { [string]$_.Status } else { 'unknown' }
        $name   = if ($_.PSObject.Properties['Tool'])   { [string]$_.Tool }
                  elseif ($_.PSObject.Properties['Name']) { [string]$_.Name }
                  else { 'tool' }
        $cls = switch -Regex ($status) {
            '^(?i)success$|^(?i)ok$' { 'tool-ok' }
            '^(?i)skip'              { 'tool-skip' }
            '^(?i)fail|error'        { 'tool-fail' }
            default                  { 'tool-other' }
        }
        "<span class='tool-pill $cls'>$(HE $name): $(HE $status)</span>"
    }) -join ''
}
if (-not $toolStatusHtml) { $toolStatusHtml = "<span class='muted'>tool-status.json not available.</span>" }

# Net-change summary
$netNew = if ($delta) { [int]$delta.Summary.New } else { 0 }
$netRes = if ($delta) { [int]$delta.Summary.Resolved } else { 0 }
$netNet = if ($delta) { [int]$delta.Summary.NetNonCompliantDelta } else { 0 }
$netHtml = if ($delta) {
    @"
    <div class="net-row">
      <span class="net-new">+$netNew new</span>
      <span class="net-res">-$netRes resolved</span>
      <span class="net-net">net $(Format-SignedDelta $netNet)</span>
      <span class="muted">vs $(HE $prevRun.Stamp)</span>
    </div>
"@
} else {
    "<div class='net-row muted'>No prior run available - first snapshot.</div>"
}

$pctDeltaHtml = if ($null -ne $pctDelta) {
    $cls = if ($pctDelta -ge 0) { 'delta-up' } else { 'delta-down' }
    "<span class='pct-delta $cls'>$(Format-SignedDelta $pctDelta '%') vs prev</span>"
} else {
    "<span class='muted'>first run</span>"
}

$historyCount = $historyPoints.Count

$html = @"
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>azure-analyzer - Executive Dashboard</title>
<style>
  * { box-sizing: border-box; }
  body { font-family: 'Segoe UI', Arial, sans-serif; margin: 0; background: #f3f4f6; color: #1f2328; }
  header { background: #0b1220; color: #fff; padding: 18px 28px; display: flex; justify-content: space-between; align-items: center; }
  header h1 { margin: 0; font-size: 20px; font-weight: 600; }
  header .meta { font-size: 12px; opacity: 0.85; }
  main { padding: 20px 28px; max-width: 1400px; margin: 0 auto; }
  .grid { display: grid; gap: 16px; }
  .grid-top { grid-template-columns: minmax(280px, 1fr) 2fr; }
  .grid-mid { grid-template-columns: 1fr 1fr; }
  .grid-bot { grid-template-columns: 1.2fr 1fr 1fr; }
  .card { background: #fff; border-radius: 8px; padding: 16px 18px; box-shadow: 0 1px 2px rgba(0,0,0,0.06); }
  .card h2 { margin: 0 0 10px; font-size: 13px; text-transform: uppercase; letter-spacing: 0.05em; color: #57606a; font-weight: 600; }
  .score { display: flex; align-items: baseline; gap: 12px; }
  .score .num { font-size: 56px; font-weight: 700; color: #0b1220; line-height: 1; }
  .score .pct { font-size: 24px; color: #57606a; }
  .pct-delta { font-size: 13px; padding: 2px 8px; border-radius: 12px; font-weight: 600; }
  .delta-up   { background: #dcfce7; color: #14532d; }
  .delta-down { background: #fee2e2; color: #7f1d1d; }
  .muted { color: #6b7280; font-size: 12px; }
  .spark-row { display: grid; grid-template-columns: 70px 130px 50px; align-items: center; padding: 4px 0; font-size: 13px; }
  .spark-label { font-weight: 600; }
  .spark-val { text-align: right; color: #1f2328; font-variant-numeric: tabular-nums; }
  .spark-na { color: #9ca3af; font-size: 11px; }
  table { width: 100%; border-collapse: collapse; font-size: 12px; }
  th { text-align: left; padding: 6px 8px; border-bottom: 1px solid #e5e7eb; color: #57606a; font-weight: 600; }
  td { padding: 6px 8px; border-bottom: 1px solid #f3f4f6; vertical-align: top; }
  td.ridcol { font-family: ui-monospace, Consolas, monospace; max-width: 380px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  td.src { color: #57606a; font-size: 11px; }
  td.empty, .empty { color: #9ca3af; font-style: italic; padding: 12px; }
  .sev { padding: 1px 8px; border-radius: 10px; font-size: 11px; font-weight: 600; color: #fff; display: inline-block; }
  .sev-critical { background: #a80000; }
  .sev-high { background: #d83b01; }
  .sev-medium { background: #ca5010; }
  .sev-low { background: #107c10; }
  .sev-info { background: #6b7280; }
  .cov { padding: 1px 8px; border-radius: 10px; font-size: 11px; font-weight: 600; color: #fff; }
  .cov-green  { background: #107c10; }
  .cov-yellow { background: #ca5010; }
  .cov-red    { background: #a80000; }
  .sub-grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(170px, 1fr)); gap: 10px; }
  .sub-tile { padding: 10px 12px; border-radius: 6px; border-left: 4px solid #ccc; background: #f9fafb; }
  .sub-tile.sub-red   { border-left-color: #a80000; background: #fef2f2; }
  .sub-tile.sub-amber { border-left-color: #d97706; background: #fff7ed; }
  .sub-tile.sub-green { border-left-color: #107c10; background: #f0fdf4; }
  .sub-id { font-family: ui-monospace, Consolas, monospace; font-size: 11px; color: #1f2328; }
  .sub-counts { font-size: 11px; margin-top: 4px; display: flex; gap: 8px; }
  .sub-counts .cnt-c { color: #a80000; font-weight: 600; }
  .sub-counts .cnt-h { color: #d83b01; font-weight: 600; }
  .sub-counts .cnt-n { color: #57606a; }
  .waf-grid { display: grid; grid-template-columns: repeat(5, 1fr); gap: 10px; }
  .waf-tile { padding: 12px; border-radius: 6px; background: #f9fafb; border-top: 4px solid #ccc; text-align: center; }
  .waf-tile.waf-red   { background: #fef2f2; }
  .waf-tile.waf-amber { background: #fff7ed; }
  .waf-tile.waf-green { background: #f0fdf4; }
  .waf-name { font-size: 11px; font-weight: 600; color: #57606a; text-transform: uppercase; }
  .waf-num  { font-size: 28px; font-weight: 700; color: #1f2328; margin: 4px 0; }
  .waf-sub  { font-size: 10px; color: #6b7280; }
  .waf-trend { font-size: 16px; vertical-align: middle; margin-left: 4px; }
  .trend-up   { color: #1a7f37; }
  .trend-down { color: #cf222e; }
  .trend-flat { color: #6b7280; }
  .card-sub { margin: -4px 0 8px; }
  .net-row { display: flex; gap: 14px; align-items: center; font-size: 13px; padding: 4px 0; }
  .net-new { color: #a80000; font-weight: 600; }
  .net-res { color: #107c10; font-weight: 600; }
  .net-net { color: #1f2328; font-weight: 600; }
  .tool-pill { display: inline-block; padding: 2px 8px; border-radius: 10px; font-size: 11px; margin: 2px 4px 2px 0; }
  .tool-ok    { background: #dcfce7; color: #14532d; }
  .tool-skip  { background: #f3f4f6; color: #57606a; }
  .tool-fail  { background: #fee2e2; color: #7f1d1d; }
  .tool-other { background: #fef9c3; color: #854d0e; }
  footer { text-align: center; color: #6b7280; font-size: 11px; padding: 16px; }
</style>
</head>
<body>
<header>
  <h1>azure-analyzer - Executive Dashboard</h1>
  <div class="meta">$date · history: $historyCount run(s)</div>
</header>
<main>
  <div class="grid grid-top">
    <div class="card">
      <h2>Compliance score</h2>
      <div class="score">
        <span class="num">$compliancePct</span>
        <span class="pct">%</span>
        <span>$pctDeltaHtml</span>
      </div>
      <div class="muted" style="margin-top:8px">$compliantCount of $total compliant · $nonCompliant non-compliant</div>
      <div style="margin-top:14px">$netHtml</div>
    </div>
    <div class="card">
      <h2>Severity mix trend</h2>
      <div class="muted card-sub">Non-compliant findings only (risk over time).</div>
      $sparklinesHtml
    </div>
  </div>

  <div class="grid grid-mid" style="margin-top:16px">
    <div class="card">
      <h2>Top-10 risky resources</h2>
      <table>
        <thead><tr><th>Resource</th><th>Findings</th><th>Highest</th><th>Sources</th></tr></thead>
        <tbody>$topResourcesRows</tbody>
      </table>
    </div>
    <div class="card">
      <h2>Subscription heat map</h2>
      <div class="sub-grid">$subTilesHtml</div>
    </div>
  </div>

  <div class="card" style="margin-top:16px">
    <h2>WAF 5-pillar coverage</h2>
    <div class="waf-grid">$wafTilesHtml</div>
  </div>

  <div class="grid grid-bot" style="margin-top:16px">
    <div class="card">
      <h2>MTTR by severity</h2>
      <table>
        <thead><tr><th>Severity</th><th>Resolved</th><th>Median</th><th>Mean</th></tr></thead>
        <tbody>$mttrTableRows</tbody>
      </table>
    </div>
    <div class="card">
      <h2>Framework gap analysis</h2>
      <table>
        <thead><tr><th>Framework</th><th>Controls hit</th><th>%</th></tr></thead>
        <tbody>$frameworkTableRows</tbody>
      </table>
    </div>
    <div class="card">
      <h2>Tool execution</h2>
      <div>$toolStatusHtml</div>
    </div>
  </div>
</main>
<footer>azure-analyzer · executive dashboard v1 · single self-contained file (no external deps)</footer>
</body>
</html>
"@

$html = Remove-Credentials $html
Set-Content -Path $OutputPath -Value $html -Encoding UTF8
Write-Host "Wrote dashboard: $OutputPath" -ForegroundColor Green
