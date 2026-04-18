#Requires -Version 7.4
<#
.SYNOPSIS
    Run history storage for the executive dashboard (Phase 11 / #97).

.DESCRIPTION
    Persists per-run snapshots of results.json (and a small companion run-meta.json)
    under output/history/{yyyy-MM-dd-HHmmss}/ so trend analytics (sparklines, MTTR,
    severity-mix-over-time) can be computed across runs.

    Snapshots are deliberately a shallow copy of the v1 results.json findings only,
    not raw tool output, to keep history disk usage bounded.

    Functions:
      - Save-RunSnapshot       : Copies results.json into history and writes run-meta.json.
      - Get-RunHistory         : Returns ordered (oldest first) snapshot metadata + paths.
      - Remove-OldRunSnapshots : Prunes oldest snapshots beyond the retention count.
#>

Set-StrictMode -Version Latest

function Get-RunHistoryRoot {
    [CmdletBinding()]
    param ([Parameter(Mandatory)] [string] $OutputPath)
    return (Join-Path $OutputPath 'history')
}

function Save-RunSnapshot {
    <#
    .SYNOPSIS
        Persist a snapshot of the current results.json + lightweight metadata into history.
    .PARAMETER OutputPath
        Output directory (typically the orchestrator's -OutputPath, e.g. .\output).
    .PARAMETER ResultsPath
        Path to the v1 results.json that should be snapshotted.
    .PARAMETER Timestamp
        Optional explicit timestamp (defaults to UTC now). Used for deterministic tests.
    .PARAMETER Tools
        Optional list of tool names that ran in this scan.
    .PARAMETER Subscriptions
        Optional list of subscription IDs scanned in this run.
    .OUTPUTS
        [pscustomobject] with Path, MetaPath, Timestamp, FindingCount.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)] [string] $OutputPath,
        [Parameter(Mandatory)] [string] $ResultsPath,
        [datetime] $Timestamp = (Get-Date).ToUniversalTime(),
        [string[]] $Tools = @(),
        [string[]] $Subscriptions = @()
    )

    if (-not (Test-Path $ResultsPath)) {
        Write-Warning "Save-RunSnapshot: results file not found at '$ResultsPath' - skipping snapshot."
        return $null
    }

    if ($Timestamp.Kind -ne [System.DateTimeKind]::Utc) {
        $Timestamp = $Timestamp.ToUniversalTime()
    }

    $historyRoot = Get-RunHistoryRoot -OutputPath $OutputPath
    if (-not (Test-Path $historyRoot)) {
        $null = New-Item -ItemType Directory -Path $historyRoot -Force
    }

    $stamp   = $Timestamp.ToString('yyyy-MM-dd-HHmmss')
    $runDir  = Join-Path $historyRoot $stamp
    if (-not (Test-Path $runDir)) {
        $null = New-Item -ItemType Directory -Path $runDir -Force
    }

    $snapshotPath = Join-Path $runDir 'results.json'
    Copy-Item -Path $ResultsPath -Destination $snapshotPath -Force

    # Build lightweight run-meta.json
    $findings = @()
    try {
        $findings = @(Get-Content $snapshotPath -Raw | ConvertFrom-Json -ErrorAction Stop)
    } catch {
        Write-Warning "Save-RunSnapshot: unable to parse snapshot for severity counts: $_"
    }

    $sevCounts = [ordered]@{
        Critical = 0; High = 0; Medium = 0; Low = 0; Info = 0
    }
    $nonCompliantSevCounts = [ordered]@{
        Critical = 0; High = 0; Medium = 0; Low = 0; Info = 0
    }
    $nonCompliant = 0
    foreach ($f in $findings) {
        if (-not $f) { continue }
        $sev = $null
        if ($f.PSObject.Properties['Severity'] -and $f.Severity) { $sev = [string]$f.Severity }
        $bucket = $null
        switch -Regex ($sev) {
            '^(?i)critical$' { $bucket = 'Critical'; break }
            '^(?i)high$'     { $bucket = 'High'; break }
            '^(?i)medium$'   { $bucket = 'Medium'; break }
            '^(?i)low$'      { $bucket = 'Low'; break }
            '^(?i)info$'     { $bucket = 'Info'; break }
        }
        if ($bucket) { $sevCounts[$bucket]++ }
        $isNonCompliant = $f.PSObject.Properties['Compliant'] -and -not $f.Compliant
        if ($isNonCompliant) {
            $nonCompliant++
            if ($bucket) { $nonCompliantSevCounts[$bucket]++ }
        }
    }

    $meta = [pscustomobject]@{
        Timestamp                     = $Timestamp.ToString('o')
        Stamp                         = $stamp
        Tools                         = @($Tools)
        Subscriptions                 = @($Subscriptions)
        FindingCount                  = @($findings).Count
        NonCompliantCount             = $nonCompliant
        SeverityCounts                = $sevCounts
        NonCompliantSeverityCounts    = $nonCompliantSevCounts
        SchemaVersion                 = '1.1'
    }
    $metaPath = Join-Path $runDir 'run-meta.json'
    $meta | ConvertTo-Json -Depth 5 | Set-Content -Path $metaPath -Encoding UTF8

    return [pscustomobject]@{
        Path         = $snapshotPath
        MetaPath     = $metaPath
        Timestamp    = $Timestamp
        Stamp        = $stamp
        FindingCount = $meta.FindingCount
    }
}

function Get-RunHistory {
    <#
    .SYNOPSIS
        Returns ordered (oldest first) snapshot metadata for every run found under output/history/.
    .OUTPUTS
        Array of [pscustomobject] { Stamp; Timestamp; ResultsPath; MetaPath; Meta }.
        Empty array when no history exists.
    #>
    [CmdletBinding()]
    param ([Parameter(Mandatory)] [string] $OutputPath)

    $historyRoot = Get-RunHistoryRoot -OutputPath $OutputPath
    if (-not (Test-Path $historyRoot)) { return @() }

    $dirs = @(Get-ChildItem -Path $historyRoot -Directory -ErrorAction SilentlyContinue) |
        Sort-Object -Property Name

    $out = [System.Collections.Generic.List[object]]::new()
    foreach ($d in $dirs) {
        $resultsPath = Join-Path $d.FullName 'results.json'
        $metaPath    = Join-Path $d.FullName 'run-meta.json'
        if (-not (Test-Path $resultsPath)) { continue }

        $meta = $null
        if (Test-Path $metaPath) {
            try { $meta = Get-Content $metaPath -Raw | ConvertFrom-Json -ErrorAction Stop } catch { $meta = $null }
        }

        $ts = $null
        if ($meta -and $meta.PSObject.Properties['Timestamp'] -and $meta.Timestamp) {
            try {
                $ts = [datetime]::Parse(
                    [string]$meta.Timestamp,
                    [System.Globalization.CultureInfo]::InvariantCulture,
                    [System.Globalization.DateTimeStyles]::RoundtripKind)
            } catch { $ts = $null }
        }
        if (-not $ts) {
            try {
                $ts = [datetime]::ParseExact(
                    $d.Name, 'yyyy-MM-dd-HHmmss',
                    [System.Globalization.CultureInfo]::InvariantCulture)
            } catch { $ts = $d.CreationTimeUtc }
        }

        $out.Add([pscustomobject]@{
            Stamp       = $d.Name
            Timestamp   = $ts
            ResultsPath = $resultsPath
            MetaPath    = if (Test-Path $metaPath) { $metaPath } else { $null }
            Meta        = $meta
        }) | Out-Null
    }

    return @($out | Sort-Object Timestamp)
}

function Remove-OldRunSnapshots {
    <#
    .SYNOPSIS
        Prune oldest history snapshots beyond -Retention.
    .PARAMETER Retention
        Number of most recent snapshots to keep. Must be >= 1. Default 30.
    .OUTPUTS
        Array of stamps that were removed.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)] [string] $OutputPath,
        [ValidateRange(1, 365)]
        [int] $Retention = 30
    )

    $history = @(Get-RunHistory -OutputPath $OutputPath)
    if ($history.Count -le $Retention) { return @() }

    $toRemove = $history | Select-Object -First ($history.Count - $Retention)
    $removed  = [System.Collections.Generic.List[string]]::new()
    foreach ($h in $toRemove) {
        $dir = Split-Path $h.ResultsPath -Parent
        try {
            Remove-Item -Path $dir -Recurse -Force -ErrorAction Stop
            $removed.Add($h.Stamp) | Out-Null
        } catch {
            Write-Warning "Remove-OldRunSnapshots: failed to prune '$dir': $_"
        }
    }
    return @($removed)
}
