#Requires -Version 7.4
<#
.SYNOPSIS
    Canonicalization helpers for schema v2 entity IDs.
.DESCRIPTION
    Normalizes identifiers for Azure, GitHub, ADO, and Entra entities.
#>
[CmdletBinding()]
param ()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:GuidPattern = '^[0-9a-f]{8}-([0-9a-f]{4}-){3}[0-9a-f]{12}$'

function ConvertTo-CanonicalArmId {
    <#
    .SYNOPSIS
        Canonicalize an ARM resource ID.
    .PARAMETER ArmId
        Raw ARM resource identifier.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $ArmId
    )

    $normalized = $ArmId.Trim() -replace '\\', '/'
    $normalized = $normalized.TrimEnd('/')
    $normalized = $normalized.ToLowerInvariant()

    if ($normalized -notmatch '^/subscriptions/[0-9a-f]{8}-([0-9a-f]{4}-){3}[0-9a-f]{12}(/|$)') {
        throw "ARM ID must start with /subscriptions/{guid}. Provided: '$ArmId'."
    }

    return $normalized
}

function ConvertTo-CanonicalRepoId {
    <#
    .SYNOPSIS
        Canonicalize a GitHub repository identifier.
    .PARAMETER RepoId
        Raw repository identifier.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $RepoId
    )

    $normalized = $RepoId.Trim()

    if ($normalized -match '^(?i)ado://') {
        return ConvertTo-CanonicalAdoId -AdoId $normalized
    }

    if ($normalized -match '^https?://dev\.azure\.com/([^/]+)/([^/]+)/_git/([^/?#]+)') {
        $org = $matches[1].ToLowerInvariant()
        $project = $matches[2].ToLowerInvariant()
        $repo = $matches[3].ToLowerInvariant()
        return "ado://$org/$project/repository/$repo"
    }

    if ($normalized -match '^https?://([^/]+)\.visualstudio\.com/([^/]+)/_git/([^/?#]+)') {
        $org = $matches[1].ToLowerInvariant()
        $project = $matches[2].ToLowerInvariant()
        $repo = $matches[3].ToLowerInvariant()
        return "ado://$org/$project/repository/$repo"
    }

    $normalized = $normalized -replace '^https?://', ''
    $normalized = $normalized -replace '^ssh://', ''
    $normalized = $normalized -replace '^git@', ''
    $normalized = $normalized -replace '^www\.', ''
    # Normalize git@ SSH syntax for any host (e.g., git@github.contoso.com:org/repo)
    $normalized = $normalized -replace '^([^/:]+):', '$1/'
    $normalized = $normalized.TrimEnd('/')
    $normalized = $normalized -replace '\.git$', ''
    $normalized = $normalized.ToLowerInvariant()

    # Accept github.com or any enterprise host with host/owner/repo format
    if ($normalized -notmatch '^[a-z0-9]([a-z0-9\-\.]*[a-z0-9])?/[^/]+/[^/]+$') {
        throw "Repository ID must be in host/owner/repo format (e.g., github.com/owner/repo). Provided: '$RepoId'."
    }

    return $normalized
}

function ConvertTo-CanonicalAdoId {
    <#
    .SYNOPSIS
        Canonicalize an Azure DevOps identifier.
    .DESCRIPTION
        Normalizes to ado://org/project/type/name.
    .PARAMETER AdoId
        Raw ADO identifier or URL.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $AdoId
    )

    $raw = $AdoId.Trim()
    $org = $null
    $project = $null
    $type = $null
    $name = $null

    if ($raw -match '^ado://') {
        $raw = $raw.Substring(6)
    } elseif ($raw -match '^https?://dev\.azure\.com/([^/]+)/([^/]+)/_build') {
        $org = $matches[1]
        $project = $matches[2]
        $type = 'pipeline'
        if ($raw -match 'definitionId=([0-9]+)') {
            $name = $matches[1]
        }
    } elseif ($raw -match '^https?://([^/]+)\.visualstudio\.com/([^/]+)/_build') {
        $org = $matches[1]
        $project = $matches[2]
        $type = 'pipeline'
        if ($raw -match 'definitionId=([0-9]+)') {
            $name = $matches[1]
        }
    }

    if (-not $org) {
        $raw = $raw.Trim('/')
        $segments = $raw -split '/'
        if ($segments.Count -lt 4) {
            throw "ADO ID must be in org/project/type/name format. Provided: '$AdoId'."
        }
        $org = $segments[0]
        $project = $segments[1]
        $type = $segments[2]
        $name = ($segments[3..($segments.Count - 1)] -join '/')
    }

    if (-not $org -or -not $project -or -not $type -or -not $name) {
        throw "ADO ID must include org, project, type, and name. Provided: '$AdoId'."
    }

    return "ado://$($org.ToLowerInvariant())/$($project.ToLowerInvariant())/$($type.ToLowerInvariant())/$($name.ToLowerInvariant())"
}

function ConvertTo-CanonicalSpnId {
    <#
    .SYNOPSIS
        Canonicalize a service principal identifier.
    .DESCRIPTION
        Always returns an appId:{guid} identifier. Object IDs require a lookup map.
    .PARAMETER SpnId
        Raw service principal identifier (appId:{guid}, objectId:{guid}, or guid).
    .PARAMETER ObjectIdToAppId
        Lookup map from objectId to appId.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $SpnId,

        [hashtable] $ObjectIdToAppId
    )

    $raw = $SpnId.Trim()
    $guid = $null

    if ($raw -match '^(?i:appid):(?<id>[0-9a-f-]{36})$') {
        $guid = $matches['id']
        return "appId:$($guid.ToLowerInvariant())"
    } elseif ($raw -match '^(?i:objectid):(?<id>[0-9a-f-]{36})$') {
        $objectId = $matches['id'].ToLowerInvariant()
        if (-not $ObjectIdToAppId -or -not $ObjectIdToAppId.ContainsKey($objectId)) {
            return "objectId:$objectId"
        }
        $guid = [string]$ObjectIdToAppId[$objectId]
        $guid = $guid.ToLowerInvariant()
        if ($guid -notmatch $script:GuidPattern) {
            throw "Resolved appId '$guid' is not a valid GUID."
        }
        return "appId:$guid"
    } elseif ($raw -match $script:GuidPattern) {
        $guid = $raw
        $guid = $guid.ToLowerInvariant()
        return "appId:$guid"
    } else {
        throw "SPN identifier must be appId:{guid}, objectId:{guid}, or a GUID. Provided: '$SpnId'."
    }
}

function ConvertTo-CanonicalEntityId {
    <#
    .SYNOPSIS
        Derive canonical entity metadata from a raw identifier.
    .PARAMETER RawId
        Raw identifier provided by a tool.
    .PARAMETER EntityType
        Entity type enum.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $RawId,

        [Parameter(Mandatory)]
        [ValidateSet(
            'AzureResource',
            'ServicePrincipal',
            'ManagedIdentity',
            'Application',
            'Repository',
            'Pipeline',
            'VariableGroup',
            'Environment',
            'ServiceConnection',
            'User',
            'Subscription',
            'ManagementGroup',
            'Workflow',
            'Tenant',
            'AdoProject',
            'KarpenterProvisioner'
        )]
        [string] $EntityType,

        [hashtable] $ObjectIdToAppId
    )

    $canonicalId = switch ($EntityType) {
        'AzureResource' { ConvertTo-CanonicalArmId -ArmId $RawId }
        'ManagedIdentity' { ConvertTo-CanonicalArmId -ArmId $RawId }
        'Repository' { ConvertTo-CanonicalRepoId -RepoId $RawId }
        'Workflow' { $RawId.Trim().ToLowerInvariant() -replace '\\', '/' }
        'ServicePrincipal' { ConvertTo-CanonicalSpnId -SpnId $RawId -ObjectIdToAppId $ObjectIdToAppId }
        'Application' { ConvertTo-CanonicalSpnId -SpnId $RawId -ObjectIdToAppId $ObjectIdToAppId }
        'Pipeline' { ConvertTo-CanonicalAdoId -AdoId $RawId }
        'VariableGroup' { ConvertTo-CanonicalAdoId -AdoId $RawId }
        'Environment' { ConvertTo-CanonicalAdoId -AdoId $RawId }
        'ServiceConnection' { ConvertTo-CanonicalAdoId -AdoId $RawId }
        'User' {
            $raw = $RawId.Trim()
            $userId = if ($raw -match '^(?i:objectid):(?<id>[0-9a-f-]{36})$') {
                $matches['id']
            } elseif ($raw -match $script:GuidPattern) {
                $raw
            } else {
                throw "User entity IDs must be objectId:{guid} or a GUID. Provided: '$RawId'."
            }
            "objectId:$($userId.ToLowerInvariant())"
        }
        'Subscription' {
            $raw = $RawId.Trim()
            if ($raw -notmatch $script:GuidPattern) {
                throw "Subscription IDs must be GUIDs. Provided: '$RawId'."
            }
            $raw.ToLowerInvariant()
        }
        'ManagementGroup' { $RawId.Trim().ToLowerInvariant() }
        'AdoProject' {
            # Project-level ADO entity: canonical form ado://{org}/{project}
            $raw = $RawId.Trim()
            if ($raw -match '^ado://') { $raw = $raw.Substring(6) }
            elseif ($raw -match '^https?://dev\.azure\.com/([^/]+)/([^/?#]+)') {
                $raw = "$($matches[1])/$($matches[2])"
            }
            elseif ($raw -match '^https?://([^/]+)\.visualstudio\.com/([^/?#]+)') {
                $raw = "$($matches[1])/$($matches[2])"
            }
            $segments = $raw.Trim('/') -split '/'
            if ($segments.Count -lt 2 -or [string]::IsNullOrWhiteSpace($segments[0]) -or [string]::IsNullOrWhiteSpace($segments[1])) {
                throw "AdoProject IDs must be in org/project format. Provided: '$RawId'."
            }
            "ado://$($segments[0].ToLowerInvariant())/$($segments[1].ToLowerInvariant())"
        }
        'KarpenterProvisioner' { ConvertTo-CanonicalArmId -ArmId $RawId }
        'Tenant' {
            # Accept bare GUID or tenant:{guid} form; fall back to slugified string for synthetic IDs
            $raw = $RawId.Trim()
            if ($raw -match '^(?i:tenant):(?<id>[0-9a-f-]{36})$') {
                "tenant:$($matches['id'].ToLowerInvariant())"
            } elseif ($raw -match $script:GuidPattern) {
                "tenant:$($raw.ToLowerInvariant())"
            } else {
                $raw.ToLowerInvariant() -replace '\s+', '-'
            }
        }
        default { throw "Unsupported EntityType '$EntityType'." }
    }

    $platform = switch ($EntityType) {
        'AzureResource' { 'Azure' }
        'ManagedIdentity' { 'Azure' }
        'Subscription' { 'Azure' }
        'ManagementGroup' { 'Azure' }
        'ServicePrincipal' { 'Entra' }
        'Application' { 'Entra' }
        'User' { 'Entra' }
        'Tenant' { 'Entra' }
        'Repository' {
            if ($canonicalId -match '^ado://') { 'ADO' } else { 'GitHub' }
        }
        'Pipeline' { 'ADO' }
        'VariableGroup' { 'ADO' }
        'Environment' { 'ADO' }
        'ServiceConnection' { 'ADO' }
        'AdoProject' { 'ADO' }
        'KarpenterProvisioner' { 'Azure' }
        default { 'Unknown' }
    }

    return [PSCustomObject]@{
        Platform    = $platform
        EntityType  = $EntityType
        CanonicalId = $canonicalId
    }
}
