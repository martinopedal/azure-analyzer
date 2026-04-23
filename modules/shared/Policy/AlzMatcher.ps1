# AlzMatcher.ps1
# Track C scaffold (#431). Stub only. See docs/design/alz-scoring-algorithm.md.
# Pure function: deterministic fuzzy-match of a tenant MG hierarchy against the
# ALZ canonical reference. Returns score plus four component scores for auditability.

Set-StrictMode -Version Latest

$script:AlzWeights = @{
    exactName   = 0.40
    structural  = 0.30
    renames     = 0.20
    levenshtein = 0.10
}

$script:AlzCanonicalNodes = @(
    [pscustomobject]@{ Name = 'Root';          Depth = 0; ChildCount = 4 }
    [pscustomobject]@{ Name = 'Platform';      Depth = 1; ChildCount = 3 }
    [pscustomobject]@{ Name = 'Management';    Depth = 2; ChildCount = 0 }
    [pscustomobject]@{ Name = 'Connectivity';  Depth = 2; ChildCount = 0 }
    [pscustomobject]@{ Name = 'Identity';      Depth = 2; ChildCount = 0 }
    [pscustomobject]@{ Name = 'Landing Zones'; Depth = 1; ChildCount = 2 }
    [pscustomobject]@{ Name = 'Corp';          Depth = 2; ChildCount = 0 }
    [pscustomobject]@{ Name = 'Online';        Depth = 2; ChildCount = 0 }
    [pscustomobject]@{ Name = 'Decommissioned';Depth = 1; ChildCount = 0 }
    [pscustomobject]@{ Name = 'Sandbox';       Depth = 1; ChildCount = 0 }
)

$script:AlzRenameTable = @{
    'Platform'      = @('Core', 'Shared Services', 'SharedServices', 'Shared', 'Hub')
    'Landing Zones' = @('Workloads', 'Application', 'Applications', 'LZ', 'LandingZones')
    'Corp'          = @('Internal', 'Private', 'Enterprise')
    'Online'        = @('External', 'Public', 'Internet')
    'Decommissioned'= @('Decom', 'Retired', 'Archive')
    'Sandbox'       = @('Dev', 'Development', 'NonProd', 'Playground')
    'Connectivity'  = @('Network', 'Networking', 'Hub-Network', 'HubNetwork')
    'Identity'      = @('IAM', 'AAD', 'Entra')
    'Management'    = @('Mgmt', 'Operations', 'Ops', 'Monitoring')
}

function ConvertTo-AlzToken {
    param([string] $Name)
    if ([string]::IsNullOrWhiteSpace($Name)) { return '' }
    return (($Name.Trim().ToLowerInvariant() -replace '\s+', '') -replace '[-_]', '')
}

function Get-AlzTenantNodes {
    param(
        [Parameter(Mandatory)] [object] $TenantHierarchy,
        [int] $Depth = 0
    )

    $nodes = [System.Collections.Generic.List[object]]::new()
    foreach ($item in @($TenantHierarchy)) {
        if ($null -eq $item) { continue }
        $name = $null
        foreach ($nameProp in 'Name', 'name', 'DisplayName', 'displayName') {
            if ($item.PSObject.Properties[$nameProp]) {
                $name = [string]$item.$nameProp
                break
            }
        }

        $children = @()
        foreach ($childProp in 'Children', 'children', 'ManagementGroups', 'managementGroups', 'Nodes', 'nodes') {
            if ($item.PSObject.Properties[$childProp] -and $null -ne $item.$childProp) {
                $children = @($item.$childProp)
                break
            }
        }

        if (-not [string]::IsNullOrWhiteSpace($name)) {
            $nodes.Add([pscustomobject]@{
                Name       = $name
                Token      = ConvertTo-AlzToken $name
                Depth      = $Depth
                ChildCount = @($children).Count
            }) | Out-Null
        }

        if (@($children).Count -gt 0) {
            foreach ($child in @(Get-AlzTenantNodes -TenantHierarchy $children -Depth ($Depth + 1))) {
                $nodes.Add($child) | Out-Null
            }
        }
    }

    return @($nodes)
}

function Get-LevenshteinDistance {
    param(
        [string] $Left,
        [string] $Right
    )
    if ($Left -eq $Right) { return 0 }
    if ([string]::IsNullOrEmpty($Left)) { return $Right.Length }
    if ([string]::IsNullOrEmpty($Right)) { return $Left.Length }

    $n = $Left.Length
    $m = $Right.Length
    $distance = New-Object 'int[,]' ($n + 1), ($m + 1)
    for ($i = 0; $i -le $n; $i++) { $distance[$i, 0] = $i }
    for ($j = 0; $j -le $m; $j++) { $distance[0, $j] = $j }
    for ($i = 1; $i -le $n; $i++) {
        for ($j = 1; $j -le $m; $j++) {
            $cost = if ($Left[($i - 1)] -ceq $Right[($j - 1)]) { 0 } else { 1 }
            $distance[$i, $j] = [Math]::Min(
                [Math]::Min($distance[($i - 1), $j] + 1, $distance[$i, ($j - 1)] + 1),
                $distance[($i - 1), ($j - 1)] + $cost
            )
        }
    }
    return $distance[$n, $m]
}

function Get-AlzMatchBreakdown {
    param([Parameter(Mandatory)] [object] $TenantHierarchy)

    $tenantNodes = @(Get-AlzTenantNodes -TenantHierarchy $TenantHierarchy)
    $canonicalCount = @($script:AlzCanonicalNodes).Count
    if ($canonicalCount -eq 0) {
        throw 'ALZ canonical hierarchy is empty.'
    }

    $exactMatches = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $renameMatches = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $levMatches = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $matchedHierarchy = [System.Collections.Generic.List[object]]::new()

    $rootAliases = @('TenantRoot', 'Tenant Root Group')

    foreach ($canonical in $script:AlzCanonicalNodes) {
        $canonicalToken = ConvertTo-AlzToken $canonical.Name
        $match = $tenantNodes | Where-Object {
            $_.Depth -eq $canonical.Depth -and (
                $_.Token -eq $canonicalToken -or
                ($canonical.Name -eq 'Root' -and (ConvertTo-AlzToken $_.Name) -in @($rootAliases | ForEach-Object { ConvertTo-AlzToken $_ }))
            )
        } | Select-Object -First 1
        if ($match) {
            $exactMatches[$canonical.Name] = $match
            $matchedHierarchy.Add([pscustomobject]@{
                tenantNode = $match.Name
                canonical  = $canonical.Name
                matchType  = 'exact'
            }) | Out-Null
        }
    }

    foreach ($canonical in $script:AlzCanonicalNodes) {
        if ($exactMatches.ContainsKey($canonical.Name)) { continue }
        $candidateRenames = @($script:AlzRenameTable[$canonical.Name] | ForEach-Object { ConvertTo-AlzToken $_ })
        if (@($candidateRenames).Count -eq 0) { continue }
        $match = $tenantNodes | Where-Object {
            $_.Depth -eq $canonical.Depth -and $_.Token -in $candidateRenames
        } | Select-Object -First 1
        if ($match) {
            $renameMatches[$canonical.Name] = $match
            $matchedHierarchy.Add([pscustomobject]@{
                tenantNode = $match.Name
                canonical  = $canonical.Name
                matchType  = 'rename'
            }) | Out-Null
        }
    }

    foreach ($canonical in $script:AlzCanonicalNodes) {
        if ($exactMatches.ContainsKey($canonical.Name) -or $renameMatches.ContainsKey($canonical.Name)) { continue }
        $canonicalToken = ConvertTo-AlzToken $canonical.Name
        $match = $tenantNodes | Where-Object {
            $_.Depth -eq $canonical.Depth -and (Get-LevenshteinDistance -Left $_.Token -Right $canonicalToken) -le 2
        } | Sort-Object { Get-LevenshteinDistance -Left $_.Token -Right $canonicalToken }, Name | Select-Object -First 1
        if ($match) {
            $levMatches[$canonical.Name] = $match
            $matchedHierarchy.Add([pscustomobject]@{
                tenantNode = $match.Name
                canonical  = $canonical.Name
                matchType  = 'levenshtein'
            }) | Out-Null
        }
    }

    $exactScore = [double]$exactMatches.Count / [double]$canonicalCount
    $renameCandidates = @($script:AlzCanonicalNodes | Where-Object { -not $exactMatches.ContainsKey($_.Name) }).Count
    $renamesScore = if ($renameCandidates -eq 0) { 1.0 } else { [double]$renameMatches.Count / [double]$renameCandidates }
    $remainingAfterRename = @($script:AlzCanonicalNodes | Where-Object { -not $exactMatches.ContainsKey($_.Name) -and -not $renameMatches.ContainsKey($_.Name) }).Count
    $levenshteinScore = if ($remainingAfterRename -eq 0) { 1.0 } else { [double]$levMatches.Count / [double]$remainingAfterRename }

    $depthCorrectCount = 0
    foreach ($canonical in $script:AlzCanonicalNodes) {
        $matchedNode = $null
        if ($exactMatches.ContainsKey($canonical.Name)) { $matchedNode = $exactMatches[$canonical.Name] }
        if (-not $matchedNode -and $renameMatches.ContainsKey($canonical.Name)) { $matchedNode = $renameMatches[$canonical.Name] }
        if (-not $matchedNode -and $levMatches.ContainsKey($canonical.Name)) { $matchedNode = $levMatches[$canonical.Name] }
        if ($matchedNode -and $matchedNode.Depth -eq $canonical.Depth) {
            $depthCorrectCount++
        }
    }
    $depthCorrectFraction = [double]$depthCorrectCount / [double]$canonicalCount

    $nonLeaf = @($script:AlzCanonicalNodes | Where-Object { $_.ChildCount -gt 0 })
    $childMatches = 0
    foreach ($canonical in $nonLeaf) {
        $matchedNode = $null
        if ($exactMatches.ContainsKey($canonical.Name)) { $matchedNode = $exactMatches[$canonical.Name] }
        if (-not $matchedNode -and $renameMatches.ContainsKey($canonical.Name)) { $matchedNode = $renameMatches[$canonical.Name] }
        if (-not $matchedNode -and $levMatches.ContainsKey($canonical.Name)) { $matchedNode = $levMatches[$canonical.Name] }
        if ($matchedNode -and [Math]::Abs([int]$matchedNode.ChildCount - [int]$canonical.ChildCount) -le 1) {
            $childMatches++
        }
    }
    $childCountFraction = if (@($nonLeaf).Count -eq 0) { 1.0 } else { [double]$childMatches / [double]@($nonLeaf).Count }
    $structuralScore = ($depthCorrectFraction + $childCountFraction) / 2.0

    return [pscustomobject]@{
        ExactScore       = [Math]::Round($exactScore, 4)
        StructuralScore  = [Math]::Round($structuralScore, 4)
        RenamesScore     = [Math]::Round($renamesScore, 4)
        LevenshteinScore = [Math]::Round($levenshteinScore, 4)
        MatchedHierarchy = @($matchedHierarchy)
    }
}

function Get-AlzMatchScore {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [double] $ExactName,
        [Parameter(Mandatory)] [double] $Structural,
        [Parameter(Mandatory)] [double] $Renames,
        [Parameter(Mandatory)] [double] $Levenshtein
    )

    $score = ($script:AlzWeights.exactName * $ExactName) +
        ($script:AlzWeights.structural * $Structural) +
        ($script:AlzWeights.renames * $Renames) +
        ($script:AlzWeights.levenshtein * $Levenshtein)
    return [Math]::Round($score, 4)
}

function Invoke-AlzHierarchyMatch {
    <#
    .SYNOPSIS
        Score how closely a tenant MG hierarchy matches the ALZ canonical reference.
    .DESCRIPTION
        Implements the weighted formula:
            score = 0.40 * exactName
                  + 0.30 * structural
                  + 0.20 * renames
                  + 0.10 * levenshtein
        See docs/design/alz-scoring-algorithm.md for the full specification.
    .PARAMETER TenantHierarchy
        Tenant MG hierarchy as a tree of nodes (Name, Depth, Children).
    .PARAMETER Mode
        Auto | Force | Off. Default Auto.
    .OUTPUTS
        PSCustomObject with Score, Components, MatchedHierarchy, Mode.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object] $TenantHierarchy,
        [ValidateSet('Auto','Force','Off')] [string] $Mode = 'Auto'
    )
    if ($Mode -eq 'Off') {
        return [pscustomobject]@{
            Mode            = 'Off'
            Score           = $null
            Components      = $null
            Weighted        = $null
            MatchedHierarchy= @()
            Decision        = 'Off'
        }
    }

    $breakdown = Get-AlzMatchBreakdown -TenantHierarchy $TenantHierarchy
    $score = Get-AlzMatchScore `
        -ExactName $breakdown.ExactScore `
        -Structural $breakdown.StructuralScore `
        -Renames $breakdown.RenamesScore `
        -Levenshtein $breakdown.LevenshteinScore
    $decision = Get-AlzActivationDecision -Score $score -Mode $Mode

    return [pscustomobject]@{
        Mode             = $Mode
        Score            = $score
        Components       = [pscustomobject]@{
            exactName   = $breakdown.ExactScore
            structural  = $breakdown.StructuralScore
            renames     = $breakdown.RenamesScore
            levenshtein = $breakdown.LevenshteinScore
        }
        Weighted         = [pscustomobject]@{
            exactName   = [Math]::Round($script:AlzWeights.exactName * $breakdown.ExactScore, 4)
            structural  = [Math]::Round($script:AlzWeights.structural * $breakdown.StructuralScore, 4)
            renames     = [Math]::Round($script:AlzWeights.renames * $breakdown.RenamesScore, 4)
            levenshtein = [Math]::Round($script:AlzWeights.levenshtein * $breakdown.LevenshteinScore, 4)
        }
        MatchedHierarchy = @($breakdown.MatchedHierarchy)
        Decision         = $decision
        ForceOverridden  = ($Mode -eq 'Force' -and $score -lt 0.80)
    }
}

function Get-AlzExactNameComponent {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [object] $TenantHierarchy)
    return (Get-AlzMatchBreakdown -TenantHierarchy $TenantHierarchy).ExactScore
}

function Get-AlzStructuralComponent {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [object] $TenantHierarchy)
    return (Get-AlzMatchBreakdown -TenantHierarchy $TenantHierarchy).StructuralScore
}

function Get-AlzRenamesComponent {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [object] $TenantHierarchy)
    return (Get-AlzMatchBreakdown -TenantHierarchy $TenantHierarchy).RenamesScore
}

function Get-AlzLevenshteinComponent {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [object] $TenantHierarchy)
    return (Get-AlzMatchBreakdown -TenantHierarchy $TenantHierarchy).LevenshteinScore
}

function Get-AlzActivationDecision {
    <#
    .SYNOPSIS
        Apply threshold semantics to a score: Full | Partial | Fallback.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [double] $Score,
        [ValidateSet('Auto','Force','Off')] [string] $Mode = 'Auto'
    )
    if ($Mode -eq 'Off') { return 'Off' }
    if ($Mode -eq 'Force') { return 'Full' }
    if ($Score -ge 0.80) { return 'Full' }
    if ($Score -ge 0.50) { return 'Partial' }
    return 'Fallback'
}

if ($MyInvocation.MyCommand.Module) {
    Export-ModuleMember -Function `
        Invoke-AlzHierarchyMatch, `
        Get-AlzMatchScore, `
        Get-AlzExactNameComponent, `
        Get-AlzStructuralComponent, `
        Get-AlzRenamesComponent, `
        Get-AlzLevenshteinComponent, `
        Get-AlzActivationDecision
}
