#Requires -Version 7.4
<#
.SYNOPSIS
    Compare two entities.json snapshots and classify drift by canonical entity ID.
.DESCRIPTION
    Returns a hashtable with Added, Removed, Modified, and Unchanged arrays.
    Entity keys are canonicalized using ConvertTo-CanonicalEntityId when available.

    Volatile fields intentionally ignored in deep comparison:
      - Observations[*].Id
      - Observations[*].Provenance.RunId
      - Observations[*].Provenance.Timestamp
      - Observations[*].Provenance.RawRecordRef

    These values are run-specific and would otherwise create false-positive drift.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$sanitizePath = Join-Path $PSScriptRoot 'Sanitize.ps1'
if (Test-Path $sanitizePath) { . $sanitizePath }
if (-not (Get-Command Remove-Credentials -ErrorAction SilentlyContinue)) {
    function Remove-Credentials { param ([string] $Text) return $Text }
}

function Get-EntitySnapshotPayload {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [string] $Path
    )

    if (-not (Test-Path $Path)) {
        throw "Snapshot not found: $Path"
    }

    $raw = Get-Content -Path $Path -Raw -ErrorAction Stop
    $parsed = $raw | ConvertFrom-Json -Depth 100 -ErrorAction Stop

    if ($parsed -is [System.Array]) {
        return [pscustomobject]@{
            SchemaVersion = $null
            Entities      = @($parsed)
        }
    }

    if ($parsed.PSObject.Properties['Entities']) {
        return [pscustomobject]@{
            SchemaVersion = if ($parsed.PSObject.Properties['SchemaVersion']) { [string]$parsed.SchemaVersion } else { $null }
            Entities      = @($parsed.Entities)
        }
    }

    if ($parsed.PSObject.Properties['items']) {
        return [pscustomobject]@{
            SchemaVersion = if ($parsed.PSObject.Properties['SchemaVersion']) { [string]$parsed.SchemaVersion } else { $null }
            Entities      = @($parsed.items)
        }
    }

    return [pscustomobject]@{
        SchemaVersion = if ($parsed.PSObject.Properties['SchemaVersion']) { [string]$parsed.SchemaVersion } else { $null }
        Entities      = @($parsed)
    }
}

function Get-CanonicalEntityKey {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [object] $Entity
    )

    $rawEntityId = if ($Entity.PSObject.Properties['EntityId']) { [string]$Entity.EntityId } else { '' }
    $entityType = if ($Entity.PSObject.Properties['EntityType']) { [string]$Entity.EntityType } else { '' }

    if ([string]::IsNullOrWhiteSpace($rawEntityId)) { return $null }
    if ([string]::IsNullOrWhiteSpace($entityType)) { return $rawEntityId.Trim().ToLowerInvariant() }

    if (Get-Command ConvertTo-CanonicalEntityId -ErrorAction SilentlyContinue) {
        try {
            $canonical = ConvertTo-CanonicalEntityId -RawId $rawEntityId -EntityType $entityType
            if ($canonical -and $canonical.PSObject.Properties['CanonicalId'] -and $canonical.CanonicalId) {
                return [string]$canonical.CanonicalId
            }
        } catch {
            Write-Verbose (Remove-Credentials "Canonicalization fallback for '$rawEntityId': $_")
        }
    }

    return $rawEntityId.Trim().ToLowerInvariant()
}

function Test-IsIgnoredPath {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [string] $Path
    )

    $normalized = $Path -replace '\[\d+\]', '[]'
    $normalized = $normalized.TrimStart('.')
    return (
        $normalized -match '^EntityId$' -or
        $normalized -match '^Observations\[\]\.Id$' -or
        $normalized -match '^Observations\[\]\.Provenance\.RunId$' -or
        $normalized -match '^Observations\[\]\.Provenance\.Timestamp$' -or
        $normalized -match '^Observations\[\]\.Provenance\.RawRecordRef$'
    )
}

function Normalize-ForComparison {
    [CmdletBinding()]
    param (
        [AllowNull()]
        [object] $InputObject,
        [string] $Path = ''
    )

    if ($null -eq $InputObject) { return $null }

    if ($InputObject -is [System.Management.Automation.PSCustomObject] -or $InputObject -is [hashtable]) {
        $ordered = [ordered]@{}
        $properties = @()
        if ($InputObject -is [hashtable]) {
            $properties = @($InputObject.Keys | Sort-Object)
            foreach ($name in $properties) {
                $childPath = if ($Path) { "$Path.$name" } else { "$name" }
                if (Test-IsIgnoredPath -Path $childPath) { continue }
                $ordered[$name] = Normalize-ForComparison -InputObject $InputObject[$name] -Path $childPath
            }
        } else {
            $properties = @($InputObject.PSObject.Properties | ForEach-Object { $_.Name } | Sort-Object)
            foreach ($name in $properties) {
                $childPath = if ($Path) { "$Path.$name" } else { "$name" }
                if (Test-IsIgnoredPath -Path $childPath) { continue }
                $ordered[$name] = Normalize-ForComparison -InputObject $InputObject.$name -Path $childPath
            }
        }
        return [pscustomobject]$ordered
    }

    if ($InputObject -is [System.Array] -or ($InputObject -is [System.Collections.IEnumerable] -and $InputObject -isnot [string])) {
        $items = @()
        $idx = 0
        foreach ($item in $InputObject) {
            $items += ,(Normalize-ForComparison -InputObject $item -Path "$Path[$idx]")
            $idx++
        }

        $sorted = @(
            $items |
                Sort-Object {
                    try { ($_ | ConvertTo-Json -Depth 100 -Compress) }
                    catch { [string]$_ }
                }
        )
        return ,$sorted
    }

    return $InputObject
}

function Get-FlatPathMap {
    [CmdletBinding()]
    param (
        [AllowNull()]
        [object] $InputObject,
        [string] $Path = ''
    )

    $map = @{}
    if ($null -eq $InputObject) {
        if ($Path) { $map[$Path] = $null }
        return $map
    }

    if ($InputObject -is [System.Management.Automation.PSCustomObject] -or $InputObject -is [hashtable]) {
        $names = if ($InputObject -is [hashtable]) { @($InputObject.Keys) } else { @($InputObject.PSObject.Properties | ForEach-Object { $_.Name }) }
        foreach ($name in $names) {
            $childPath = if ($Path) { "$Path.$name" } else { "$name" }
            $value = if ($InputObject -is [hashtable]) { $InputObject[$name] } else { $InputObject.$name }
            $childMap = Get-FlatPathMap -InputObject $value -Path $childPath
            foreach ($k in $childMap.Keys) { $map[$k] = $childMap[$k] }
        }
        return $map
    }

    if ($InputObject -is [System.Array] -or ($InputObject -is [System.Collections.IEnumerable] -and $InputObject -isnot [string])) {
        $i = 0
        foreach ($item in $InputObject) {
            $childPath = "$Path[$i]"
            $childMap = Get-FlatPathMap -InputObject $item -Path $childPath
            foreach ($k in $childMap.Keys) { $map[$k] = $childMap[$k] }
            $i++
        }
        if ($i -eq 0 -and $Path) {
            $map[$Path] = @()
        }
        return $map
    }

    if ($Path) { $map[$Path] = $InputObject }
    return $map
}

function Get-ChangedPaths {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [object] $PreviousEntity,
        [Parameter(Mandatory)]
        [object] $CurrentEntity
    )

    $left = Normalize-ForComparison -InputObject $PreviousEntity
    $right = Normalize-ForComparison -InputObject $CurrentEntity
    $leftMap = Get-FlatPathMap -InputObject $left
    $rightMap = Get-FlatPathMap -InputObject $right

    $paths = @($leftMap.Keys + $rightMap.Keys | Sort-Object -Unique)
    $changed = [System.Collections.Generic.List[string]]::new()
    foreach ($path in $paths) {
        if (Test-IsIgnoredPath -Path $path) { continue }
        $leftVal = if ($leftMap.ContainsKey($path)) { $leftMap[$path] } else { $null }
        $rightVal = if ($rightMap.ContainsKey($path)) { $rightMap[$path] } else { $null }
        $leftJson = try { $leftVal | ConvertTo-Json -Depth 30 -Compress } catch { [string]$leftVal }
        $rightJson = try { $rightVal | ConvertTo-Json -Depth 30 -Compress } catch { [string]$rightVal }
        if ($leftJson -ne $rightJson) {
            $changed.Add($path) | Out-Null
        }
    }
    return @($changed.ToArray())
}

function Get-DriftSeverity {
    [CmdletBinding()]
    param (
        [string[]] $ChangedPaths = @(),
        [object] $PreviousEntity,
        [object] $CurrentEntity
    )

    $previousJson = ''
    $currentJson = ''
    try { $previousJson = $PreviousEntity | ConvertTo-Json -Depth 20 -Compress } catch { $previousJson = '' }
    try { $currentJson = $CurrentEntity | ConvertTo-Json -Depth 20 -Compress } catch { $currentJson = '' }

    $context = @(
        ($ChangedPaths -join ' ')
        $previousJson
        $currentJson
    ) -join ' '

    if ($context -match '(?i)\brbac\b|\brole\b|roleassignment|permission|owner|accesspolicy|privilege') {
        return 'Medium'
    }

    return 'Info'
}

function Get-LatestPreviousRun {
    <#
    .SYNOPSIS
        Returns the most recently modified sibling run directory containing entities.json.
    .PARAMETER OutputRoot
        Root directory containing per-run output directories.
    .PARAMETER CurrentRunDir
        Current run output directory (excluded from candidates).
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [string] $OutputRoot,
        [Parameter(Mandatory)]
        [string] $CurrentRunDir
    )

    if (-not (Test-Path $OutputRoot -PathType Container)) { return $null }

    $currentResolved = $null
    if (Test-Path $CurrentRunDir -PathType Container) {
        $currentResolved = (Resolve-Path $CurrentRunDir).Path
    }

    $candidates = @(
        Get-ChildItem -Path $OutputRoot -Directory -ErrorAction SilentlyContinue |
            Where-Object {
                if ($currentResolved -and $_.FullName -eq $currentResolved) { return $false }
                Test-Path (Join-Path $_.FullName 'entities.json')
            } |
            Sort-Object LastWriteTimeUtc -Descending
    )

    if ($candidates.Count -eq 0) { return $null }
    return $candidates[0].FullName
}

function Compare-EntitySnapshots {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [string] $Previous,
        [Parameter(Mandatory)]
        [string] $Current
    )

    $previousPayload = Get-EntitySnapshotPayload -Path $Previous
    $currentPayload = Get-EntitySnapshotPayload -Path $Current

    $previousIndex = @{}
    foreach ($entity in @($previousPayload.Entities)) {
        if (-not $entity) { continue }
        $key = Get-CanonicalEntityKey -Entity $entity
        if (-not $key) { continue }
        if (-not $previousIndex.ContainsKey($key)) { $previousIndex[$key] = $entity }
    }

    $currentIndex = @{}
    foreach ($entity in @($currentPayload.Entities)) {
        if (-not $entity) { continue }
        $key = Get-CanonicalEntityKey -Entity $entity
        if (-not $key) { continue }
        if (-not $currentIndex.ContainsKey($key)) { $currentIndex[$key] = $entity }
    }

    $added = [System.Collections.Generic.List[object]]::new()
    $removed = [System.Collections.Generic.List[object]]::new()
    $modified = [System.Collections.Generic.List[object]]::new()
    $unchanged = [System.Collections.Generic.List[object]]::new()

    foreach ($key in $currentIndex.Keys) {
        $curr = $currentIndex[$key]
        if (-not $previousIndex.ContainsKey($key)) {
            $added.Add([pscustomobject]@{
                    ChangeKind = 'Added'
                    EntityId   = $key
                    EntityType = if ($curr.PSObject.Properties['EntityType']) { $curr.EntityType } else { $null }
                    Platform   = if ($curr.PSObject.Properties['Platform']) { $curr.Platform } else { $null }
                    Severity   = 'Info'
                    Previous   = $null
                    Current    = $curr
                    ChangedPaths = @()
                }) | Out-Null
            continue
        }

        $prev = $previousIndex[$key]
        $normalizedPrev = Normalize-ForComparison -InputObject $prev
        $normalizedCurr = Normalize-ForComparison -InputObject $curr
        $prevJson = $normalizedPrev | ConvertTo-Json -Depth 100 -Compress
        $currJson = $normalizedCurr | ConvertTo-Json -Depth 100 -Compress

        if ($prevJson -eq $currJson) {
            $unchanged.Add([pscustomobject]@{
                    ChangeKind = 'Unchanged'
                    EntityId   = $key
                    EntityType = if ($curr.PSObject.Properties['EntityType']) { $curr.EntityType } else { $null }
                    Platform   = if ($curr.PSObject.Properties['Platform']) { $curr.Platform } else { $null }
                    Severity   = 'Info'
                    Previous   = $prev
                    Current    = $curr
                    ChangedPaths = @()
                }) | Out-Null
            continue
        }

        $changedPaths = Get-ChangedPaths -PreviousEntity $prev -CurrentEntity $curr
        $severity = Get-DriftSeverity -ChangedPaths $changedPaths -PreviousEntity $prev -CurrentEntity $curr
        $modified.Add([pscustomobject]@{
                ChangeKind = 'Modified'
                EntityId   = $key
                EntityType = if ($curr.PSObject.Properties['EntityType']) { $curr.EntityType } else { if ($prev.PSObject.Properties['EntityType']) { $prev.EntityType } else { $null } }
                Platform   = if ($curr.PSObject.Properties['Platform']) { $curr.Platform } else { if ($prev.PSObject.Properties['Platform']) { $prev.Platform } else { $null } }
                Severity   = $severity
                Previous   = $prev
                Current    = $curr
                ChangedPaths = @($changedPaths)
            }) | Out-Null
    }

    foreach ($key in $previousIndex.Keys) {
        if ($currentIndex.ContainsKey($key)) { continue }
        $prev = $previousIndex[$key]
        $removed.Add([pscustomobject]@{
                ChangeKind = 'Removed'
                EntityId   = $key
                EntityType = if ($prev.PSObject.Properties['EntityType']) { $prev.EntityType } else { $null }
                Platform   = if ($prev.PSObject.Properties['Platform']) { $prev.Platform } else { $null }
                Severity   = 'Info'
                Previous   = $prev
                Current    = $null
                ChangedPaths = @()
            }) | Out-Null
    }

    return [ordered]@{
        Added     = @($added)
        Removed   = @($removed)
        Modified  = @($modified)
        Unchanged = @($unchanged)
    }
}
