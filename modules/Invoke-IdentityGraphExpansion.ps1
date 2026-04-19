#Requires -Version 7.4
<#
.SYNOPSIS
    Expand the identity graph with cross-tenant B2B + SPN-to-resource edges.
.DESCRIPTION
    Builds on the existing IdentityCorrelator. Adds first-class Edge records to
    the EntityStore for relationships that auditors ask about first:

        - GuestOf            : B2B guest user -> external home tenant
        - MemberOf           : User|SPN -> directory group / role
        - HasRoleOn          : SPN|User -> AzureResource (RBAC role assignment)
        - OwnsAppRegistration: User|SPN -> Application
        - ConsentedTo        : User|SPN -> Application (delegated/admin consent)

    Microsoft Graph access is OPTIONAL. When the Microsoft.Graph modules are not
    connected, the wrapper consumes pre-fetched data via -PreFetchedData (test
    fixtures, offline mode) and returns whatever can be derived from the existing
    EntityStore. All Graph calls are wrapped in Invoke-WithRetry to handle the
    aggressive 429 throttling Graph applies. All errors are sanitised.

    Read-only Graph scopes required when running live:
        User.Read.All, Application.Read.All, Directory.Read.All
.PARAMETER EntityStore
    Populated EntityStore. Edges are added directly via $Store.AddEdge.
.PARAMETER TenantId
    Home tenant id (for canonical Tenant entity ids).
.PARAMETER PreFetchedData
    Optional PSCustomObject with .Guests, .GroupMemberships, .AppRoleAssignments,
    .RbacAssignments, .AppOwnerships, .ConsentGrants. Used by tests; bypasses
    live Graph calls when supplied.
.PARAMETER IncludeGraphLookup
    When set and Microsoft.Graph is connected, performs live Graph queries.
.OUTPUTS
    PSCustomObject @{ Status; RunId; Findings = [...]; Edges = [...] }.
    Findings already passed through New-FindingRow. Edges already passed
    through New-Edge AND added to the supplied EntityStore (so the orchestrator
    must NOT re-add them).

    This is the "envelope" correlator contract (issue #187). The orchestrator
    (Invoke-AzureAnalyzer.ps1) detects the envelope shape via:
        $corrRaw -is [pscustomobject] AND has .Findings AND has (.Status OR .Edges)
    Any future correlator returning flat finding rows MUST NOT include both a
    `Findings` property AND a `Status`/`Edges` property — that combination is
    reserved for this envelope contract.
#>
[CmdletBinding()]
param ()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. "$PSScriptRoot\shared\Schema.ps1"
. "$PSScriptRoot\shared\Sanitize.ps1"
. "$PSScriptRoot\shared\Retry.ps1"
. "$PSScriptRoot\shared\Canonicalize.ps1"

$script:HighPrivilegeRoles = @(
    'owner', 'contributor', 'user access administrator',
    'role based access control administrator', 'access review operator service role'
)
$script:RiskyConsentScopes = @(
    'directory.readwrite.all', 'application.readwrite.all',
    'roleassignmentschedule.readwrite.directory', 'rolemanagement.readwrite.directory',
    'mail.read', 'mail.readwrite', 'files.readwrite.all',
    'sites.fullcontrol.all', 'user.readwrite.all'
)

function Get-DomainFromUpn {
    [CmdletBinding()]
    param ([string] $Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $null }
    # B2B guests come back as `local#EXT#@home.onmicrosoft.com` — strip the EXT
    # suffix to recover the home domain. Fall back to plain domain split.
    if ($Value -match '#EXT#@([^@]+)$') { return $matches[1].ToLowerInvariant() }
    if ($Value -match '@([^@]+)$') { return $matches[1].ToLowerInvariant() }
    return $null
}

function Get-HomeTenantIdFromGuest {
    [CmdletBinding()]
    param ([object] $Guest)
    if (-not $Guest) { return $null }
    foreach ($prop in @('HomeTenantId', 'IssuerAssignedId', 'ExternalUserStateChangeDateTime')) {
        if ($Guest.PSObject.Properties[$prop] -and $Guest.$prop -is [string] -and $Guest.$prop -match '^[0-9a-f]{8}-([0-9a-f]{4}-){3}[0-9a-f]{12}$') {
            return ($Guest.$prop).ToLowerInvariant()
        }
    }
    if ($Guest.PSObject.Properties['Identities'] -and $Guest.Identities) {
        foreach ($id in @($Guest.Identities)) {
            if ($id.PSObject.Properties['Issuer'] -and $id.Issuer -match '([0-9a-f]{8}-([0-9a-f]{4}-){3}[0-9a-f]{12})') {
                return ($matches[1]).ToLowerInvariant()
            }
        }
    }
    return $null
}

function ConvertTo-CanonicalTenantToken {
    <#
    .SYNOPSIS
        Best-effort tenant canonicalization. Returns "tenant:{guid}" when a guid is
        available, else a slugified domain string ("tenant-domain:contoso.com").
    #>
    [CmdletBinding()]
    param ([string] $TenantIdOrDomain)
    if ([string]::IsNullOrWhiteSpace($TenantIdOrDomain)) { return $null }
    $value = $TenantIdOrDomain.Trim()
    try {
        $canonical = ConvertTo-CanonicalEntityId -RawId $value -EntityType 'Tenant'
        return $canonical.CanonicalId
    } catch {
        return "tenant-domain:$($value.ToLowerInvariant())"
    }
}

function Invoke-IdentityGraphExpansion {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [object] $EntityStore,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $TenantId,

        [PSCustomObject] $PreFetchedData,

        [switch] $IncludeGraphLookup
    )

    $runId = [guid]::NewGuid().ToString()
    $findings = [System.Collections.Generic.List[PSCustomObject]]::new()
    $edges = [System.Collections.Generic.List[PSCustomObject]]::new()
    $homeTenantCanonical = ConvertTo-CanonicalTenantToken -TenantIdOrDomain $TenantId

    # ------------------------------------------------------------------
    # Data acquisition. Pre-fetched data wins; otherwise opt-in Graph calls.
    # ------------------------------------------------------------------
    $data = if ($PreFetchedData) {
        $PreFetchedData
    } else {
        Get-IdentityGraphExpansionData -IncludeGraphLookup:$IncludeGraphLookup -EntityStore $EntityStore
    }

    # ------------------------------------------------------------------
    # B2B guest -> home tenant edges + dormant guest findings
    # ------------------------------------------------------------------
    $guests = if ($data -and $data.PSObject.Properties['Guests'] -and $data.Guests) { @($data.Guests) } else { @() }
    foreach ($guest in $guests) {
        if (-not $guest) { continue }
        $oid = if ($guest.PSObject.Properties['Id']) { [string]$guest.Id } else { $null }
        $upn = if ($guest.PSObject.Properties['UserPrincipalName']) { [string]$guest.UserPrincipalName } else { $null }
        $mail = if ($guest.PSObject.Properties['Mail']) { [string]$guest.Mail } else { $null }
        $state = if ($guest.PSObject.Properties['ExternalUserState']) { [string]$guest.ExternalUserState } else { 'Unknown' }
        if (-not $oid) { continue }

        try {
            $userCanonical = (ConvertTo-CanonicalEntityId -RawId $oid -EntityType 'User').CanonicalId
        } catch {
            Write-Verbose "Skipping guest with invalid object id: $(Remove-Credentials $_.Exception.Message)"
            continue
        }

        $homeTid = Get-HomeTenantIdFromGuest -Guest $guest
        $homeDomain = Get-DomainFromUpn -Value $upn
        if (-not $homeDomain) { $homeDomain = Get-DomainFromUpn -Value $mail }

        $tenantToken = if ($homeTid) { "tenant:$homeTid" } elseif ($homeDomain) { "tenant-domain:$homeDomain" } else { $null }
        if ($tenantToken) {
            $confidence = if ($homeTid) { 'Confirmed' } elseif ($homeDomain) { 'Likely' } else { 'Unknown' }
            $edge = New-Edge `
                -Source $userCanonical `
                -Target $tenantToken `
                -Relation 'GuestOf' `
                -Confidence $confidence `
                -Platform 'Entra' `
                -DiscoveredBy 'identity-graph-expansion' `
                -Properties @{
                    ExternalUserState = $state
                    HomeDomain        = $homeDomain
                    HomeTenantId      = $homeTid
                    GuestUpn          = $upn
                }
            if ($edge) { $edges.Add($edge) }
        }

        # Risk: pending-acceptance guests are dormant attack surface
        if ($state -eq 'PendingAcceptance') {
            $finding = New-FindingRow `
                -Id ([guid]::NewGuid().ToString()) `
                -Source 'identity-graph-expansion' `
                -EntityId $userCanonical `
                -EntityType 'User' `
                -Title "Dormant B2B guest in pending-acceptance state ($($upn ?? $oid))" `
                -Compliant $false `
                -ProvenanceRunId $runId `
                -Platform 'Entra' `
                -Category 'B2B Guest Hygiene' `
                -Severity 'Low' `
                -Confidence 'Confirmed' `
                -Detail "Guest user has not accepted invitation. Home domain: $($homeDomain ?? 'unknown'). Stale invitations should be reviewed and revoked." `
                -Remediation 'Audit pending B2B invitations regularly; revoke unused invitations via Entra > External Identities.'
            if ($finding) { $findings.Add($finding) }
        }
    }

    # ------------------------------------------------------------------
    # MemberOf edges (group/directory role memberships)
    # ------------------------------------------------------------------
    $memberships = if ($data -and $data.PSObject.Properties['GroupMemberships'] -and $data.GroupMemberships) { @($data.GroupMemberships) } else { @() }
    foreach ($m in $memberships) {
        if (-not $m) { continue }
        $principalId = if ($m.PSObject.Properties['PrincipalId']) { [string]$m.PrincipalId } else { $null }
        $principalType = if ($m.PSObject.Properties['PrincipalType']) { [string]$m.PrincipalType } else { 'User' }
        $groupId = if ($m.PSObject.Properties['GroupId']) { [string]$m.GroupId } else { $null }
        $groupName = if ($m.PSObject.Properties['GroupName']) { [string]$m.GroupName } else { $null }
        if (-not $principalId -or -not $groupId) { continue }

        try {
            $entityType = if ($principalType -match 'service|principal|managed') { 'ServicePrincipal' } else { 'User' }
            $srcCanonical = (ConvertTo-CanonicalEntityId -RawId $principalId -EntityType $entityType).CanonicalId
        } catch { continue }

        $groupToken = "group:$($groupId.ToLowerInvariant())"
        $edge = New-Edge `
            -Source $srcCanonical `
            -Target $groupToken `
            -Relation 'MemberOf' `
            -Confidence 'Confirmed' `
            -Platform 'Entra' `
            -DiscoveredBy 'identity-graph-expansion' `
            -Properties @{ GroupName = $groupName; PrincipalType = $principalType }
        if ($edge) { $edges.Add($edge) }
    }

    # ------------------------------------------------------------------
    # HasRoleOn edges from RBAC (SPN -> AzureResource)
    # ------------------------------------------------------------------
    $rbac = if ($data -and $data.PSObject.Properties['RbacAssignments'] -and $data.RbacAssignments) { @($data.RbacAssignments) } else { @() }
    foreach ($a in $rbac) {
        if (-not $a) { continue }
        $principalId = if ($a.PSObject.Properties['PrincipalId']) { [string]$a.PrincipalId } else { $null }
        $principalType = if ($a.PSObject.Properties['PrincipalType']) { [string]$a.PrincipalType } else { 'ServicePrincipal' }
        $scope = if ($a.PSObject.Properties['Scope']) { [string]$a.Scope } else { $null }
        $roleName = if ($a.PSObject.Properties['RoleDefinitionName']) { [string]$a.RoleDefinitionName } else { $null }
        if (-not $principalId -or -not $scope -or -not $roleName) { continue }

        try {
            $entityType = if ($principalType -match 'user') { 'User' } else { 'ServicePrincipal' }
            $srcCanonical = (ConvertTo-CanonicalEntityId -RawId $principalId -EntityType $entityType).CanonicalId
        } catch { continue }

        # Subscription-scope RBAC normalises to a Subscription entity, otherwise
        # treat the scope as a generic ARM resource id.
        $tgtCanonical = $null
        $tgtType = 'AzureResource'
        if ($scope -match '^/subscriptions/([0-9a-f-]{36})$') {
            try {
                $tgtCanonical = (ConvertTo-CanonicalEntityId -RawId $matches[1] -EntityType 'Subscription').CanonicalId
                $tgtType = 'Subscription'
            } catch { $tgtCanonical = $scope.ToLowerInvariant() }
        } else {
            try { $tgtCanonical = (ConvertTo-CanonicalEntityId -RawId $scope -EntityType 'AzureResource').CanonicalId }
            catch { $tgtCanonical = $scope.ToLowerInvariant() }
        }

        $edge = New-Edge `
            -Source $srcCanonical `
            -Target $tgtCanonical `
            -Relation 'HasRoleOn' `
            -Confidence 'Confirmed' `
            -Platform 'Azure' `
            -DiscoveredBy 'identity-graph-expansion' `
            -Properties @{ RoleName = $roleName; Scope = $scope; TargetType = $tgtType; PrincipalType = $principalType }
        if ($edge) { $edges.Add($edge) }

        # Risk: high-privilege role at subscription scope (or broader)
        $isHighPriv = $script:HighPrivilegeRoles -contains $roleName.ToLowerInvariant()
        $isBroadScope = ($scope -match '^/subscriptions/[0-9a-f-]{36}$') -or ($scope -match '^/providers/Microsoft\.Management/managementGroups/')
        if ($isHighPriv -and $isBroadScope) {
            $severity = if ($roleName -match '(?i)owner') { 'High' } else { 'Medium' }
            $finding = New-FindingRow `
                -Id ([guid]::NewGuid().ToString()) `
                -Source 'identity-graph-expansion' `
                -EntityId $srcCanonical `
                -EntityType $entityType `
                -Title "Over-privileged $entityType holds '$roleName' at $scope" `
                -Compliant $false `
                -ProvenanceRunId $runId `
                -Platform 'Azure' `
                -Category 'Identity Blast Radius' `
                -Severity $severity `
                -Confidence 'Confirmed' `
                -Detail "Principal $principalId has role '$roleName' assigned at scope '$scope'. High-privilege roles at subscription or management-group scope grant broad access and should be replaced with least-privilege custom roles or PIM-eligible assignments." `
                -Remediation 'Replace standing assignment with PIM-eligible role activation, or scope role to a single resource group.'
            if ($finding) { $findings.Add($finding) }
        }
    }

    # ------------------------------------------------------------------
    # OwnsAppRegistration edges
    # ------------------------------------------------------------------
    $owners = if ($data -and $data.PSObject.Properties['AppOwnerships'] -and $data.AppOwnerships) { @($data.AppOwnerships) } else { @() }
    foreach ($o in $owners) {
        if (-not $o) { continue }
        $ownerId = if ($o.PSObject.Properties['OwnerId']) { [string]$o.OwnerId } else { $null }
        $ownerType = if ($o.PSObject.Properties['OwnerType']) { [string]$o.OwnerType } else { 'User' }
        $appId = if ($o.PSObject.Properties['AppId']) { [string]$o.AppId } else { $null }
        $appName = if ($o.PSObject.Properties['AppDisplayName']) { [string]$o.AppDisplayName } else { $null }
        if (-not $ownerId -or -not $appId) { continue }

        try {
            $entityType = if ($ownerType -match 'service|principal') { 'ServicePrincipal' } else { 'User' }
            $srcCanonical = (ConvertTo-CanonicalEntityId -RawId $ownerId -EntityType $entityType).CanonicalId
            $tgtCanonical = (ConvertTo-CanonicalEntityId -RawId $appId -EntityType 'Application').CanonicalId
        } catch { continue }

        $edge = New-Edge `
            -Source $srcCanonical `
            -Target $tgtCanonical `
            -Relation 'OwnsAppRegistration' `
            -Confidence 'Confirmed' `
            -Platform 'Entra' `
            -DiscoveredBy 'identity-graph-expansion' `
            -Properties @{ AppDisplayName = $appName; OwnerType = $ownerType }
        if ($edge) { $edges.Add($edge) }
    }

    # ------------------------------------------------------------------
    # ConsentedTo edges + risky-consent findings
    # ------------------------------------------------------------------
    $consents = if ($data -and $data.PSObject.Properties['ConsentGrants'] -and $data.ConsentGrants) { @($data.ConsentGrants) } else { @() }
    foreach ($g in $consents) {
        if (-not $g) { continue }
        $clientId = if ($g.PSObject.Properties['ClientId']) { [string]$g.ClientId } else { $null }
        $resourceId = if ($g.PSObject.Properties['ResourceId']) { [string]$g.ResourceId } else { $null }
        $consentType = if ($g.PSObject.Properties['ConsentType']) { [string]$g.ConsentType } else { 'AllPrincipals' }
        $scope = if ($g.PSObject.Properties['Scope']) { [string]$g.Scope } else { '' }
        if (-not $clientId -or -not $resourceId) { continue }

        try {
            $srcCanonical = (ConvertTo-CanonicalEntityId -RawId $clientId -EntityType 'ServicePrincipal').CanonicalId
            $tgtCanonical = (ConvertTo-CanonicalEntityId -RawId $resourceId -EntityType 'Application').CanonicalId
        } catch { continue }

        $edge = New-Edge `
            -Source $srcCanonical `
            -Target $tgtCanonical `
            -Relation 'ConsentedTo' `
            -Confidence 'Confirmed' `
            -Platform 'Entra' `
            -DiscoveredBy 'identity-graph-expansion' `
            -Properties @{ ConsentType = $consentType; Scope = $scope }
        if ($edge) { $edges.Add($edge) }

        # Risk: tenant-wide consent to risky scopes
        $scopeTokens = @($scope -split '\s+' | Where-Object { $_ } | ForEach-Object { $_.ToLowerInvariant() })
        $risky = @($scopeTokens | Where-Object { $script:RiskyConsentScopes -contains $_ })
        if ($consentType -eq 'AllPrincipals' -and $risky.Count -gt 0) {
            $finding = New-FindingRow `
                -Id ([guid]::NewGuid().ToString()) `
                -Source 'identity-graph-expansion' `
                -EntityId $srcCanonical `
                -EntityType 'ServicePrincipal' `
                -Title "Tenant-wide admin consent for risky scopes: $($risky -join ', ')" `
                -Compliant $false `
                -ProvenanceRunId $runId `
                -Platform 'Entra' `
                -Category 'Excessive Consent' `
                -Severity 'High' `
                -Confidence 'Confirmed' `
                -Detail "Application $clientId holds tenant-wide admin consent to high-impact scopes ($($risky -join ', ')) on resource $resourceId. Tenant-wide admin consent should be reserved for first-party Microsoft apps and explicitly approved third parties." `
                -Remediation 'Review the consent grant in Entra > Enterprise Applications > Permissions and revoke if not justified.'
            if ($finding) { $findings.Add($finding) }
        }
    }

    # Persist edges to the supplied store (when one was provided and supports it)
    $store = $EntityStore
    if ($store -and $store.PSObject.Methods['AddEdge']) {
        foreach ($e in $edges) {
            try { $store.AddEdge($e) }
            catch {
                $msg = if (Get-Command Remove-Credentials -ErrorAction SilentlyContinue) {
                    Remove-Credentials $_.Exception.Message
                } else { $_.Exception.Message }
                Write-Warning "AddEdge failed for $($e.EdgeId): $msg"
            }
        }
    }

    Write-Verbose "IdentityGraphExpansion: emitted $($findings.Count) finding(s) and $($edges.Count) edge(s)."
    return [PSCustomObject]@{
        Status   = 'Success'
        RunId    = $runId
        Findings = @($findings)
        Edges    = @($edges)
    }
}

function Get-IdentityGraphExpansionData {
    <#
    .SYNOPSIS
        Live Microsoft Graph + ARM data acquisition. Always wrapped in retry.
    .DESCRIPTION
        Returns an object with Guests/GroupMemberships/RbacAssignments/AppOwnerships/ConsentGrants
        arrays. Skips gracefully when modules / context are missing.
    #>
    [CmdletBinding()]
    param (
        [switch] $IncludeGraphLookup,
        [object] $EntityStore
    )

    $result = [PSCustomObject]@{
        Guests             = @()
        GroupMemberships   = @()
        RbacAssignments    = @()
        AppOwnerships      = @()
        ConsentGrants      = @()
    }

    if (-not $IncludeGraphLookup) {
        Write-Verbose 'IdentityGraphExpansion: -IncludeGraphLookup not set; returning empty live data.'
        return $result
    }

    $mg = Get-Command -Name 'Get-MgUser' -ErrorAction SilentlyContinue
    if (-not $mg) {
        Write-Warning 'IdentityGraphExpansion: Microsoft.Graph.Users module not loaded; skipping live Graph queries.'
        return $result
    }

    try {
        $guests = Invoke-WithRetry -ScriptBlock {
            Get-MgUser -Filter "userType eq 'Guest'" -All `
                -Property 'id,userPrincipalName,mail,externalUserState,identities' `
                -ErrorAction Stop
        }
        if ($guests) { $result.Guests = @($guests) }
    } catch {
        Write-Warning "IdentityGraphExpansion: Guest query failed: $(Remove-Credentials $_.Exception.Message)"
    }

    # Group memberships and app ownerships are intentionally NOT bulk-enumerated;
    # we follow the same candidate-reduction discipline as IdentityCorrelator and
    # leave per-principal expansion to the caller if needed.
    return $result
}
