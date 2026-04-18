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

function Get-MttrBySeverity {
    <#
    .SYNOPSIS
        Compute median Mean-Time-To-Remediate (in days) per severity from a run history.
    .DESCRIPTION
        Walks an ordered (oldest-first) array of run history entries (as produced by
        Get-RunHistory). For each consecutive pair of runs, any finding present in the
        earlier run but absent from the later run is treated as resolved at the later
        run's timestamp. Days-to-resolve = laterTimestamp - firstSeenTimestamp, where
        firstSeenTimestamp is the earliest run in which that finding appeared.

        Returns one row per severity (Critical/High/Medium/Low/Info) with:
          - Severity
          - ResolvedCount
          - MedianDays  ([double] or $null when ResolvedCount -eq 0)
          - MeanDays    ([double] or $null when ResolvedCount -eq 0)

        MTTR is only meaningful with 3+ runs containing resolved findings; for shorter
        histories the per-severity rows still return with ResolvedCount = 0 and null
        timing values so the caller can render "N/A".

    .PARAMETER History
        Array of objects each with { Timestamp; ResultsPath } (the shape returned by
        modules/shared/RunHistory.ps1::Get-RunHistory). May be empty.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $History
    )

    $severities = @('Critical','High','Medium','Low','Info')
    $stats = @{}
    foreach ($sev in $severities) { $stats[$sev] = [System.Collections.Generic.List[double]]::new() }

    if (-not $History -or $History.Count -lt 2) {
        return @($severities | ForEach-Object {
            [pscustomobject]@{ Severity = $_; ResolvedCount = 0; MedianDays = $null; MeanDays = $null }
        })
    }

    # First-seen index: key -> earliest timestamp + canonical row.
    $firstSeen = @{}
    $previousKeys = $null
    $previousRows = $null
    $previousTs   = $null

    foreach ($run in $History) {
        if (-not $run -or -not (Test-Path $run.ResultsPath)) { continue }
        $rows = @()
        try {
            $rows = @(Get-Content $run.ResultsPath -Raw | ConvertFrom-Json -ErrorAction Stop)
        } catch {
            Write-Warning "Get-MttrBySeverity: could not parse '$($run.ResultsPath)': $_"
            continue
        }

        $thisKeys = @{}
        foreach ($r in $rows) {
            if (-not $r) { continue }
            $k = Get-ReportDeltaKey -Row $r
            if (-not $thisKeys.ContainsKey($k)) { $thisKeys[$k] = $r }
            if (-not $firstSeen.ContainsKey($k)) {
                $firstSeen[$k] = [pscustomobject]@{ Timestamp = $run.Timestamp; Row = $r }
            }
        }

        if ($previousKeys -and $previousTs -and $run.Timestamp) {
            foreach ($k in $previousKeys.Keys) {
                if ($thisKeys.ContainsKey($k)) { continue }
                # Resolved in this run: earlier had it, current does not.
                $row = $previousKeys[$k]
                $sev = if ($row.PSObject.Properties['Severity'] -and $row.Severity) {
                    [string]$row.Severity
                } else { '' }
                $bucket = $null
                switch -Regex ($sev) {
                    '^(?i)critical$' { $bucket = 'Critical'; break }
                    '^(?i)high$'     { $bucket = 'High'; break }
                    '^(?i)medium$'   { $bucket = 'Medium'; break }
                    '^(?i)low$'      { $bucket = 'Low'; break }
                    '^(?i)info$'     { $bucket = 'Info'; break }
                }
                if (-not $bucket) { continue }
                $first = if ($firstSeen.ContainsKey($k)) { $firstSeen[$k].Timestamp } else { $previousTs }
                $days = ($run.Timestamp - $first).TotalDays
                if ($days -lt 0) { $days = 0 }
                $stats[$bucket].Add([double]$days) | Out-Null
            }
        }

        $previousKeys = $thisKeys
        $previousRows = $rows
        $previousTs   = $run.Timestamp
    }

    return @($severities | ForEach-Object {
        $sev = $_
        $vals = @($stats[$sev])
        if ($vals.Count -eq 0) {
            [pscustomobject]@{ Severity = $sev; ResolvedCount = 0; MedianDays = $null; MeanDays = $null }
        } else {
            $sorted = @($vals | Sort-Object)
            $count  = $sorted.Count
            $median = if ($count % 2 -eq 1) {
                $sorted[[math]::Floor($count / 2)]
            } else {
                ($sorted[$count / 2 - 1] + $sorted[$count / 2]) / 2.0
            }
            $mean = ($sorted | Measure-Object -Average).Average
            [pscustomobject]@{
                Severity      = $sev
                ResolvedCount = $count
                MedianDays    = [math]::Round([double]$median, 2)
                MeanDays      = [math]::Round([double]$mean, 2)
            }
        }
    })
}
