#Requires -Version 7.4
<#
.SYNOPSIS
    Generate machine-readable and markdown drift reports from entity snapshot diffs.
#>
[CmdletBinding()]
param (
    [hashtable] $Comparison,
    [string] $PreviousSnapshot,
    [string] $CurrentSnapshot,
    [string] $OutputPath = (Join-Path $PSScriptRoot '..' '..' 'output')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$sharedRoot = Join-Path $PSScriptRoot '..' 'shared'
$sanitizePath = Join-Path $sharedRoot 'Sanitize.ps1'
if (Test-Path $sanitizePath) { . $sanitizePath }
$comparePath = Join-Path $sharedRoot 'Compare-EntitySnapshots.ps1'
if (Test-Path $comparePath) { . $comparePath }
if (-not (Get-Command Remove-Credentials -ErrorAction SilentlyContinue)) {
    function Remove-Credentials { param ([string] $Text) return $Text }
}

if (-not $Comparison) {
    if (-not $PreviousSnapshot -or -not $CurrentSnapshot) {
        throw "Provide -Comparison or both -PreviousSnapshot and -CurrentSnapshot."
    }
    $Comparison = Compare-EntitySnapshots -Previous $PreviousSnapshot -Current $CurrentSnapshot
}

if (-not (Test-Path $OutputPath)) {
    $null = New-Item -ItemType Directory -Path $OutputPath -Force
}

$added = @($Comparison.Added)
$removed = @($Comparison.Removed)
$modified = @($Comparison.Modified)
$unchanged = @($Comparison.Unchanged)

$all = @($added + $removed + $modified + $unchanged)
$entityTypes = @($all | ForEach-Object { if ($_.EntityType) { [string]$_.EntityType } else { 'Unknown' } } | Sort-Object -Unique)

$byType = [ordered]@{}
foreach ($entityType in $entityTypes) {
    $byType[$entityType] = [ordered]@{
        Added     = @($added | Where-Object { (($_.EntityType ?? 'Unknown')) -eq $entityType }).Count
        Removed   = @($removed | Where-Object { (($_.EntityType ?? 'Unknown')) -eq $entityType }).Count
        Modified  = @($modified | Where-Object { (($_.EntityType ?? 'Unknown')) -eq $entityType }).Count
        Unchanged = @($unchanged | Where-Object { (($_.EntityType ?? 'Unknown')) -eq $entityType }).Count
    }
}

$report = [ordered]@{
    SchemaVersion = '1.0'
    GeneratedAt   = (Get-Date).ToUniversalTime().ToString('o')
    PreviousSnapshot = $PreviousSnapshot
    CurrentSnapshot  = $CurrentSnapshot
    Summary = [ordered]@{
        Added     = $added.Count
        Removed   = $removed.Count
        Modified  = $modified.Count
        Unchanged = $unchanged.Count
        TotalCompared = $all.Count
    }
    ByEntityType = $byType
    Changes = [ordered]@{
        Added     = $added
        Removed   = $removed
        Modified  = $modified
        Unchanged = $unchanged
    }
}

$jsonPath = Join-Path $OutputPath 'drift-report.json'
$mdPath = Join-Path $OutputPath 'drift-report.md'

try {
    $json = $report | ConvertTo-Json -Depth 100
    Set-Content -Path $jsonPath -Value (Remove-Credentials $json) -Encoding UTF8
} catch {
    throw (Remove-Credentials "Failed to write drift-report.json: $_")
}

$lines = [System.Collections.Generic.List[string]]::new()
$lines.Add('# Entity drift report')
$lines.Add('')
$lines.Add("| Metric | Count |")
$lines.Add("|---|---:|")
$lines.Add("| Added | $($added.Count) |")
$lines.Add("| Removed | $($removed.Count) |")
$lines.Add("| Modified | $($modified.Count) |")
$lines.Add("| Unchanged | $($unchanged.Count) |")
$lines.Add('')

if ($PreviousSnapshot) { $lines.Add(('- Previous: `{0}`' -f $PreviousSnapshot)) }
if ($CurrentSnapshot) { $lines.Add(('- Current: `{0}`' -f $CurrentSnapshot)) }
$lines.Add('')

function Add-ChangeTable {
    param (
        [Parameter(Mandatory)][string] $Title,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]] $Rows
    )

    $lines.Add("## $Title")
    $lines.Add('')
    if (@($Rows).Count -eq 0) {
        $lines.Add('No entries.')
        $lines.Add('')
        return
    }

    $groups = @($Rows | Group-Object -Property { if ($_.EntityType) { $_.EntityType } else { 'Unknown' } } | Sort-Object Name)
    foreach ($group in $groups) {
        $lines.Add("### $($group.Name)")
        $lines.Add('')
        $lines.Add('| EntityId | Severity | Changed fields |')
        $lines.Add('|---|---|---|')
        foreach ($row in @($group.Group | Sort-Object EntityId)) {
            $changed = if ($row.ChangedPaths -and @($row.ChangedPaths).Count -gt 0) {
                (@($row.ChangedPaths) -join ', ') -replace '\|', '\|'
            } else {
                '-'
            }
            $entityId = ([string]$row.EntityId) -replace '\|', '\|'
            $severity = if ($row.Severity) { [string]$row.Severity } else { 'Info' }
            $lines.Add("| $entityId | $severity | $changed |")
        }
        $lines.Add('')
    }
}

Add-ChangeTable -Title 'Added entities' -Rows $added
Add-ChangeTable -Title 'Removed entities' -Rows $removed
Add-ChangeTable -Title 'Modified entities' -Rows $modified

try {
    Set-Content -Path $mdPath -Value (Remove-Credentials ($lines -join "`n")) -Encoding UTF8 -NoNewline
} catch {
    throw (Remove-Credentials "Failed to write drift-report.md: $_")
}
