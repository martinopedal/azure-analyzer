#Requires -Version 7.4
<#
.SYNOPSIS
    Report v2 delta helper — compare current findings against a previous run.

.DESCRIPTION
    Given two arrays of v2 FindingRows (or v1 legacy rows), returns a hashtable keyed
    by a stable composite key (Source|ResourceId|Category|Title) with a classification
    of each current finding as 'New', 'Resolved', or 'Unchanged'.

    - 'New'       — present in current, absent in previous.
    - 'Resolved'  — present in previous, absent in current (emitted as synthetic rows).
    - 'Unchanged' — present in both.

    The returned shape is:
      @{
        Status    = @{ '<key>' = 'New' | 'Resolved' | 'Unchanged' ; ... }
        Resolved  = @( <synthetic rows from previous run that vanished> )
        Summary   = [pscustomobject]@{ New = <int>; Resolved = <int>; Unchanged = <int>; NetNonCompliantDelta = <int> }
      }

    Also provides:
      Resolve-BaselineRun  — discovers the most-recent prior results.json under an OutputRoot.
      Get-RunTrend         — aggregates the last N runs into a trend array (oldest first) for sparklines.

    Safe under StrictMode — all property reads are PSObject-probed.
#>
Set-StrictMode -Version Latest

function Get-ReportDeltaKey {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)] [PSCustomObject] $Row
    )
    $src = if ($Row.PSObject.Properties['Source']     -and $Row.Source)     { [string]$Row.Source }     else { '' }
    $rid = if ($Row.PSObject.Properties['ResourceId'] -and $Row.ResourceId) { [string]$Row.ResourceId } else { '' }
    if (-not $rid -and $Row.PSObject.Properties['EntityId'] -and $Row.EntityId) { $rid = [string]$Row.EntityId }
    $cat = if ($Row.PSObject.Properties['Category']   -and $Row.Category)   { [string]$Row.Category }   else { '' }
    $title = if ($Row.PSObject.Properties['Title']    -and $Row.Title)      { [string]$Row.Title }      else { '' }
    return "{0}|{1}|{2}|{3}" -f $src, $rid.ToLowerInvariant(), $cat, $title
}

function Get-ReportDelta {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)] $Current,
        [Parameter(Mandatory)] $Previous
    )

    $currentArr  = @($Current)
    $previousArr = @($Previous)

    $currentIndex  = @{}
    $previousIndex = @{}

    foreach ($r in $currentArr) {
        if (-not $r) { continue }
        $k = Get-ReportDeltaKey -Row $r
        if (-not $currentIndex.ContainsKey($k)) { $currentIndex[$k] = $r }
    }
    foreach ($r in $previousArr) {
        if (-not $r) { continue }
        $k = Get-ReportDeltaKey -Row $r
        if (-not $previousIndex.ContainsKey($k)) { $previousIndex[$k] = $r }
    }

    $status   = @{}
    $newCount = 0
    $unchangedCount = 0

    foreach ($k in $currentIndex.Keys) {
        if ($previousIndex.ContainsKey($k)) {
            $status[$k] = 'Unchanged'
            $unchangedCount++
        } else {
            $status[$k] = 'New'
            $newCount++
        }
    }

    $resolved = [System.Collections.Generic.List[object]]::new()
    foreach ($k in $previousIndex.Keys) {
        if (-not $currentIndex.ContainsKey($k)) {
            $status[$k] = 'Resolved'
            $resolved.Add($previousIndex[$k]) | Out-Null
        }
    }

    $curNonCompliant = @($currentArr  | Where-Object { $_ -and $_.PSObject.Properties['Compliant'] -and -not $_.Compliant }).Count
    $prevNonCompliant = @($previousArr | Where-Object { $_ -and $_.PSObject.Properties['Compliant'] -and -not $_.Compliant }).Count

    return [pscustomobject]@{
        Status   = $status
        Resolved = @($resolved)
        Summary  = [pscustomobject]@{
            New       = $newCount
            Resolved  = $resolved.Count
            Unchanged = $unchangedCount
            NetNonCompliantDelta = ($curNonCompliant - $prevNonCompliant)
        }
    }
}

function Resolve-BaselineRun {
    <#
    .SYNOPSIS
        Returns the path to the most recent prior results.json under OutputRoot, excluding CurrentRunId.
    .PARAMETER OutputRoot
        The output root directory that contains per-run subdirectories each with a results.json.
    .PARAMETER CurrentRunId
        The directory name of the current run to exclude from the search.
    .OUTPUTS
        [string] path to results.json, or $null if no prior run exists.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)] [string] $OutputRoot,
        [Parameter(Mandatory)] [string] $CurrentRunId
    )
    if (-not (Test-Path $OutputRoot)) { return $null }
    $candidates = @(
        Get-ChildItem -Path $OutputRoot -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -ne $CurrentRunId } |
        ForEach-Object {
            $rf = Join-Path $_.FullName 'results.json'
            if (Test-Path $rf) {
                [pscustomobject]@{ Path = $rf; LastWriteTime = (Get-Item $rf).LastWriteTime }
            }
        } |
        Sort-Object LastWriteTime -Descending
    )
    if ($candidates.Count -gt 0) { return $candidates[0].Path }
    return $null
}

function Get-RunTrend {
    <#
    .SYNOPSIS
        Aggregates the last N run directories under OutputRoot into a trend array ordered oldest to newest.
    .PARAMETER OutputRoot
        Directory that contains per-run subdirectories each holding a results.json.
    .PARAMETER MaxRuns
        Maximum number of runs to include (default 10). The most recent N are selected, then sorted oldest first.
    .OUTPUTS
        Array of [pscustomobject]@{ RunId; Timestamp; Total; NonCompliant; BySeverity = @{ Critical; High; Medium; Low; Info } }
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)] [string] $OutputRoot,
        [int] $MaxRuns = 10
    )
    $result = [System.Collections.Generic.List[object]]::new()
    if (-not (Test-Path $OutputRoot)) { return @($result) }

    $runs = @(
        Get-ChildItem -Path $OutputRoot -Directory -ErrorAction SilentlyContinue |
        ForEach-Object {
            $rf = Join-Path $_.FullName 'results.json'
            if (Test-Path $rf) {
                [pscustomobject]@{ RunId = $_.Name; ResultsFile = $rf; LastWriteTime = (Get-Item $rf).LastWriteTime }
            }
        } |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First $MaxRuns |
        Sort-Object LastWriteTime  # oldest to newest for sparkline direction
    )

    foreach ($run in $runs) {
        try {
            $findings = @(Get-Content $run.ResultsFile -Raw | ConvertFrom-Json -ErrorAction Stop)
            $total       = $findings.Count
            $nonCompliant = @($findings | Where-Object {
                $_ -and
                $_.PSObject.Properties['Compliant'] -and
                -not $_.Compliant
            }).Count
            $sev = @{ Critical = 0; High = 0; Medium = 0; Low = 0; Info = 0 }
            foreach ($level in @('Critical','High','Medium','Low','Info')) {
                $sev[$level] = @($findings | Where-Object {
                    $_ -and
                    $_.PSObject.Properties['Severity'] -and
                    $_.Severity -eq $level -and
                    $_.PSObject.Properties['Compliant'] -and
                    -not $_.Compliant
                }).Count
            }
            $result.Add([pscustomobject]@{
                RunId        = $run.RunId
                Timestamp    = $run.LastWriteTime
                Total        = $total
                NonCompliant = $nonCompliant
                BySeverity   = [pscustomobject]$sev
            })
        } catch {
            Write-Warning "Get-RunTrend: could not parse $($run.ResultsFile): $_"
        }
    }
    return @($result)
}
