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
        Returns the path to the most recent snapshot in a snapshot index, for use as a delta baseline.
    .DESCRIPTION
        Reads SnapshotDir/index.json (SchemaVersion 1.0, written by Add-RunSnapshot) and returns
        the full path to the most recent entry's snapshot file, or $null when no prior snapshot exists.

        Call this BEFORE Add-RunSnapshot so the current run is not yet in the index.
        The snapshot-index design avoids scanning parent directories for sibling results.json files,
        which would produce false positives when runs share a flat output root (e.g. the default .\output).

        Note: only snapshots registered via Add-RunSnapshot appear in the index.  Partial or
        incremental output directories (e.g. #94 layer dirs) are never indexed unless an explicit
        Add-RunSnapshot call targets them.
    .PARAMETER SnapshotDir
        Path to the snapshot directory (e.g. $OutputPath\snapshots).
    .OUTPUTS
        [string] absolute path to the baseline snapshot file, or $null.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)] [string] $SnapshotDir
    )
    if (-not (Test-Path $SnapshotDir)) { return $null }
    $indexPath = Join-Path $SnapshotDir 'index.json'
    if (-not (Test-Path $indexPath)) { return $null }
    try {
        $parsed = Get-Content $indexPath -Raw | ConvertFrom-Json -ErrorAction Stop
        if (-not ($parsed.PSObject.Properties['SchemaVersion'])) {
            Write-Warning "Resolve-BaselineRun: index.json has no SchemaVersion; skipping baseline."
            return $null
        }
        if ($parsed.SchemaVersion -ne '1.0') {
            Write-Warning "Resolve-BaselineRun: unknown index SchemaVersion '$($parsed.SchemaVersion)'; skipping baseline."
            return $null
        }
        if (-not ($parsed.PSObject.Properties['Entries']) -or $null -eq $parsed.Entries) {
            Write-Warning "Resolve-BaselineRun: index.json Entries is absent or null; skipping baseline."
            return $null
        }
        $entries = @($parsed.Entries)
        if ($entries.Count -eq 0) { return $null }
        # Last entry is the most recently added snapshot.
        $latest = $entries[-1]
        $snapshotPath = Join-Path $SnapshotDir ([string]$latest.SnapshotFile)
        if (Test-Path $snapshotPath) { return $snapshotPath }
    } catch {
        Write-Warning "Resolve-BaselineRun: could not read snapshot index at ${SnapshotDir}: $_"
    }
    return $null
}

function Get-RunTrend {
    <#
    .SYNOPSIS
        Aggregates the last N snapshots from a snapshot index into a trend array ordered oldest to newest.
    .DESCRIPTION
        Reads SnapshotDir/index.json (SchemaVersion 1.0, written by Add-RunSnapshot) and returns an
        array of run-summary objects ordered oldest to newest so a sparkline reads left to right.

        Call this AFTER Add-RunSnapshot so the current run is included in the trend.

        Only entries registered via Add-RunSnapshot appear; partial or incremental layer directories
        (e.g. #94 per-tool dirs) are excluded by design since they are never indexed here.
    .PARAMETER SnapshotDir
        Path to the snapshot directory (e.g. $OutputPath\snapshots).
    .PARAMETER MaxRuns
        Maximum number of runs to include (default 10). The most recent N index entries are selected.
    .OUTPUTS
        Array of [pscustomobject]@{ RunId; Timestamp; Total; NonCompliant; BySeverity = @{ Critical; High; Medium; Low; Info } }
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)] [string] $SnapshotDir,
        [int] $MaxRuns = 10
    )
    $result = [System.Collections.Generic.List[object]]::new()
    if (-not (Test-Path $SnapshotDir)) { return @($result) }
    $indexPath = Join-Path $SnapshotDir 'index.json'
    if (-not (Test-Path $indexPath)) { return @($result) }
    try {
        $parsed = Get-Content $indexPath -Raw | ConvertFrom-Json -ErrorAction Stop
        if (-not ($parsed.PSObject.Properties['SchemaVersion'])) {
            Write-Warning "Get-RunTrend: index.json has no SchemaVersion; skipping trend."
            return @($result)
        }
        if ($parsed.SchemaVersion -ne '1.0') {
            Write-Warning "Get-RunTrend: unknown index SchemaVersion '$($parsed.SchemaVersion)'; skipping trend."
            return @($result)
        }
        if (-not ($parsed.PSObject.Properties['Entries']) -or $null -eq $parsed.Entries) {
            Write-Warning "Get-RunTrend: index.json Entries is absent or null; skipping trend."
            return @($result)
        }
        $entries = @($parsed.Entries)
    } catch {
        Write-Warning "Get-RunTrend: could not read index at ${SnapshotDir}: $_"
        return @($result)
    }
    # Take the most recent MaxRuns entries; they are already in insertion (oldest-first) order.
    $selected = @($entries | Select-Object -Last $MaxRuns)
    foreach ($entry in $selected) {
        $snapshotPath = Join-Path $SnapshotDir ([string]$entry.SnapshotFile)
        if (-not (Test-Path $snapshotPath)) {
            Write-Warning "Get-RunTrend: snapshot file missing, skipping: $snapshotPath"
            continue
        }
        try {
            $findings     = @(Get-Content $snapshotPath -Raw | ConvertFrom-Json -ErrorAction Stop)
            $total        = $findings.Count
            $nonCompliant = @($findings | Where-Object {
                $_ -and $_.PSObject.Properties['Compliant'] -and -not $_.Compliant
            }).Count
            $sev = @{ Critical = 0; High = 0; Medium = 0; Low = 0; Info = 0 }
            foreach ($level in @('Critical','High','Medium','Low','Info')) {
                $sev[$level] = @($findings | Where-Object {
                    $_ -and
                    $_.PSObject.Properties['Severity'] -and $_.Severity -eq $level -and
                    $_.PSObject.Properties['Compliant'] -and -not $_.Compliant
                }).Count
            }
            $ts = if ($entry.PSObject.Properties['Timestamp'] -and $entry.Timestamp) {
                try { [datetime]$entry.Timestamp } catch { [datetime]::MinValue }
            } else { [datetime]::MinValue }
            $result.Add([pscustomobject]@{
                RunId        = [string]$entry.RunId
                Timestamp    = $ts
                Total        = $total
                NonCompliant = $nonCompliant
                BySeverity   = [pscustomobject]$sev
            })
        } catch {
            Write-Warning "Get-RunTrend: could not parse ${snapshotPath}: $_"
        }
    }
    return @($result)
}

function Add-RunSnapshot {
    <#
    .SYNOPSIS
        Archives a results.json into the snapshot directory and updates the snapshot index atomically.
    .DESCRIPTION
        Copies SourceFile into SnapshotDir as <RunId>.json and appends an entry to
        SnapshotDir/index.json (SchemaVersion 1.0).  The index is written atomically via a
        .tmp file + Move-Item -Force to guard against corruption from concurrent runs.
        Entries older than MaxHistory are pruned and their snapshot files deleted.

        Call this AFTER writing results.json and AFTER calling Resolve-BaselineRun (so the
        current run does not appear in the baseline lookup) but BEFORE calling Get-RunTrend
        (so the current run IS included in the sparkline).
    .PARAMETER SnapshotDir
        Destination snapshot directory.
    .PARAMETER RunId
        Unique identifier for this run.  Use millisecond-precision timestamps plus a random
        suffix (e.g. 'yyyyMMdd-HHmmssfff-NNNN') to avoid second-resolution collisions on
        concurrent or rapid successive runs.
    .PARAMETER SourceFile
        Path to the results.json file to archive.
    .PARAMETER MaxHistory
        Maximum number of snapshots to retain (default 10).  Oldest are pruned first.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)] [string] $SnapshotDir,
        [Parameter(Mandatory)] [string] $RunId,
        [Parameter(Mandatory)] [string] $SourceFile,
        [int] $MaxHistory = 10
    )
    if (-not (Test-Path $SourceFile)) {
        Write-Warning "Add-RunSnapshot: source file not found, skipping: $SourceFile"
        return
    }
    $null = New-Item -ItemType Directory -Path $SnapshotDir -Force -ErrorAction SilentlyContinue
    $indexPath = Join-Path $SnapshotDir 'index.json'
    $tmpPath   = Join-Path $SnapshotDir 'index.json.tmp'
    $entries   = [System.Collections.Generic.List[object]]::new()

    # Read existing index; tolerates absent file (first run) or malformed JSON (fresh start).
    if (Test-Path $indexPath) {
        try {
            $parsed = Get-Content $indexPath -Raw | ConvertFrom-Json -ErrorAction Stop
            if ($parsed.PSObject.Properties['SchemaVersion'] -and $parsed.SchemaVersion -eq '1.0') {
                if ($parsed.PSObject.Properties['Entries'] -and $null -ne $parsed.Entries) {
                    foreach ($e in @($parsed.Entries)) { if ($null -ne $e) { $entries.Add($e) | Out-Null } }
                }
            } else {
                Write-Warning "Add-RunSnapshot: existing index has unknown schema; starting fresh."
            }
        } catch {
            Write-Warning "Add-RunSnapshot: could not read existing index, starting fresh: $_"
        }
    }

    # Archive the snapshot before updating the index so a crash between the two
    # leaves the index consistent (entry absent) rather than pointing at a missing file.
    $snapshotFile = "$RunId.json"
    $snapshotDest = Join-Path $SnapshotDir $snapshotFile
    Copy-Item -Path $SourceFile -Destination $snapshotDest -Force

    $entries.Add([pscustomobject]@{
        RunId        = $RunId
        Timestamp    = (Get-Date -Format 'o')
        SnapshotFile = $snapshotFile
    }) | Out-Null

    # Prune oldest entries when over the limit.
    while ($entries.Count -gt $MaxHistory) {
        $oldest = $entries[0]
        $fname  = if ($oldest -and $oldest.PSObject.Properties['SnapshotFile']) {
            [string]$oldest.SnapshotFile
        } else { $null }
        if (-not [string]::IsNullOrWhiteSpace($fname)) {
            $oldFile = Join-Path $SnapshotDir $fname
            if (Test-Path $oldFile) { Remove-Item $oldFile -Force -ErrorAction SilentlyContinue }
        }
        $entries.RemoveAt(0)
    }

    # Atomic write: write to .tmp then rename so a reader never sees a partial file.
    $indexObj = [pscustomobject]@{
        SchemaVersion = '1.0'
        Entries       = @($entries)
    }
    $indexObj | ConvertTo-Json -Depth 4 | Set-Content -Path $tmpPath -Encoding UTF8
    Move-Item -Path $tmpPath -Destination $indexPath -Force
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
