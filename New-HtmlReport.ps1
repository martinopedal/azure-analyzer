#Requires -Version 7.0
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
#>
[CmdletBinding()]
param (
    [string] $InputPath = (Join-Path $PSScriptRoot 'output' 'results.json'),
    [string] $OutputPath = (Join-Path $PSScriptRoot 'output' 'report.html')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not (Test-Path $InputPath)) {
    throw "Results file not found: $InputPath. Run Invoke-AzureAnalyzer.ps1 first."
}

$findings = @(Get-Content $InputPath -Raw | ConvertFrom-Json -ErrorAction Stop)

$date = Get-Date -Format 'yyyy-MM-dd HH:mm UTC'
$total = $findings.Count
$high = ($findings | Where-Object { $_.Severity -eq 'High' -and -not $_.Compliant }).Count
$medium = ($findings | Where-Object { $_.Severity -eq 'Medium' -and -not $_.Compliant }).Count
$low = ($findings | Where-Object { $_.Severity -eq 'Low' -and -not $_.Compliant }).Count
$compliantCount = ($findings | Where-Object { $_.Compliant -eq $true }).Count
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

$rowsJson = $findings | ForEach-Object {
    @"
{
  id: `"$(HE $_.Id)`",
  source: `"$(HE $_.Source)`",
  category: `"$(HE $_.Category)`",
  title: `"$(HE $_.Title)`",
  severity: `"$(HE $_.Severity)`",
  compliant: $($_.Compliant.ToString().ToLower()),
  detail: `"$(HE $_.Detail)`",
  remediation: `"$(HE $_.Remediation)`"
}
"@
} -join ','

$byCategory = $findings | Group-Object -Property Category | Sort-Object Name

$categoryHtml = foreach ($cat in $byCategory) {
    $catId = ($cat.Name -replace '[^a-zA-Z0-9]', '-').ToLower()
    $catRows = foreach ($f in ($cat.Group | Sort-Object Severity, Title)) {
        $sevClass = SeverityClass $f.Severity
        $compliantStr = if ($f.Compliant) { '<span class="badge badge-ok">Yes</span>' } else { '<span class="badge badge-fail">No</span>' }
        "<tr><td>$(HE $f.Title)</td><td><span class='badge $sevClass'>$(HE $f.Severity)</span></td><td>$(HE $f.Source)</td><td>$compliantStr</td><td>$(HE $f.Detail)</td></tr>"
    }
    @"
<details id="cat-$catId">
  <summary><strong>$(HE $cat.Name)</strong> <span class="cat-count">($($cat.Count))</span></summary>
  <table class="findings-table sortable">
    <thead>
      <tr>
        <th onclick="sortTable(this)">Title</th>
        <th onclick="sortTable(this)">Severity</th>
        <th onclick="sortTable(this)">Source</th>
        <th onclick="sortTable(this)">Compliant</th>
        <th>Detail</th>
      </tr>
    </thead>
    <tbody>
      $($catRows -join "`n      ")
    </tbody>
  </table>
</details>
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
  .cards { display: flex; gap: 12px; flex-wrap: wrap; margin-bottom: 24px; }
  .card { background: #fff; border-radius: 6px; padding: 16px 20px; min-width: 120px; box-shadow: 0 1px 3px rgba(0,0,0,0.08); }
  .card-label { font-size: 11px; color: #666; text-transform: uppercase; letter-spacing: 0.5px; }
  .card-value { font-size: 28px; font-weight: 700; margin-top: 2px; }
  .card-total .card-value { color: #1a1a1a; }
  .card-high .card-value { color: #d32f2f; }
  .card-medium .card-value { color: #e65100; }
  .card-low .card-value { color: #f9a825; }
  .card-ok .card-value { color: #2e7d32; }
  details { background: #fff; border-radius: 6px; margin-bottom: 8px; box-shadow: 0 1px 3px rgba(0,0,0,0.06); }
  summary { padding: 12px 16px; cursor: pointer; user-select: none; font-size: 14px; }
  summary:hover { background: #f9f9f9; }
  .cat-count { font-size: 12px; color: #888; font-weight: 400; }
  .findings-table { width: 100%; border-collapse: collapse; margin: 0 0 12px; font-size: 13px; }
  .findings-table th { background: #f0f0f0; padding: 8px 10px; text-align: left; font-weight: 600; cursor: pointer; white-space: nowrap; }
  .findings-table th:hover { background: #e0e0e0; }
  .findings-table td { padding: 7px 10px; border-top: 1px solid #f0f0f0; vertical-align: top; }
  .findings-table tr:hover td { background: #fafafa; }
  .badge { display: inline-block; padding: 2px 7px; border-radius: 3px; font-size: 11px; font-weight: 600; }
  .sev-high { background: #fde8e8; color: #c62828; }
  .sev-medium { background: #fff3e0; color: #bf360c; }
  .sev-low { background: #fff9c4; color: #827717; }
  .sev-info { background: #eeeeee; color: #555; }
  .badge-ok { background: #e8f5e9; color: #1b5e20; }
  .badge-fail { background: #fce4ec; color: #880e4f; }
</style>
</head>
<body>
<h1>Azure Analyzer Report</h1>
<p class="subtitle">Generated: $date</p>

<div class="cards">
  <div class="card card-total"><div class="card-label">Total findings</div><div class="card-value">$total</div></div>
  <div class="card card-high"><div class="card-label">High (non-compliant)</div><div class="card-value">$high</div></div>
  <div class="card card-medium"><div class="card-label">Medium (non-compliant)</div><div class="card-value">$medium</div></div>
  <div class="card card-low"><div class="card-label">Low (non-compliant)</div><div class="card-value">$low</div></div>
  <div class="card card-ok"><div class="card-label">Compliant %</div><div class="card-value">$compliantPct%</div></div>
</div>

<h2>Findings by category</h2>
$($categoryHtml -join "`n")

<script>
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
</script>
</body>
</html>
"@

try {
    $outputDir = Split-Path $OutputPath -Parent
    if (-not (Test-Path $outputDir)) {
        $null = New-Item -ItemType Directory -Path $outputDir -Force
    }
    $html | Set-Content -Path $OutputPath -Encoding UTF8
} catch {
    Write-Error "Failed to write HTML report to ${OutputPath}: $_"
    return
}
Write-Host "HTML report written to: $OutputPath" -ForegroundColor Green
