#Requires -Version 7.4
<#
.SYNOPSIS
    Shared scan-state and delta-history layer for incremental / scheduled runs.

.DESCRIPTION
    Persists a small JSON document under <OutputPath>/state/scan-state.json that
    captures, between runs:

      * Run metadata: last run time, last run mode, last baseline time.
      * Per-tool status: lastScanUtc, lastSuccessUtc, runMode, sinceUsedUtc,
        status, findingCount.
      * Per-finding history (keyed by Get-ReportDeltaKey): FirstSeenUtc,
        LastSeenUtc, LastScanUtc -- so age and recurrence can be reported
        independently of finding payload timestamps.

    The API is intentionally additive. Tool wrappers that have not yet
    opted into incremental queries are still safe; the orchestrator marks them
    as FullFallback when -Incremental is requested.

    All disk writes route through Remove-Credentials when available, and all
    paths are validated to stay under the supplied state root (no traversal).
#>
[CmdletBinding()]
param ()

Set-StrictMode -Version Latest

$script:ScanStateSchemaVersion = 1
$script:ScanStateRunModes      = @('Full','Incremental','Cached','FullFallback','Partial')

# Dot-source ReportDelta if available so Get-ReportDeltaKey is in scope.
$script:_scanStateReportDeltaPath = Join-Path $PSScriptRoot 'ReportDelta.ps1'
if ((Test-Path $script:_scanStateReportDeltaPath) -and -not (Get-Command Get-ReportDeltaKey -ErrorAction SilentlyContinue)) {
    . $script:_scanStateReportDeltaPath
}

function Get-ScanStateRoot {
    <#
    .SYNOPSIS
        Returns the canonical state directory under an output path.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $OutputPath
    )
    return [System.IO.Path]::GetFullPath((Join-Path $OutputPath 'state'))
}

function Get-ScanStatePath {
    <#
    .SYNOPSIS
        Returns the canonical scan-state.json path under an output path.
        Validates no traversal escapes the state root.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $OutputPath,

        [string] $FileName = 'scan-state.json'
    )

    if ($FileName -match '[/\\]' -or $FileName -match '\.\.') {
        throw "ScanState file name '$FileName' must be a simple file name."
    }

    $root = Get-ScanStateRoot -OutputPath $OutputPath
    $resolved = [System.IO.Path]::GetFullPath((Join-Path $root $FileName))
    $sep = [System.IO.Path]::DirectorySeparatorChar
    $rootWithSep = if ($root.EndsWith($sep)) { $root } else { "$root$sep" }
    if (-not $resolved.StartsWith($rootWithSep, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "ScanState path resolution escaped state root: $resolved"
    }
    return $resolved
}

function New-EmptyScanState {
    <#
    .SYNOPSIS
        Returns a fresh scan-state hashtable with the current schema.
    #>
    [CmdletBinding()]
    param ()
    return [ordered]@{
        schemaVersion = $script:ScanStateSchemaVersion
        runs = [ordered]@{
            lastRunUtc      = $null
            lastRunMode     = $null
            lastBaselineUtc = $null
        }
        tools    = @{}
        findings = @{}
    }
}

function ConvertTo-ScanStateHashtable {
    param ($Object)
    if ($null -eq $Object) { return $null }
    if ($Object -is [hashtable] -or $Object -is [System.Collections.IDictionary]) { return $Object }
    if ($Object -is [System.Management.Automation.PSCustomObject]) {
        $h = @{}
        foreach ($prop in $Object.PSObject.Properties) {
            $h[$prop.Name] = ConvertTo-ScanStateHashtable -Object $prop.Value
        }
        return $h
    }
    return $Object
}

function Read-ScanState {
    <#
    .SYNOPSIS
        Loads scan-state from disk. Returns a fresh state if missing or corrupt.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $OutputPath
    )

    $path = Get-ScanStatePath -OutputPath $OutputPath
    if (-not (Test-Path $path)) {
        return New-EmptyScanState
    }

    try {
        $raw = Get-Content -Raw -Path $path -ErrorAction Stop
        $obj = $raw | ConvertFrom-Json -ErrorAction Stop
        $state = ConvertTo-ScanStateHashtable -Object $obj
        if (-not $State.Contains('schemaVersion')) {
            return New-EmptyScanState
        }
        if (-not $State.Contains('runs'))     { $state['runs']     = (New-EmptyScanState).runs }
        if (-not $State.Contains('tools'))    { $state['tools']    = @{} }
        if (-not $State.Contains('findings')) { $state['findings'] = @{} }
        return $state
    } catch {
        Write-Warning "Scan state '$path' is corrupt or unreadable; starting fresh. $_"
        return New-EmptyScanState
    }
}

function Write-ScanState {
    <#
    .SYNOPSIS
        Atomically writes scan-state to disk under <OutputPath>/state/.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $OutputPath,

        [Parameter(Mandatory)]
        [ValidateNotNull()]
        $State
    )

    $root = Get-ScanStateRoot -OutputPath $OutputPath
    if (-not (Test-Path $root)) {
        $null = New-Item -ItemType Directory -Path $root -Force
    }

    $path = Get-ScanStatePath -OutputPath $OutputPath
    $json = $State | ConvertTo-Json -Depth 10
    if (Get-Command Remove-Credentials -ErrorAction SilentlyContinue) {
        $json = Remove-Credentials $json
    }

    $tempPath = "$path.tmp-$([Guid]::NewGuid().ToString('N'))"
    Set-Content -Path $tempPath -Value $json -Encoding utf8
    Move-Item -Path $tempPath -Destination $path -Force
    return $path
}

function Resolve-IncrementalSince {
    <#
    .SYNOPSIS
        Resolves the effective -Since DateTime for a given tool.

    .DESCRIPTION
        Precedence:
          1. Explicit $Override (operator-controlled) wins.
          2. Else, when -Incremental is requested, returns the previous
             lastSuccessUtc for that tool (so each tool gets its own window).
          3. Else, returns $null (full scan).
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)] $State,
        [Parameter(Mandatory)] [string] $Tool,
        [switch] $Incremental,
        [Nullable[datetime]] $Override
    )

    if ($null -ne $Override) { return [datetime]::SpecifyKind($Override, [System.DateTimeKind]::Utc)
    }
    if (-not $Incremental) { return $null }

    if (-not $State.Contains('tools') -or -not $State['tools']) { return $null }
    $tools = $State['tools']
    if ($tools -is [hashtable] -or $tools -is [System.Collections.IDictionary]) {
        if (-not $tools.Contains($Tool)) { return $null }
        $entry = $tools[$Tool]
    } elseif ($tools.PSObject.Properties[$Tool]) {
        $entry = $tools.$Tool
    } else {
        return $null
    }
    if ($null -eq $entry) { return $null }

    $val = $null
    if ($entry -is [hashtable] -or $entry -is [System.Collections.IDictionary]) {
        if ($entry.Contains('lastSuccessUtc')) { $val = $entry['lastSuccessUtc'] }
    } elseif ($entry.PSObject.Properties['lastSuccessUtc']) {
        $val = $entry.lastSuccessUtc
    }
    if (-not $val) { return $null }
    try {
        return [datetime]::Parse($val, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AssumeUniversal -bor [System.Globalization.DateTimeStyles]::AdjustToUniversal)
    } catch {
        return $null
    }
}

function Update-ScanStateToolEntry {
    <#
    .SYNOPSIS
        Records the outcome of a tool run inside the scan-state.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)] $State,
        [Parameter(Mandatory)] [string] $Tool,
        [Parameter(Mandatory)] [ValidateSet('Success','Failed','Skipped','Partial')] [string] $Status,
        [ValidateSet('Full','Incremental','Cached','FullFallback','Partial')] [string] $RunMode = 'Full',
        [int] $FindingCount = 0,
        [Nullable[datetime]] $SinceUsed,
        [Nullable[datetime]] $Now
    )

    if (-not $State.Contains('tools') -or $null -eq $State['tools']) { $State['tools'] = @{} }

    $nowUtc = if ($null -ne $Now) { ([datetime]$Now).ToUniversalTime() } else { (Get-Date).ToUniversalTime() }
    $iso    = $nowUtc.ToString('o')

    $entry = $null
    if ($State['tools'].Contains($Tool)) {
        $existing = $State['tools'][$Tool]
        $entry = ConvertTo-ScanStateHashtable -Object $existing
    }
    if (-not $entry -or -not ($entry -is [hashtable] -or $entry -is [System.Collections.IDictionary])) {
        $entry = [ordered]@{
            lastScanUtc    = $null
            lastSuccessUtc = $null
            runMode        = $null
            sinceUsedUtc   = $null
            status         = $null
            findingCount   = 0
        }
    }

    $entry['lastScanUtc']  = $iso
    $entry['runMode']      = $RunMode
    $entry['status']       = $Status
    $entry['findingCount'] = [int]$FindingCount
    $entry['sinceUsedUtc'] = if ($null -ne $SinceUsed) { ([datetime]$SinceUsed).ToUniversalTime().ToString('o') } else { $null }
    # Only fully-successful runs advance the incremental watermark. A Partial run
    # means some findings may have been missed; advancing would cause the next
    # -Incremental run to skip the window that contained the misses (#94 R1).
    if ($Status -eq 'Success') {
        $entry['lastSuccessUtc'] = $iso
    }

    $State['tools'][$Tool] = $entry
    return $State
}

function Update-FindingHistoryFromDelta {
    <#
    .SYNOPSIS
        Updates per-finding history (FirstSeenUtc / LastSeenUtc / LastScanUtc)
        from a current findings array. Resolved (absent) keys keep their last
        timestamps so they remain trendable.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)] $State,
        [Parameter(Mandatory)] $Current,
        [Nullable[datetime]] $Now
    )

    if (-not (Get-Command Get-ReportDeltaKey -ErrorAction SilentlyContinue)) {
        throw "Get-ReportDeltaKey not available. Dot-source ReportDelta.ps1 first."
    }

    $nowUtc = if ($null -ne $Now) { ([datetime]$Now).ToUniversalTime() } else { (Get-Date).ToUniversalTime() }
    $iso    = $nowUtc.ToString('o')

    if (-not $State.Contains('findings') -or $null -eq $State['findings']) { $State['findings'] = @{} }
    $hist = $State['findings']

    foreach ($row in @($Current)) {
        if (-not $row) { continue }
        $key = Get-ReportDeltaKey -Row $row
        if ($hist.Contains($key)) {
            $existing = ConvertTo-ScanStateHashtable -Object $hist[$key]
            if (-not $existing.Contains('FirstSeenUtc') -or -not $existing['FirstSeenUtc']) {
                $existing['FirstSeenUtc'] = $iso
            }
            $existing['LastSeenUtc'] = $iso
            $existing['LastScanUtc'] = $iso
            $hist[$key] = $existing
        } else {
            $hist[$key] = [ordered]@{
                FirstSeenUtc = $iso
                LastSeenUtc  = $iso
                LastScanUtc  = $iso
            }
        }
    }

    $State['findings'] = $hist
    return $State
}

function Update-ScanStateRun {
    <#
    .SYNOPSIS
        Stamps run-level metadata on the state document.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)] $State,
        [Parameter(Mandatory)] [ValidateSet('Full','Incremental','Cached','FullFallback','Partial')] [string] $RunMode,
        [Nullable[datetime]] $Now,
        [switch] $UpdateBaseline
    )

    $nowUtc = if ($null -ne $Now) { ([datetime]$Now).ToUniversalTime() } else { (Get-Date).ToUniversalTime() }
    $iso    = $nowUtc.ToString('o')

    if (-not $State.Contains('runs') -or $null -eq $State['runs']) {
        $State['runs'] = (New-EmptyScanState).runs
    }
    $runs = ConvertTo-ScanStateHashtable -Object $State['runs']
    $runs['lastRunUtc']  = $iso
    $runs['lastRunMode'] = $RunMode
    if ($UpdateBaseline -or -not $runs['lastBaselineUtc']) {
        $runs['lastBaselineUtc'] = $iso
    }
    $State['runs'] = $runs
    return $State
}

function Get-ScanStateToolEntry {
    <#
    .SYNOPSIS
        Convenience accessor for a tool's last entry. Returns $null if absent.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)] $State,
        [Parameter(Mandatory)] [string] $Tool
    )
    if (-not $State.Contains('tools') -or $null -eq $State['tools']) { return $null }
    if (-not $State['tools'].Contains($Tool)) { return $null }
    return ConvertTo-ScanStateHashtable -Object $State['tools'][$Tool]
}


