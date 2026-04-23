#Requires -Version 7.4
<#
.SYNOPSIS
    Shared executive-dashboard renderer (issue #210).

.DESCRIPTION
    Extracts the HTML/CSS/data assembly that used to live inline in
    New-ExecDashboard.ps1 so that BOTH the standalone dashboard.html (back-compat)
    and the Summary tab embedded in report.html can render the same content from
    one source of truth (no copy-paste).

    Public surface:
      Get-ExecDashboardModel  - load + compute everything from results.json + history
      Get-ExecDashboardBody   - return HTML body fragment (with or without header/footer)
      Get-ExecDashboardCss    - return CSS, optionally scoped under a CSS prefix for embedding
      Get-ExecDashboardHtml   - full standalone HTML document (used by New-ExecDashboard.ps1)

.NOTES
    The CSS scoping helper (ConvertTo-ScopedCss) is intentionally selector-prefix
    based and only handles the well-formed CSS this module emits. It is NOT a
    general-purpose CSS parser.
#>

Set-StrictMode -Version Latest

# ---------------------------------------------------------------------------
# Dot-source dependencies (best effort - graceful degradation when missing)
# ---------------------------------------------------------------------------
$script:_execDashRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
foreach ($mod in @('Sanitize','FrameworkMapper','ReportDelta','RunHistory')) {
    $p = Join-Path $PSScriptRoot "$mod.ps1"
    if (Test-Path $p) { . $p }
}
if (-not (Get-Command Remove-Credentials -ErrorAction SilentlyContinue)) {
    function Remove-Credentials { param ([string]$Text) return $Text }
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
function _ExecHE([string]$s) {
    if ($null -eq $s) { return '' }
    $s -replace '&','&amp;' -replace '<','&lt;' -replace '>','&gt;' -replace '"','&quot;' -replace "'", '&#39;'
}

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

function Get-FrameworkBadgeClass([string] $Name) {
    if (-not $Name) { return 'fw-default' }
    $n = $Name.ToLowerInvariant()
    switch -Regex ($n) {
        'cis'        { return 'fw-cis' }
        'nist'       { return 'fw-nist' }
        'mitre'      { return 'fw-mitre' }
        'eidsca'     { return 'fw-eidsca' }
        'eidas'      { return 'fw-eidas' }
        'soc'        { return 'fw-soc' }
        'iso'        { return 'fw-iso' }
        'mcsb'       { return 'fw-mcsb' }
        'caf'        { return 'fw-caf' }
        'waf'        { return 'fw-waf' }
        'cisa'       { return 'fw-cisa' }
        'orca'       { return 'fw-orca' }
        default      { return 'fw-default' }
    }
}

# Schema 2.2 (#299) conditional reader. The optional Frameworks field is a
# [hashtable[]] with at least a 'kind' key (e.g. CIS, NIST, MCSB). This helper
# extracts unique kind names across all findings; returns @() if no finding
# carries the field, so legacy results (Schema <= 2.1) render unchanged.
function Get-FrameworkKindsFromFindings([object[]] $Findings) {
    $kinds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($f in $Findings) {
        if (-not $f -or -not $f.PSObject.Properties['Frameworks']) { continue }
        foreach ($fw in @($f.Frameworks)) {
            if (-not $fw) { continue }
            $kind = $null
            if ($fw -is [hashtable] -and $fw.ContainsKey('kind')) { $kind = [string]$fw['kind'] }
            elseif ($fw.PSObject.Properties['kind']) { $kind = [string]$fw.kind }
            elseif ($fw.PSObject.Properties['Kind']) { $kind = [string]$fw.Kind }
            if ($kind) { [void]$kinds.Add($kind.Trim()) }
        }
    }
    return @($kinds | Sort-Object)
}

function Format-SignedDelta([double] $Val, [string] $Suffix = '') {
    if ($Val -gt 0) { return "+{0}{1}" -f $Val, $Suffix }
    if ($Val -lt 0) { return "{0}{1}"  -f $Val, $Suffix }
    return "0$Suffix"
}

# ---------------------------------------------------------------------------
# Get-ExecDashboardModel - data loading + computation
# ---------------------------------------------------------------------------
function Get-ExecDashboardModel {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)] [string] $InputPath,
        [string] $HistoryPath    = '',
        [string] $EntitiesPath   = '',
        [string] $ToolStatusPath = ''
    )

    if (-not (Test-Path $InputPath)) {
        if (Get-Command -Name New-FindingError -ErrorAction SilentlyContinue) {
            throw (Format-FindingErrorMessage (New-FindingError -Source 'shared:ExecDashboardRender' `
                -Category 'NotFound' `
                -Reason "Results file not found: $InputPath" `
                -Remediation 'Run Invoke-AzureAnalyzer.ps1 first to produce results.json, then re-run the dashboard renderer.'))
        }
        throw "Results file not found: $InputPath. Run Invoke-AzureAnalyzer.ps1 first."
    }

    $inputDir = Split-Path $InputPath -Parent
    if (-not $HistoryPath)    { $HistoryPath    = Join-Path $inputDir 'history' }
    if (-not $EntitiesPath)   { $EntitiesPath   = Join-Path $inputDir 'entities.json' }
    if (-not $ToolStatusPath) { $ToolStatusPath = Join-Path $inputDir 'tool-status.json' }

    $findings = @(Get-Content $InputPath -Raw | ConvertFrom-Json -ErrorAction Stop)
    $history  = @()
    if (Get-Command Get-RunHistory -ErrorAction SilentlyContinue) {
        $history = @(Get-RunHistory -OutputPath $inputDir -HistoryPath $HistoryPath)
    }

    $entities = @()
    if (Test-Path $EntitiesPath) {
        try {
            $raw = Get-Content $EntitiesPath -Raw | ConvertFrom-Json -ErrorAction Stop
            if ($raw -is [PSCustomObject] -and $raw.PSObject.Properties['Entities']) {
                $entities = @($raw.Entities)
            } else {
                $entities = @($raw)
            }
        }
        catch { Write-Warning "Could not parse entities.json: $_" }
    }

    $toolStatus = @()
    if (Test-Path $ToolStatusPath) {
        try { $toolStatus = @(Get-Content $ToolStatusPath -Raw | ConvertFrom-Json -ErrorAction Stop) }
        catch { Write-Warning "Could not parse tool-status.json: $_" }
    }

    $total          = @($findings).Count
    $compliantCount = @($findings | Where-Object { $_.PSObject.Properties['Compliant'] -and $_.Compliant }).Count
    $nonCompliant   = $total - $compliantCount
    $compliancePct  = if ($total -gt 0) { [math]::Round(($compliantCount / $total) * 100, 1) } else { 0 }
    $currentSev     = Get-SeverityCounts -Rows $findings -NonCompliantOnly

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
            try {
                $rows = @(Get-Content $h.ResultsPath -Raw | ConvertFrom-Json -ErrorAction Stop)
                $sev = Get-SeverityCounts -Rows $rows -NonCompliantOnly
            } catch { $sev = [ordered]@{ Critical = 0; High = 0; Medium = 0; Low = 0; Info = 0 } }
        }
        $historyPoints.Add([pscustomobject]@{ Stamp = $h.Stamp; Timestamp = $h.Timestamp; Severity = $sev }) | Out-Null
    }
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
    $topResources = @($resourceGroups.Values |
        Sort-Object -Property @{ Expression = 'FindingCount'; Descending = $true }, @{ Expression = 'HighestScore'; Descending = $true } |
        Select-Object -First 10)

    # Subscription heat map
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

    # WAF pillar coverage
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
        $trendGlyph = "$([char]0x2192)"  # ->
        $trendDelta = $null
        if ($prev) {
            $d = [math]::Round($r.CoveragePercent - $prev.CoveragePercent, 1)
            $trendDelta = $d
            if     ($d -gt 0) { $trend = 'up';   $trendGlyph = "$([char]0x2191)" }
            elseif ($d -lt 0) { $trend = 'down'; $trendGlyph = "$([char]0x2193)" }
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

    return [pscustomobject]@{
        Findings        = $findings
        History         = $history
        HistoryPoints   = $historyPoints
        Entities        = $entities
        ToolStatus      = $toolStatus
        Total           = $total
        CompliantCount  = $compliantCount
        NonCompliant    = $nonCompliant
        CompliancePct   = $compliancePct
        CurrentSev      = $currentSev
        PrevRun         = $prevRun
        Delta           = $delta
        PrevPct         = $prevPct
        PctDelta        = $pctDelta
        TopResources    = $topResources
        SubRows         = $subRows
        WafRows         = $wafRows
        FrameworkRows   = $frameworkRows
        MttrRows        = $mttrRows
    }
}

# ---------------------------------------------------------------------------
# Get-ExecDashboardBody - HTML body fragment
# ---------------------------------------------------------------------------
function Get-ExecDashboardBody {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)] [object] $Model,
        [switch] $Embedded
    )

    $sevColor = @{
        Critical = '#a80000'
        High     = '#d83b01'
        Medium   = '#ca5010'
        Low      = '#107c10'
        Info     = '#5c5c5c'
    }
    $severitiesForTrend = @('Critical','High','Medium','Low','Info')

    $sparklinesHtml = ($severitiesForTrend | ForEach-Object {
        $sev = $_
        $vals = @($Model.HistoryPoints | ForEach-Object { [int]$_.Severity[$sev] })
        $latest = if ($vals.Count -gt 0) { $vals[-1] } else { 0 }
        @"
  <div class="spark-row">
    <span class="spark-label" style="color:$($sevColor[$sev])">$sev</span>
    <span class="spark-svg">$(New-Sparkline -Values $vals -Color $sevColor[$sev])</span>
    <span class="spark-val">$latest</span>
  </div>
"@
    }) -join ''

    $topResourcesRows = ($Model.TopResources | ForEach-Object {
        $sevBadge = if ($_.HighestSev) { $_.HighestSev } else { '-' }
        $sevClass = Get-SafeSeverityClass $_.HighestSev
        $srcs = ($_.Sources | Sort-Object) -join ', '
        @"
    <tr>
      <td class="ridcol" title="$(_ExecHE $_.ResourceId)">$(_ExecHE $_.ResourceId)</td>
      <td>$([int]$_.FindingCount)</td>
      <td><span class="sev sev-$sevClass">$(_ExecHE $sevBadge)</span></td>
      <td class="src">$(_ExecHE $srcs)</td>
    </tr>
"@
    }) -join ''
    if (-not $topResourcesRows) { $topResourcesRows = "<tr><td colspan='4' class='empty'>No non-compliant resources in current run.</td></tr>" }

    $subTilesHtml = ($Model.SubRows | ForEach-Object {
        $status = if     ($_.Critical -gt 0)     { 'red' }
                  elseif ($_.High -gt 0)         { 'amber' }
                  elseif ($_.NonCompliant -gt 0) { 'amber' }
                  else                           { 'green' }
        $shortId = if ($_.SubscriptionId.Length -ge 8) { $_.SubscriptionId.Substring(0, 8) } else { $_.SubscriptionId }
        @"
    <div class="sub-tile sub-$status">
      <div class="sub-id" title="$(_ExecHE $_.SubscriptionId)">$(_ExecHE $shortId)$([char]0x2026)</div>
      <div class="sub-counts">
        <span class="cnt-c">C: $($_.Critical)</span>
        <span class="cnt-h">H: $($_.High)</span>
        <span class="cnt-n">N/C: $($_.NonCompliant)</span>
      </div>
    </div>
"@
    }) -join ''
    if (-not $subTilesHtml) { $subTilesHtml = "<div class='empty'>No subscription-scoped findings in current run.</div>" }

    $wafTilesHtml = ($Model.WafRows | ForEach-Object {
        $statusClass = "waf-$($_.Status)"
        $trendClass  = "trend-$($_.Trend)"
        $trendTitle  = if ($null -eq $_.TrendDelta) { 'no prior run' } else {
            $sign = if ($_.TrendDelta -ge 0) { '+' } else { '' }
            "$sign$($_.TrendDelta)% vs previous run"
        }
        @"
    <div class="waf-tile $statusClass" style="border-top-color:$($_.Color)">
      <div class="waf-name">$(_ExecHE $_.DisplayName)</div>
      <div class="waf-num">$($_.CoveragePercent)% <span class="waf-trend $trendClass" title="$(_ExecHE $trendTitle)">$($_.TrendGlyph)</span></div>
      <div class="waf-sub">$($_.NonCompliant) non-compliant of $($_.Total) $([char]0x2022) $($_.CriticalHigh) C/H</div>
    </div>
"@
    }) -join ''
    if (-not $wafTilesHtml) { $wafTilesHtml = "<div class='empty'>WAF mappings not loaded.</div>" }

    $frameworkTableRows = ($Model.FrameworkRows | ForEach-Object {
        $fwClass = Get-FrameworkBadgeClass $_.DisplayName
        @"
    <tr>
      <td><span class="fw-chip $fwClass">$(_ExecHE $_.DisplayName)</span> <span class="muted">v$(_ExecHE $_.Version)</span></td>
      <td>$($_.ControlsHit) / $($_.ControlsTotal)</td>
      <td><span class="cov cov-$($_.Status)">$($_.PercentCovered)%</span></td>
    </tr>
"@
    }) -join ''
    if (-not $frameworkTableRows) { $frameworkTableRows = "<tr><td colspan='3' class='empty'>No framework mappings loaded.</td></tr>" }

    $mttrTableRows = ($Model.MttrRows | ForEach-Object {
        $median = if ($null -eq $_.MedianDays) { 'N/A' } else { "$($_.MedianDays) d" }
        $mean   = if ($null -eq $_.MeanDays)   { 'N/A' } else { "$($_.MeanDays) d" }
        $sevClass = Get-SafeSeverityClass $_.Severity
        @"
    <tr>
      <td><span class="sev sev-$sevClass">$(_ExecHE $_.Severity)</span></td>
      <td>$($_.ResolvedCount)</td>
      <td>$median</td>
      <td>$mean</td>
    </tr>
"@
    }) -join ''
    if (-not $mttrTableRows) { $mttrTableRows = "<tr><td colspan='4' class='empty'>Run history insufficient - MTTR available after 2+ runs with resolved findings.</td></tr>" }

    $toolStatusHtml = ''
    if ($Model.ToolStatus -and @($Model.ToolStatus).Count -gt 0) {
        $toolStatusHtml = ($Model.ToolStatus | ForEach-Object {
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
            "<span class='tool-pill $cls'>$(_ExecHE $name): $(_ExecHE $status)</span>"
        }) -join ''
    }
    if (-not $toolStatusHtml) { $toolStatusHtml = "<span class='muted'>tool-status.json not available.</span>" }

    $netNew = if ($Model.Delta) { [int]$Model.Delta.Summary.New } else { 0 }
    $netRes = if ($Model.Delta) { [int]$Model.Delta.Summary.Resolved } else { 0 }
    $netNet = if ($Model.Delta) { [int]$Model.Delta.Summary.NetNonCompliantDelta } else { 0 }
    $netHtml = if ($Model.Delta) {
        @"
    <div class="net-row">
      <span class="net-new">+$netNew new</span>
      <span class="net-res">-$netRes resolved</span>
      <span class="net-net">net $(Format-SignedDelta $netNet)</span>
      <span class="muted">vs $(_ExecHE $Model.PrevRun.Stamp)</span>
    </div>
"@
    } else {
        "<div class='net-row muted'>No prior run available - first snapshot.</div>"
    }

    $pctDeltaHtml = if ($null -ne $Model.PctDelta) {
        $cls = if ($Model.PctDelta -ge 0) { 'delta-up' } else { 'delta-down' }
        "<span class='pct-delta $cls'>$(Format-SignedDelta $Model.PctDelta '%') vs prev</span>"
    } else {
        "<span class='muted'>first run</span>"
    }

    # Body fragment - the contents of <main> from the standalone dashboard.
    # When -Embedded, the caller wraps this in its own panel; when standalone,
    # New-ExecDashboard.ps1 wraps with <header>/<main>/<footer>.
    # Top severity-count KPI tiles - same primitive as main report's .sev-strip.
    $sevTilesHtml = ($severitiesForTrend | ForEach-Object {
        $cls = switch ($_) {
            'Critical' { 'kpi-crit' }
            'High'     { 'kpi-high' }
            'Medium'   { 'kpi-med' }
            'Low'      { 'kpi-low' }
            default    { 'kpi-info' }
        }
        $n = if ($Model.CurrentSev[$_]) { [int]$Model.CurrentSev[$_] } else { 0 }
        @"
    <div class="kpi-tile $cls" title="$_ non-compliant findings">
      <span class="n">$n</span>
      <span class="l">$_</span>
    </div>
"@
    }) -join ''

    # Schema 2.2 (#299) conditional: if any finding carries Frameworks[],
    # render a framework chip strip. Absent => omitted entirely (graceful
    # degradation; never fabricate).
    $frameworkKinds = @(Get-FrameworkKindsFromFindings $Model.Findings)
    $fwStripHtml = ''
    if (@($frameworkKinds).Count -gt 0) {
        $chips = ($frameworkKinds | ForEach-Object {
            $cls = Get-FrameworkBadgeClass $_
            "<span class='fw-chip $cls'>$(_ExecHE $_)</span>"
        }) -join ''
        $fwStripHtml = "<div class='fw-strip'><span class='muted'>Frameworks evaluated:</span>$chips</div>"
    }

    $body = @"
  <div class="kpi-strip">$sevTilesHtml</div>
  $fwStripHtml
  <div class="grid grid-top">
    <div class="card">
      <h2>Compliance score</h2>
      <div class="score">
        <span class="num">$($Model.CompliancePct)</span>
        <span class="pct">%</span>
        <span>$pctDeltaHtml</span>
      </div>
      <div class="muted" style="margin-top:8px">$($Model.CompliantCount) of $($Model.Total) compliant $([char]0x00b7) $($Model.NonCompliant) non-compliant</div>
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
"@

    return $body
}

# ---------------------------------------------------------------------------
# Get-ExecDashboardCss - CSS, optionally scoped under a wrapper class for embedding
# ---------------------------------------------------------------------------
# The CSS below is the SAME selectors that used to be inline in
# New-ExecDashboard.ps1. ConvertTo-ScopedCss prefixes every selector with $Scope
# so that when the body fragment is wrapped in <div class="exec-dash">...</div>
# inside report.html, none of these rules collide with report.html's own
# .card / .muted / .empty rules.
function Get-ExecDashboardCss {
    [CmdletBinding()]
    param ([string] $Scope = '')

    # Design tokens harmonized with samples/sample-report.html (issue #297).
    # Same severity palette (--crit/--high/--med/--low/--info/--pass), framework
    # badge palette (.fw-*), surface/border/text tokens, radii, shadows, fonts,
    # and dark-mode variant. Class names match the legacy ExecDashboard surface
    # so existing tests/selectors keep working; only the underlying tokens move.
    $css = @'
:root{
  --bg:#f7f8fa;--surface:#ffffff;--surface-2:#f1f3f6;--border:#e3e6eb;--border-strong:#cdd2da;
  --text:#0f172a;--text-muted:#475569;--text-faint:#64748b;
  --brand:#0b5fff;--brand-ink:#003fb3;--accent:#0ea5e9;
  --crit:#7f1d1d;--high:#b91c1c;--med:#b45309;--low:#a16207;--info:#475569;
  --crit-bg:#fef2f2;--high-bg:#fee2e2;--med-bg:#fef3c7;--low-bg:#fefce8;--info-bg:#f1f5f9;
  --pass:#15803d;--pass-bg:#dcfce7;
  --shadow-sm:0 1px 2px rgba(15,23,42,.06),0 1px 1px rgba(15,23,42,.04);
  --shadow:0 4px 12px rgba(15,23,42,.08),0 2px 4px rgba(15,23,42,.04);
  --radius:10px;--radius-sm:6px;--radius-lg:14px;
  --font:-apple-system,BlinkMacSystemFont,"Segoe UI Variable","Segoe UI",Inter,system-ui,sans-serif;
  --mono:ui-monospace,"Cascadia Code","JetBrains Mono",Consolas,monospace;
}
[data-theme="dark"]{
  --bg:#0b1220;--surface:#111a2e;--surface-2:#172238;--border:#243049;--border-strong:#324264;
  --text:#e8edf6;--text-muted:#9aa7bf;--text-faint:#7a8aa6;
  --brand:#3b82f6;--brand-ink:#60a5fa;--accent:#22d3ee;
  --crit:#f87171;--high:#fb923c;--med:#fbbf24;--low:#facc15;--info:#94a3b8;
  --crit-bg:#3a1212;--high-bg:#3a1f10;--med-bg:#3a2a0a;--low-bg:#332a0a;--info-bg:#1e293b;
  --pass:#4ade80;--pass-bg:#0f2a1a;
}
*,*::before,*::after{box-sizing:border-box}
body{font-family:var(--font);font-size:14px;line-height:1.5;margin:0;background:var(--bg);color:var(--text);-webkit-font-smoothing:antialiased;text-rendering:optimizeLegibility}
header{position:sticky;top:0;z-index:50;background:var(--surface);color:var(--text);border-bottom:1px solid var(--border);box-shadow:var(--shadow-sm);padding:14px 28px;display:flex;justify-content:space-between;align-items:center;gap:12px;flex-wrap:wrap}
header h1{margin:0;font-size:18px;font-weight:700;letter-spacing:-.01em}
header .meta{font-size:12px;color:var(--text-faint)}
.theme-btn{display:inline-flex;align-items:center;justify-content:center;width:34px;height:34px;border:1px solid var(--border);border-radius:8px;background:var(--surface-2);color:var(--text-muted);cursor:pointer;font:inherit}
.theme-btn:hover{color:var(--text);border-color:var(--border-strong)}
main{padding:20px 28px;max-width:1440px;margin:0 auto}
.grid{display:grid;gap:16px}
.grid-top{grid-template-columns:minmax(280px,1fr) 2fr}
.grid-mid{grid-template-columns:1fr 1fr}
.grid-bot{grid-template-columns:1.2fr 1fr 1fr}
@media(max-width:980px){.grid-top,.grid-mid,.grid-bot{grid-template-columns:1fr}}
.card{background:var(--surface);border:1px solid var(--border);border-radius:var(--radius);padding:16px 18px;box-shadow:var(--shadow-sm)}
.card h2{margin:0 0 10px;font-size:13px;text-transform:uppercase;letter-spacing:.05em;color:var(--text-faint);font-weight:600}
.score{display:flex;align-items:baseline;gap:12px}
.score .num{font-size:56px;font-weight:700;color:var(--text);line-height:1;letter-spacing:-.02em}
.score .pct{font-size:24px;color:var(--text-muted)}
.pct-delta{font-size:13px;padding:2px 8px;border-radius:12px;font-weight:600}
.delta-up{background:var(--pass-bg);color:var(--pass)}
.delta-down{background:var(--high-bg);color:var(--high)}
.muted{color:var(--text-muted);font-size:12px}
.kpi-strip{display:flex;gap:8px;flex-wrap:wrap;margin:0 0 16px}
.kpi-tile{display:flex;flex-direction:column;align-items:center;justify-content:center;min-width:64px;padding:8px 12px;border-radius:8px;color:#fff;font-weight:600;box-shadow:var(--shadow-sm)}
.kpi-tile .n{font-size:18px;line-height:1}
.kpi-tile .l{font-size:10px;text-transform:uppercase;letter-spacing:.06em;margin-top:3px;opacity:.95}
.kpi-tile.kpi-crit{background:var(--crit)}
.kpi-tile.kpi-high{background:var(--high)}
.kpi-tile.kpi-med{background:var(--med)}
.kpi-tile.kpi-low{background:var(--low)}
.kpi-tile.kpi-info{background:var(--info)}
.fw-strip{display:flex;flex-wrap:wrap;gap:6px;margin:8px 0 16px}
.fw-strip .muted{align-self:center;margin-right:4px}
.spark-row{display:grid;grid-template-columns:70px 130px 50px;align-items:center;padding:4px 0;font-size:13px}
.spark-label{font-weight:600}
.spark-val{text-align:right;color:var(--text);font-variant-numeric:tabular-nums}
.spark-na{color:var(--text-faint);font-size:11px}
table{width:100%;border-collapse:collapse;font-size:12px}
th{text-align:left;padding:6px 8px;border-bottom:1px solid var(--border);color:var(--text-faint);font-weight:600;text-transform:uppercase;letter-spacing:.04em;font-size:11px}
td{padding:6px 8px;border-bottom:1px solid var(--border);vertical-align:top;color:var(--text)}
td.ridcol{font-family:var(--mono);max-width:380px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
td.src{color:var(--text-faint);font-size:11px}
td.empty,.empty{color:var(--text-faint);font-style:italic;padding:12px}
.sev{padding:1px 8px;border-radius:999px;font-size:11px;font-weight:600;color:#fff;display:inline-block;line-height:1.5}
.sev-critical{background:var(--crit)}
.sev-high{background:var(--high)}
.sev-medium{background:var(--med)}
.sev-low{background:var(--low)}
.sev-info{background:var(--info)}
.cov{padding:1px 8px;border-radius:999px;font-size:11px;font-weight:600;color:#fff}
.cov-green{background:var(--pass)}
.cov-yellow{background:var(--med)}
.cov-red{background:var(--crit)}
.sub-grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(170px,1fr));gap:10px}
.sub-tile{padding:10px 12px;border-radius:var(--radius-sm);border:1px solid var(--border);border-left:4px solid var(--border-strong);background:var(--surface)}
.sub-tile.sub-red{border-left-color:var(--crit);background:var(--crit-bg)}
.sub-tile.sub-amber{border-left-color:var(--med);background:var(--med-bg)}
.sub-tile.sub-green{border-left-color:var(--pass);background:var(--pass-bg)}
.sub-id{font-family:var(--mono);font-size:11px;color:var(--text)}
.sub-counts{font-size:11px;margin-top:4px;display:flex;gap:8px}
.sub-counts .cnt-c{color:var(--crit);font-weight:600}
.sub-counts .cnt-h{color:var(--high);font-weight:600}
.sub-counts .cnt-n{color:var(--text-muted)}
.waf-grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(170px,1fr));gap:10px}
.waf-tile{padding:12px;border-radius:var(--radius-sm);background:var(--surface);border:1px solid var(--border);border-top:4px solid var(--border-strong);text-align:center}
.waf-tile.waf-red{background:var(--crit-bg)}
.waf-tile.waf-amber{background:var(--med-bg)}
.waf-tile.waf-green{background:var(--pass-bg)}
.waf-name{font-size:11px;font-weight:600;color:var(--text-faint);text-transform:uppercase;letter-spacing:.05em}
.waf-num{font-size:28px;font-weight:700;color:var(--text);margin:4px 0;letter-spacing:-.02em}
.waf-sub{font-size:10px;color:var(--text-muted)}
.waf-trend{font-size:16px;vertical-align:middle;margin-left:4px}
.trend-up{color:var(--pass)}
.trend-down{color:var(--crit)}
.trend-flat{color:var(--text-muted)}
.card-sub{margin:-4px 0 8px}
.net-row{display:flex;gap:14px;align-items:center;font-size:13px;padding:4px 0;flex-wrap:wrap}
.net-new{color:var(--crit);font-weight:600}
.net-res{color:var(--pass);font-weight:600}
.net-net{color:var(--text);font-weight:600}
.tool-pill{display:inline-block;padding:2px 8px;border-radius:999px;font-size:11px;margin:2px 4px 2px 0;border:1px solid transparent}
.tool-ok{background:var(--pass-bg);color:var(--pass);border-color:var(--pass)}
.tool-skip{background:var(--surface-2);color:var(--text-muted);border-color:var(--border)}
.tool-fail{background:var(--high-bg);color:var(--high);border-color:var(--high)}
.tool-other{background:var(--low-bg);color:var(--low);border-color:var(--low)}
.fw-chip{display:inline-flex;align-items:center;padding:2px 8px;border-radius:999px;font-size:11px;font-weight:600;color:#fff;line-height:1.5;margin:1px 2px}
.fw-cis{background:#d97706}.fw-nist{background:#374151}.fw-mitre{background:#b91c1c}
.fw-eidsca{background:#1f6feb}.fw-eidas{background:#7c3aed}.fw-soc{background:#0e7490}
.fw-iso{background:#0f766e}.fw-mcsb{background:#005a9e}.fw-caf{background:#1e3a8a}
.fw-waf{background:#3a7d0a}.fw-cisa{background:#0f766e}.fw-orca{background:#0891b2}
.fw-default{background:#475569}
.mitre-chip{display:inline-flex;align-items:center;padding:1px 6px;border-radius:4px;font-size:10.5px;font-family:var(--mono);background:var(--high-bg);color:var(--high);border:1px solid var(--high);margin:1px 2px}
footer{text-align:center;color:var(--text-faint);font-size:11px;padding:16px}
'@

    if (-not $Scope) { return $css }
    return (ConvertTo-ScopedCss -Css $css -Scope $Scope)
}

function ConvertTo-ScopedCss {
    [CmdletBinding()]
    param ([string]$Css, [Parameter(Mandatory)][string]$Scope)

    # Naive selector-prefix scoper. Assumes input is the well-formed CSS this
    # module emits (no nested @media, no @keyframes, no @supports, no comments
    # containing braces). For our embed use-case that is sufficient.
    $sb = [System.Text.StringBuilder]::new()
    $i  = 0
    $n  = $Css.Length
    while ($i -lt $n) {
        $brace = $Css.IndexOf('{', $i)
        if ($brace -lt 0) { [void]$sb.Append($Css.Substring($i)); break }
        $rawSelectors = $Css.Substring($i, $brace - $i)
        $leadingWs = ''
        $sels = $rawSelectors.TrimStart()
        if ($sels.Length -lt $rawSelectors.Length) {
            $leadingWs = $rawSelectors.Substring(0, $rawSelectors.Length - $sels.Length)
        }
        # Find matching close brace (no nesting expected).
        $close = $Css.IndexOf('}', $brace + 1)
        if ($close -lt 0) { [void]$sb.Append($Css.Substring($i)); break }
        $declBlock = $Css.Substring($brace, $close - $brace + 1)

        if ($sels.StartsWith('@')) {
            # Pass-through (we don't emit at-rules, but be safe).
            [void]$sb.Append($leadingWs)
            [void]$sb.Append($sels)
            [void]$sb.Append($declBlock)
        } else {
            $parts = $sels -split ','
            $scoped = foreach ($p in $parts) {
                $t = $p.Trim()
                if (-not $t) { continue }
                "$Scope $t"
            }
            [void]$sb.Append($leadingWs)
            [void]$sb.Append(($scoped -join ', '))
            [void]$sb.Append($declBlock)
        }
        $i = $close + 1
    }
    return $sb.ToString()
}

# ---------------------------------------------------------------------------
# Get-ExecDashboardHtml - full standalone HTML doc (used by New-ExecDashboard.ps1)
# ---------------------------------------------------------------------------
function Get-ExecDashboardHtml {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)] [string] $InputPath,
        [string] $HistoryPath    = '',
        [string] $EntitiesPath   = '',
        [string] $ToolStatusPath = ''
    )

    $model = Get-ExecDashboardModel -InputPath $InputPath -HistoryPath $HistoryPath -EntitiesPath $EntitiesPath -ToolStatusPath $ToolStatusPath
    $body  = Get-ExecDashboardBody  -Model $model
    $css   = Get-ExecDashboardCss

    $date = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd HH:mm 'UTC'")
    $historyCount = $model.HistoryPoints.Count

    $html = @"
<!DOCTYPE html>
<html lang="en" data-theme="light">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>azure-analyzer - Executive Dashboard</title>
<style>
$css
</style>
</head>
<body>
<header>
  <h1>azure-analyzer - Executive Dashboard</h1>
  <div style="display:flex;align-items:center;gap:14px">
    <div class="meta">$date $([char]0x00b7) history: $historyCount run(s)</div>
    <button class="theme-btn" id="themeToggle" type="button" title="Toggle light/dark theme" aria-label="Toggle theme">$([char]0x263D)</button>
  </div>
</header>
<main>
$body
</main>
<footer>azure-analyzer $([char]0x00b7) executive dashboard v2 $([char]0x00b7) single self-contained file (no external deps) $([char]0x00b7) design tokens harmonized with main report (#297)</footer>
<script>
(function(){
  var KEY='aa-theme';
  var html=document.documentElement;
  var stored=null;
  try{stored=localStorage.getItem(KEY);}catch(e){}
  if(stored==='dark'||stored==='light'){html.setAttribute('data-theme',stored);}
  var btn=document.getElementById('themeToggle');
  if(btn){
    btn.addEventListener('click',function(){
      var cur=html.getAttribute('data-theme')==='dark'?'light':'dark';
      html.setAttribute('data-theme',cur);
      try{localStorage.setItem(KEY,cur);}catch(e){}
    });
  }
})();
</script>
</body>
</html>
"@

    return (Remove-Credentials $html)
}
