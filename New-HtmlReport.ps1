#Requires -Version 7.4
<#
.SYNOPSIS
    Generate an offline HTML report from azure-analyzer results.
.DESCRIPTION
    Reads results.json and writes a single self-contained HTML dashboard
    (report v2) with embedded JSON payload, client-side filtering, and
    optional delta comparison against a previous run.
#>
[CmdletBinding()]
param (
    [string] $InputPath = (Join-Path $PSScriptRoot 'output' 'results.json'),
    [string] $OutputPath = (Join-Path $PSScriptRoot 'output' 'report.html'),
    [string] $TriagePath = '',
    [string] $PreviousRunPath = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$sanitizePath = Join-Path $PSScriptRoot 'modules' 'shared' 'Sanitize.ps1'
if (Test-Path $sanitizePath) { . $sanitizePath }
if (-not (Get-Command Remove-Credentials -ErrorAction SilentlyContinue)) {
    function Remove-Credentials { param ([string]$Text) return $Text }
}

$deltaPath = Join-Path $PSScriptRoot 'modules' 'shared' 'ReportDelta.ps1'
if (-not (Test-Path $deltaPath)) {
    throw "Required module not found: $deltaPath"
}
. $deltaPath

if (-not (Test-Path $InputPath)) {
    throw "Results file not found: $InputPath. Run Invoke-AzureAnalyzer.ps1 first."
}

$findings = @(Get-Content $InputPath -Raw | ConvertFrom-Json -ErrorAction Stop)
$previousFindings = @()
$resolvedPreviousPath = ''
if ($PreviousRunPath -and (Test-Path $PreviousRunPath)) {
    try {
        $previousFindings = @(Get-Content $PreviousRunPath -Raw | ConvertFrom-Json -ErrorAction Stop)
        $resolvedPreviousPath = (Resolve-Path $PreviousRunPath).Path
    } catch {
        Write-Warning (Remove-Credentials "Could not parse previous run file '${PreviousRunPath}': $_")
        $previousFindings = @()
        $resolvedPreviousPath = ''
    }
}

$delta = Get-FindingDelta -CurrentFindings $findings -PreviousFindings $previousFindings
$annotatedFindings = @($delta.CurrentFindings)
$resolvedFindings = @($delta.ResolvedFindings)
$dashboardFindings = @($annotatedFindings + $resolvedFindings)

$triageFindings = @()
if ($TriagePath -and (Test-Path $TriagePath)) {
    try {
        $triageFindings = @(Get-Content $TriagePath -Raw | ConvertFrom-Json -ErrorAction Stop)
    } catch {
        Write-Warning (Remove-Credentials "Could not load triage data from ${TriagePath}: $_")
    }
}

function HE([string]$s) {
    if ($null -eq $s) { return '' }
    $s -replace '&', '&amp;' -replace '<', '&lt;' -replace '>', '&gt;' -replace '"', '&quot;'
}

function Linkify([string]$text) {
    if ([string]::IsNullOrWhiteSpace($text)) { return '' }
    $escaped = HE $text
    $escaped -replace '(https?://[^\s&lt;&quot;]+)', '<a href="$1" target="_blank" rel="noopener noreferrer">$1</a>'
}

function Get-FrameworkNames {
    param ([pscustomobject]$Finding)

    $out = [System.Collections.Generic.List[string]]::new()

    if ($Finding.PSObject.Properties['Frameworks'] -and $Finding.Frameworks) {
        foreach ($framework in @($Finding.Frameworks)) {
            if ($framework -is [string] -and -not [string]::IsNullOrWhiteSpace($framework)) {
                $out.Add($framework)
                continue
            }
            if ($framework -and $framework.PSObject.Properties['Name'] -and -not [string]::IsNullOrWhiteSpace([string]$framework.Name)) {
                $out.Add([string]$framework.Name)
            }
        }
    }

    return @($out | Sort-Object -Unique)
}

$date = Get-Date -Format 'yyyy-MM-dd HH:mm UTC'
$total = $annotatedFindings.Count
$nonCompliant = @($annotatedFindings | Where-Object { -not $_.Compliant }).Count
$compliantCount = @($annotatedFindings | Where-Object { $_.Compliant }).Count
$high = @($annotatedFindings | Where-Object { $_.Severity -eq 'High' -and -not $_.Compliant }).Count
$medium = @($annotatedFindings | Where-Object { $_.Severity -eq 'Medium' -and -not $_.Compliant }).Count
$low = @($annotatedFindings | Where-Object { $_.Severity -eq 'Low' -and -not $_.Compliant }).Count
$critical = @($annotatedFindings | Where-Object { $_.Severity -eq 'Critical' -and -not $_.Compliant }).Count
$compliantPct = if ($total -gt 0) { [math]::Round(($compliantCount / $total) * 100) } else { 0 }

$sourceGroups = @($annotatedFindings | Group-Object -Property Source | Sort-Object Name)
$maxSourceCount = if ($sourceGroups.Count -gt 0) { ($sourceGroups | Measure-Object -Property Count -Maximum).Maximum } else { 1 }
if ($maxSourceCount -eq 0) { $maxSourceCount = 1 }

$sourceBreakdown = @($sourceGroups | ForEach-Object {
    [PSCustomObject]@{
        Name  = $_.Name
        Count = $_.Count
        Width = [math]::Round(($_.Count / $maxSourceCount) * 100)
    }
})

$toolStatus = @()
$statusJsonPath = Join-Path (Split-Path $InputPath -Parent) 'tool-status.json'
if (Test-Path $statusJsonPath) {
    try {
        $toolStatus = @(Get-Content $statusJsonPath -Raw | ConvertFrom-Json -ErrorAction Stop)
    } catch {
        Write-Warning "Could not load tool status: $_"
    }
}

$modelFindings = @($dashboardFindings | ForEach-Object {
    [PSCustomObject]@{
        id           = [string]$_.Id
        source       = [string]$_.Source
        category     = [string]$_.Category
        title        = [string]$_.Title
        severity     = [string]$_.Severity
        compliant    = [bool]$_.Compliant
        detail       = [string]$_.Detail
        remediation  = [string]$_.Remediation
        resourceId   = [string]$_.ResourceId
        learnMoreUrl = [string]$_.LearnMoreUrl
        frameworks   = @(Get-FrameworkNames -Finding $_)
        deltaStatus  = [string]$_.DeltaStatus
    }
})

$frameworkOptions = @($modelFindings | ForEach-Object { @($_.frameworks) } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)

$model = [PSCustomObject]@{
    generatedAt = $date
    summary = [PSCustomObject]@{
        totalFindings = $total
        nonCompliant  = $nonCompliant
        compliant     = $compliantCount
        compliancePct = $compliantPct
        highSeverity  = ($high + $critical)
        mediumSeverity = $medium
        lowSeverity   = $low
        criticalSeverity = $critical
    }
    delta = [PSCustomObject]@{
        enabled = [bool]($resolvedPreviousPath)
        previousRunPath = $resolvedPreviousPath
        newCount = $delta.NewCount
        resolvedCount = $delta.ResolvedCount
        unchangedCount = $delta.UnchangedCount
        previousNonCompliant = $delta.PreviousNonCompliantCount
        currentNonCompliant = $delta.CurrentNonCompliantCount
        netNonCompliantChange = $delta.NetNonCompliantChange
    }
    sourceBreakdown = $sourceBreakdown
    toolStatus = $toolStatus
    findings = $modelFindings
    frameworks = $frameworkOptions
    triage = @($triageFindings)
}

$grouped = @($dashboardFindings | Group-Object -Property Category | Sort-Object Name)
$staticCategoryHtml = foreach ($categoryGroup in $grouped) {
    $catRows = foreach ($f in @($categoryGroup.Group | Sort-Object Severity, Title)) {
        $compliantLabel = if ($f.Compliant) { 'Compliant' } else { 'Non-compliant' }
        $deltaLabel = if ($f.DeltaStatus) { $f.DeltaStatus } else { 'Unchanged' }
        $frameworks = @((Get-FrameworkNames -Finding $f) | ForEach-Object { HE $_ }) -join ', '
        @"
<tr>
  <td>$(HE $f.Title)</td>
  <td>$(HE $f.Source)</td>
  <td>$(HE $f.Severity)</td>
  <td>$compliantLabel</td>
  <td>$deltaLabel</td>
  <td>$(HE $frameworks)</td>
  <td class="resource-id">$(HE $f.ResourceId)</td>
  <td>$(HE $f.Detail)</td>
  <td>$(Linkify $f.Remediation)</td>
</tr>
"@
    }

    @"
<details open>
  <summary><strong>$(HE $categoryGroup.Name)</strong> <span class="cat-count">($($categoryGroup.Count))</span></summary>
  <table class="findings-table static-table">
    <thead>
      <tr>
        <th>Title</th>
        <th>Source</th>
        <th>Severity</th>
        <th>Compliance</th>
        <th>Delta</th>
        <th>Frameworks</th>
        <th>Resource ID</th>
        <th>Detail</th>
        <th>Remediation</th>
      </tr>
    </thead>
    <tbody>
      $($catRows -join "`n")
    </tbody>
  </table>
</details>
"@
}

$staticFallback = @"
<section aria-label="Static findings report">
  <h2>Static findings view</h2>
  <p>JavaScript is disabled. Showing static report output.</p>
  $($staticCategoryHtml -join "`n")
</section>
"@

$templatePath = Join-Path $PSScriptRoot 'report-template.html'
if (-not (Test-Path $templatePath)) {
    throw "Report template not found: $templatePath"
}

$template = Get-Content $templatePath -Raw -ErrorAction Stop
$modelJson = $model | ConvertTo-Json -Depth 12
$modelJson = $modelJson -replace '</', '<\/'

$html = $template.Replace('{{MODEL_JSON}}', $modelJson).Replace('{{STATIC_REPORT}}', $staticFallback)
$html = Remove-Credentials $html

try {
    $outputDir = Split-Path $OutputPath -Parent
    if (-not (Test-Path $outputDir)) {
        $null = New-Item -ItemType Directory -Path $outputDir -Force
    }
    $html | Set-Content -Path $OutputPath -Encoding UTF8
} catch {
    Write-Error (Remove-Credentials "Failed to write HTML report to ${OutputPath}: $_")
    return
}

Write-Host "HTML report written to: $OutputPath" -ForegroundColor Green
