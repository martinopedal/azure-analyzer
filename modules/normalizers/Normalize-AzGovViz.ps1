#Requires -Version 7.4
<#
.SYNOPSIS
    Normalizer for AzGovViz findings.
.DESCRIPTION
    Converts raw AzGovViz wrapper output to v3 FindingRow objects.
    Platform=Azure, EntityType=ManagementGroup or AzureResource depending on the finding.
#>
[CmdletBinding()]
param ()

. "$PSScriptRoot\..\shared\Schema.ps1"
. "$PSScriptRoot\..\shared\Canonicalize.ps1"

function Get-PropertyValue {
    param ([object]$Obj, [string]$Name, [object]$Default = '')
    if ($null -eq $Obj) { return $Default }
    $p = $Obj.PSObject.Properties[$Name]
    if ($null -eq $p -or $null -eq $p.Value) { return $Default }
    return $p.Value
}

function Get-StringArrayValue {
    param ([object]$Obj, [string]$Name)
    $value = Get-PropertyValue -Obj $Obj -Name $Name -Default @()
    if ($null -eq $value) { return @() }
    if ($value -is [System.Array]) {
        return @($value | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    }
    if ($value -is [string]) {
        if ([string]::IsNullOrWhiteSpace($value)) { return @() }
        return @($value -split '[,;|]' | ForEach-Object { $_.Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    }
    return @([string]$value)
}

function Get-HashtableArrayValue {
    param ([object]$Obj, [string]$Name)
    $value = Get-PropertyValue -Obj $Obj -Name $Name -Default @()
    if ($null -eq $value) { return @() }
    $items = [System.Collections.Generic.List[hashtable]]::new()
    foreach ($entry in @($value)) {
        if ($null -eq $entry) { continue }
        if ($entry -is [System.Collections.IDictionary]) {
            $map = @{}
            foreach ($key in $entry.Keys) {
                $map[[string]$key] = $entry[$key]
            }
            $items.Add($map) | Out-Null
            continue
        }

        if ($entry.PSObject) {
            $map = @{}
            foreach ($prop in @($entry.PSObject.Properties)) {
                $map[$prop.Name] = $prop.Value
            }
            if ($map.Count -gt 0) {
                $items.Add($map) | Out-Null
                continue
            }
        }

        $text = [string]$entry
        if (-not [string]::IsNullOrWhiteSpace($text)) {
            $items.Add(@{
                    language = 'text'
                    code     = $text.Trim()
                }) | Out-Null
        }
    }
    return @($items)
}

function Convert-ToRemediationSnippets {
    param ([string]$Remediation)

    if ([string]::IsNullOrWhiteSpace($Remediation)) { return @() }
    return @(
        @{
            language = 'text'
            code     = $Remediation.Trim()
        }
    )
}

function Get-AzGovVizPillar {
    param ([string]$Category, [string]$Title)

    $normalizedCategory = ($Category ?? '').Trim().ToLowerInvariant()
    $normalizedTitle = ($Title ?? '').Trim().ToLowerInvariant()
    if ($normalizedCategory -match '^(policy|identity)$') { return 'Security' }
    if ($normalizedCategory -match '^(cost|costoptimization|finops)$') { return 'Cost' }
    if ($normalizedTitle -match 'orphaned') { return 'Cost' }
    return 'Operational Excellence'
}

function Get-AzGovVizImpact {
    param (
        [string]$Severity,
        [string]$Category
    )

    switch -Regex (($Severity ?? '').Trim().ToLowerInvariant()) {
        'critical|high' { return 'High' }
        'medium' { return 'Medium' }
        'low|info' { return 'Low' }
    }

    switch -Regex (($Category ?? '').Trim().ToLowerInvariant()) {
        '^(policy|identity)$' { return 'High' }
        '^(cost|costoptimization|finops)$' { return 'Medium' }
        default { return 'Medium' }
    }
}

function Get-AzGovVizEffort {
    param ([string]$Category)

    switch -Regex (($Category ?? '').Trim().ToLowerInvariant()) {
        '^identity$' { return 'High' }
        '^(policy|operations)$' { return 'Medium' }
        default { return 'Low' }
    }
}

function Resolve-AzGovVizEntity {
    param ([psobject]$Finding)

    $rawId = Get-PropertyValue $Finding 'ResourceId' ''
    $scope = Get-PropertyValue $Finding 'Scope' ''
    $category = Get-PropertyValue $Finding 'Category' 'Governance'
    $principalId = Get-PropertyValue $Finding 'PrincipalId' ''
    $principalType = Get-PropertyValue $Finding 'PrincipalType' ''
    $managementGroupResourceId = Get-PropertyValue $Finding 'ManagementGroupResourceId' ''
    $managementGroupId = Get-PropertyValue $Finding 'ManagementGroupId' ''
    $tenantId = Get-PropertyValue $Finding 'TenantId' ''
    $subId = ''
    $rg = ''
    $canonicalId = ''
    $entityType = 'ManagementGroup'
    $platformOverride = $null

    if ($category -eq 'Identity' -and $principalId) {
        $principalTypeValue = $principalType.ToLowerInvariant()
        $prefixedId = if ($principalId -match '^(objectId|appId):') { $principalId } else { "objectId:$principalId" }
        if ($principalTypeValue -match 'user') {
            $entityType = 'User'
            $canonicalId = (ConvertTo-CanonicalEntityId -RawId $prefixedId -EntityType 'User').CanonicalId
        } else {
            $entityType = 'ServicePrincipal'
            $canonicalId = (ConvertTo-CanonicalEntityId -RawId $prefixedId -EntityType 'ServicePrincipal').CanonicalId
        }
        $platformOverride = 'Azure'
    }

    if ($rawId -match '/subscriptions/([^/]+)') { $subId = $Matches[1] }
    if ($scope -match '/subscriptions/([^/]+)') { $subId = $Matches[1] }
    if ($rawId -match '/resourceGroups/([^/]+)') { $rg = $Matches[1] }

    if (-not $canonicalId) {
        $candidate = @($rawId, $scope, $managementGroupResourceId) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -First 1
        if ($candidate -and $candidate -match '^/providers/microsoft\.management/managementgroups/') {
            $entityType = 'ManagementGroup'
            $canonicalId = $candidate.ToLowerInvariant()
        } elseif ($candidate -and $candidate -match '^/subscriptions/[^/]+$') {
            $entityType = 'Subscription'
            if ($candidate -match '/subscriptions/([^/]+)') {
                $canonicalId = (ConvertTo-CanonicalEntityId -RawId $Matches[1] -EntityType 'Subscription').CanonicalId
            }
        } elseif ($candidate -and $candidate -match '^/subscriptions/') {
            $entityType = 'AzureResource'
            try {
                $canonicalId = (ConvertTo-CanonicalEntityId -RawId $candidate -EntityType 'AzureResource').CanonicalId
            } catch {
                $canonicalId = $candidate.ToLowerInvariant()
            }
        } elseif ($tenantId) {
            $entityType = 'Tenant'
            $canonicalId = (ConvertTo-CanonicalEntityId -RawId $tenantId -EntityType 'Tenant').CanonicalId
        } elseif ($managementGroupId) {
            $entityType = 'ManagementGroup'
            $canonicalId = "/providers/microsoft.management/managementgroups/$($managementGroupId.ToLowerInvariant())"
        } else {
            $entityType = 'ManagementGroup'
            $cat  = Get-PropertyValue $Finding 'Category' 'unknown'
            $ttl  = Get-PropertyValue $Finding 'Title' (Get-PropertyValue $Finding 'Description' 'unknown')
            $stableKey = "$cat/$ttl".ToLowerInvariant() -replace '[^a-z0-9/]', '-'
            $canonicalId = "azgovviz/$stableKey"
        }
    }

    return [pscustomobject]@{
        EntityType             = $entityType
        CanonicalId            = $canonicalId
        SubscriptionId         = $subId
        ResourceGroup          = $rg
        PlatformOverride       = $platformOverride
        ManagementGroupId      = $managementGroupId
        ManagementGroupResId   = $managementGroupResourceId
        TenantId               = $tenantId
    }
}

function Get-AzGovVizEntityRefs {
    param (
        [psobject]$Finding,
        [psobject]$EntityResolution
    )

    $refs = [System.Collections.Generic.List[string]]::new()
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $entityType = $EntityResolution.EntityType
    $entityId = $EntityResolution.CanonicalId

    function Add-Ref {
        param ([string]$RefId, [string]$RefType)
        if ([string]::IsNullOrWhiteSpace($RefId)) { return }
        try {
            $canonical = (ConvertTo-CanonicalEntityId -RawId $RefId -EntityType $RefType).CanonicalId
            if ($canonical -and $canonical -ne $entityId -and $seen.Add($canonical)) {
                $refs.Add($canonical)
            }
        } catch {
            return
        }
    }

    $subId = $EntityResolution.SubscriptionId
    if ($subId -and $entityType -ne 'Subscription') {
        Add-Ref -RefId $subId -RefType 'Subscription'
    }

    $mgRef = if ($EntityResolution.ManagementGroupResId) {
        $EntityResolution.ManagementGroupResId
    } elseif ($EntityResolution.ManagementGroupId) {
        "/providers/Microsoft.Management/managementGroups/$($EntityResolution.ManagementGroupId)"
    } else {
        ''
    }
    if ($mgRef -and $entityType -ne 'ManagementGroup') {
        Add-Ref -RefId $mgRef -RefType 'ManagementGroup'
    }

    $mgPath = Get-StringArrayValue -Obj $Finding -Name 'ManagementGroupPath'
    foreach ($mg in $mgPath) {
        $mgRefId = if ($mg -match '^/providers/microsoft\.management/managementgroups/') { $mg } else { "/providers/Microsoft.Management/managementGroups/$mg" }
        if ($entityType -ne 'ManagementGroup') {
            Add-Ref -RefId $mgRefId -RefType 'ManagementGroup'
        }
    }

    $parentMgId = Get-PropertyValue -Obj $Finding -Name 'ParentManagementGroupId' -Default ''
    if ($parentMgId) {
        Add-Ref -RefId "/providers/Microsoft.Management/managementGroups/$parentMgId" -RefType 'ManagementGroup'
    }

    if ($EntityResolution.TenantId -and $entityType -ne 'Tenant') {
        Add-Ref -RefId $EntityResolution.TenantId -RefType 'Tenant'
    }

    return @($refs)
}

function Normalize-AzGovViz {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [PSCustomObject] $ToolResult
    )

    if ($ToolResult.Status -ne 'Success' -or -not $ToolResult.Findings) {
        return @()
    }

    $runId = [guid]::NewGuid().ToString()
    $normalized = [System.Collections.Generic.List[PSCustomObject]]::new()

    foreach ($finding in $ToolResult.Findings) {
        $rawId = Get-PropertyValue $finding 'ResourceId' ''
        $category = Get-PropertyValue $finding 'Category' 'Governance'
        $entityResolution = Resolve-AzGovVizEntity -Finding $finding
        $title = Get-PropertyValue $finding 'Title' (Get-PropertyValue $finding 'Description' 'Unknown')

        $rawSev = Get-PropertyValue $finding 'Severity' 'Info'
        $severity = switch -Regex ($rawSev.ToString().ToLowerInvariant()) {
            'critical'         { 'Critical' }
            'high'             { 'High' }
            'medium|moderate'  { 'Medium' }
            'low'              { 'Low' }
            'info'             { 'Info' }
            default            { 'Medium' }
        }

        # Determine compliance
        $compliantProp = $finding.PSObject.Properties['Compliant']
        $compliant = if ($null -eq $compliantProp) { $true } else { $compliantProp.Value -ne $false }

        $detail = Get-PropertyValue $finding 'Detail' ''
        $remediation = Get-PropertyValue $finding 'Remediation' ''
        $learnMore = Get-PropertyValue $finding 'LearnMoreUrl' (Get-PropertyValue $finding 'LearnMoreLink' '')
        $pillar = Get-PropertyValue $finding 'Pillar' ''
        if (-not $pillar) {
            $pillar = Get-AzGovVizPillar -Category $category -Title $title
        }
        $frameworks = Get-PropertyValue $finding 'Frameworks' @()
        $baselineTags = Get-StringArrayValue -Obj $finding -Name 'BaselineTags'
        $evidenceUris = Get-StringArrayValue -Obj $finding -Name 'EvidenceUris'
        $impact = [string](Get-PropertyValue $finding 'Impact' '')
        if (-not $impact) {
            $impact = Get-AzGovVizImpact -Severity $severity -Category $category
        }
        $effort = [string](Get-PropertyValue $finding 'Effort' '')
        if (-not $effort) {
            $effort = Get-AzGovVizEffort -Category $category
        }
        $remediationSnippets = @(Get-HashtableArrayValue -Obj $finding -Name 'RemediationSnippets')
        if (@($remediationSnippets).Count -eq 0) {
            $remediationSnippets = @(Convert-ToRemediationSnippets -Remediation $remediation)
        }
        $scoreDelta = $null
        $rawScoreDelta = Get-PropertyValue $finding 'ScoreDelta' $null
        if ($null -ne $rawScoreDelta -and -not [string]::IsNullOrWhiteSpace([string]$rawScoreDelta)) {
            $parsedScore = 0.0
            if ([double]::TryParse(
                    [string]$rawScoreDelta,
                    [System.Globalization.NumberStyles]::Any,
                    [System.Globalization.CultureInfo]::InvariantCulture,
                    [ref]$parsedScore
                )) {
                $scoreDelta = $parsedScore
            }
        }
        $mitreTactics = Get-StringArrayValue -Obj $finding -Name 'MitreTactics'
        if (@($mitreTactics).Count -eq 0) {
            $mitreTactics = Get-StringArrayValue -Obj $finding -Name 'Tactics'
        }
        $mitreTechniques = Get-StringArrayValue -Obj $finding -Name 'MitreTechniques'
        if (@($mitreTechniques).Count -eq 0) {
            $mitreTechniques = Get-StringArrayValue -Obj $finding -Name 'Techniques'
        }
        $entityRefs = Get-AzGovVizEntityRefs -Finding $finding -EntityResolution $entityResolution
        $toolVersion = Get-PropertyValue $finding 'ToolVersion' ''
        $deepLinkUrl = Get-PropertyValue $finding 'DeepLinkUrl' ''
        $mgPath = Get-StringArrayValue -Obj $finding -Name 'ManagementGroupPath'

        $newFindingParams = @{
            Id              = ([guid]::NewGuid().ToString())
            Source          = 'azgovviz'
            EntityId        = $entityResolution.CanonicalId
            EntityType      = $entityResolution.EntityType
            Title           = $title
            Compliant       = [bool]$compliant
            ProvenanceRunId = $runId
            Category        = $category
            Severity        = $severity
            Detail          = $detail
            Remediation     = $remediation
            LearnMoreUrl    = ($learnMore ?? '')
            ResourceId      = ($rawId ?? '')
            SubscriptionId  = $entityResolution.SubscriptionId
            ResourceGroup   = $entityResolution.ResourceGroup
            ManagementGroupPath = $mgPath
             Frameworks      = $frameworks
             Pillar          = $pillar
             Impact          = $impact
             Effort          = $effort
             DeepLinkUrl     = $deepLinkUrl
             RemediationSnippets = $remediationSnippets
             EvidenceUris    = $evidenceUris
             BaselineTags    = $baselineTags
             ScoreDelta      = $scoreDelta
             MitreTactics    = $mitreTactics
             MitreTechniques = $mitreTechniques
             EntityRefs      = $entityRefs
             ToolVersion     = $toolVersion
        }
        if ($entityResolution.PlatformOverride) {
            $newFindingParams.Platform = $entityResolution.PlatformOverride
        }

        $row = New-FindingRow @newFindingParams
        # Skip null rows (validation failed)
        if ($null -ne $row) {
            $normalized.Add($row)
        }
    }

    return @($normalized)
}
