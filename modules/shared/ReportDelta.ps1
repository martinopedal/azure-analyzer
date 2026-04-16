#Requires -Version 7.4
[CmdletBinding()]
param ()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-FindingCompositeKey {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [pscustomobject] $Finding
    )

    $source = [string]$Finding.Source
    $resourceId = [string]$Finding.ResourceId
    $category = [string]$Finding.Category
    $title = [string]$Finding.Title

    return ('{0}|{1}|{2}|{3}' -f $source.Trim().ToLowerInvariant(), $resourceId.Trim().ToLowerInvariant(), $category.Trim().ToLowerInvariant(), $title.Trim().ToLowerInvariant())
}

function Get-FindingDelta {
    [CmdletBinding()]
    param (
        [object[]] $CurrentFindings,
        [object[]] $PreviousFindings
    )

    $current = @($CurrentFindings)
    $previous = @($PreviousFindings)

    $currentKeySet = [System.Collections.Generic.HashSet[string]]::new()
    $previousKeySet = [System.Collections.Generic.HashSet[string]]::new()

    foreach ($f in $current) {
        if ($null -eq $f) { continue }
        $null = $currentKeySet.Add((Get-FindingCompositeKey -Finding $f))
    }

    foreach ($f in $previous) {
        if ($null -eq $f) { continue }
        $null = $previousKeySet.Add((Get-FindingCompositeKey -Finding $f))
    }

    $annotatedCurrent = foreach ($f in $current) {
        if ($null -eq $f) { continue }
        $key = Get-FindingCompositeKey -Finding $f
        $status = if ($previousKeySet.Contains($key)) { 'Unchanged' } else { 'New' }
        $severity = if ($f.PSObject.Properties['Severity']) { $f.Severity } else { 'Info' }
        $detail = if ($f.PSObject.Properties['Detail']) { $f.Detail } else { '' }
        $remediation = if ($f.PSObject.Properties['Remediation']) { $f.Remediation } else { '' }
        $learnMoreUrl = if ($f.PSObject.Properties['LearnMoreUrl']) { $f.LearnMoreUrl } else { '' }
        $frameworks = if ($f.PSObject.Properties['Frameworks']) { $f.Frameworks } else { @() }
        [PSCustomObject]@{
            Id           = $f.Id
            Source       = $f.Source
            Category     = $f.Category
            Title        = $f.Title
            Severity     = $severity
            Compliant    = [bool]$f.Compliant
            Detail       = $detail
            Remediation  = $remediation
            ResourceId   = $f.ResourceId
            LearnMoreUrl = $learnMoreUrl
            Frameworks   = $frameworks
            DeltaStatus  = $status
        }
    }

    $newCount = @($annotatedCurrent | Where-Object { $_.DeltaStatus -eq 'New' }).Count
    $unchangedCount = @($annotatedCurrent | Where-Object { $_.DeltaStatus -eq 'Unchanged' }).Count

    $resolvedFindings = [System.Collections.Generic.List[pscustomobject]]::new()
    foreach ($f in $previous) {
        if ($null -eq $f) { continue }
        $key = Get-FindingCompositeKey -Finding $f
        if ($currentKeySet.Contains($key)) { continue }

        $severity = if ($f.PSObject.Properties['Severity']) { $f.Severity } else { 'Info' }
        $detail = if ($f.PSObject.Properties['Detail']) { $f.Detail } else { '' }
        $remediation = if ($f.PSObject.Properties['Remediation']) { $f.Remediation } else { '' }
        $learnMoreUrl = if ($f.PSObject.Properties['LearnMoreUrl']) { $f.LearnMoreUrl } else { '' }
        $frameworks = if ($f.PSObject.Properties['Frameworks']) { $f.Frameworks } else { @() }

        $resolvedFindings.Add([PSCustomObject]@{
            Id           = $f.Id
            Source       = $f.Source
            Category     = $f.Category
            Title        = $f.Title
            Severity     = $severity
            Compliant    = [bool]$f.Compliant
            Detail       = $detail
            Remediation  = $remediation
            ResourceId   = $f.ResourceId
            LearnMoreUrl = $learnMoreUrl
            Frameworks   = $frameworks
            DeltaStatus  = 'Resolved'
        })
    }
    $resolvedCount = $resolvedFindings.Count

    $currentNonCompliant = @($annotatedCurrent | Where-Object { -not $_.Compliant }).Count
    $previousNonCompliant = @($previous | Where-Object { -not [bool]$_.Compliant }).Count

    [PSCustomObject]@{
        CurrentFindings          = @($annotatedCurrent)
        ResolvedFindings         = @($resolvedFindings)
        NewCount                 = $newCount
        ResolvedCount            = $resolvedCount
        UnchangedCount           = $unchangedCount
        CurrentNonCompliantCount = $currentNonCompliant
        PreviousNonCompliantCount = $previousNonCompliant
        NetNonCompliantChange    = ($currentNonCompliant - $previousNonCompliant)
    }
}
