#Requires -Version 7.4
<#
.SYNOPSIS
    Identify net-new and escalated Critical findings from a Compare-EntitySnapshots drift result.
.DESCRIPTION
    Given a drift hashtable produced by Compare-EntitySnapshots, returns an array of
    PSCustomObjects describing Critical findings that are genuinely new:

      - 'New'       -- entity appears in Added with one or more Critical observations.
      - 'Escalated' -- entity appears in Modified and the Critical observation count
                       increased compared to the previous snapshot.

    Unchanged entities and modifications that did not increase the Critical count are
    excluded, suppressing noise from standing (known) findings.

    Also exports New-NoBaselineDriftResult, a helper that synthesises an all-Added drift
    result from a single entities.json path. Use this for first-run mode where no previous
    snapshot exists and every Critical observation should be treated as new.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-NewCriticalFindings {
    <#
    .SYNOPSIS
        Returns net-new and escalated Critical findings from a Compare-EntitySnapshots drift result.
    .OUTPUTS
        PSCustomObject[]  Each element has: EntityId, EntityType, ChangeKind (New|Escalated),
                          CriticalObservationCount, Titles (string[]).
    #>
    [CmdletBinding()]
    [OutputType([System.Object[]])]
    param (
        [Parameter(Mandatory)]
        [object] $DriftResult
    )

    $results = [System.Collections.Generic.List[object]]::new()

    # New entities with at least one Critical observation
    foreach ($entry in @($DriftResult.Added)) {
        if (-not $entry -or -not $entry.Current) { continue }
        $critObs = @($entry.Current.Observations | Where-Object {
            $_ -and $_.Severity -and ([string]$_.Severity).ToLowerInvariant() -eq 'critical'
        })
        if ($critObs.Count -eq 0) { continue }
        $results.Add([pscustomobject]@{
            EntityId                 = [string]$entry.EntityId
            EntityType               = if ($entry.EntityType) { [string]$entry.EntityType } else { '' }
            ChangeKind               = 'New'
            CriticalObservationCount = $critObs.Count
            Titles                   = @($critObs | ForEach-Object {
                if ($_.PSObject.Properties['Title'] -and $_.Title) { [string]$_.Title } else { '' }
            })
        }) | Out-Null
    }

    # Modified entities where the Critical observation count increased (severity escalation)
    foreach ($entry in @($DriftResult.Modified)) {
        if (-not $entry) { continue }

        $prevCritCount = 0
        if ($entry.PSObject.Properties['Previous'] -and $entry.Previous -and
            $entry.Previous.PSObject.Properties['Observations']) {
            $prevCritCount = @($entry.Previous.Observations | Where-Object {
                $_ -and $_.Severity -and ([string]$_.Severity).ToLowerInvariant() -eq 'critical'
            }).Count
        }

        $currCritObs = @()
        if ($entry.PSObject.Properties['Current'] -and $entry.Current -and
            $entry.Current.PSObject.Properties['Observations']) {
            $currCritObs = @($entry.Current.Observations | Where-Object {
                $_ -and $_.Severity -and ([string]$_.Severity).ToLowerInvariant() -eq 'critical'
            })
        }
        $currCritCount = $currCritObs.Count

        if ($currCritCount -le $prevCritCount) { continue }

        $results.Add([pscustomobject]@{
            EntityId                 = [string]$entry.EntityId
            EntityType               = if ($entry.EntityType) { [string]$entry.EntityType } else { '' }
            ChangeKind               = 'Escalated'
            CriticalObservationCount = $currCritCount - $prevCritCount
            Titles                   = @($currCritObs | ForEach-Object {
                if ($_.PSObject.Properties['Title'] -and $_.Title) { [string]$_.Title } else { '' }
            })
        }) | Out-Null
    }

    return , $results.ToArray()
}

function New-NoBaselineDriftResult {
    <#
    .SYNOPSIS
        Creates an all-Added drift result from entities.json for first-run (no baseline) mode.
    .DESCRIPTION
        Reads the entities.json at the given path via Get-EntitySnapshotPayload and wraps
        every entity as an 'Added' drift entry. Pass the result to Get-NewCriticalFindings
        to treat every Critical observation as net-new.
    .PARAMETER EntitiesPath
        Absolute path to the current run's entities.json.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param (
        [Parameter(Mandatory)]
        [string] $EntitiesPath
    )

    # Get-EntitySnapshotPayload is defined in Compare-EntitySnapshots.ps1; require it
    if (-not (Get-Command Get-EntitySnapshotPayload -ErrorAction SilentlyContinue)) {
        throw 'Get-EntitySnapshotPayload not found -- dot-source Compare-EntitySnapshots.ps1 first.'
    }

    $payload = Get-EntitySnapshotPayload -Path $EntitiesPath
    $added = [System.Collections.Generic.List[object]]::new()

    foreach ($entity in @($payload.Entities)) {
        if (-not $entity) { continue }
        $entityId   = if ($entity.PSObject.Properties['EntityId'])   { [string]$entity.EntityId }   else { '' }
        $entityType = if ($entity.PSObject.Properties['EntityType']) { $entity.EntityType }          else { $null }
        $platform   = if ($entity.PSObject.Properties['Platform'])   { $entity.Platform }            else { $null }
        if (-not $entityId) { continue }

        $added.Add([pscustomobject]@{
            ChangeKind   = 'Added'
            EntityId     = $entityId
            EntityType   = $entityType
            Platform     = $platform
            Severity     = 'Info'
            Previous     = $null
            Current      = $entity
            ChangedPaths = @()
        }) | Out-Null
    }

    return [ordered]@{
        Added     = @($added)
        Removed   = @()
        Modified  = @()
        Unchanged = @()
    }
}
