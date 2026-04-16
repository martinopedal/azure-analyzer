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
