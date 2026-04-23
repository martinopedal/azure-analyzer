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

$envelopePath = Join-Path $PSScriptRoot 'shared' 'New-WrapperEnvelope.ps1'
if (Test-Path $envelopePath) { . $envelopePath }
if (-not (Get-Command New-WrapperEnvelope -ErrorAction SilentlyContinue)) { function New-WrapperEnvelope { param([string]$Source,[string]$Status='Failed',[string]$Message='',[object[]]$FindingErrors=@()) return [PSCustomObject]@{ Source=$Source; SchemaVersion='1.0'; Status=$Status; Message=$Message; Findings=@(); Errors=@($FindingErrors) } } }
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

function Get-IdentityGraphFrameworks {
    [CmdletBinding()]
    param ()
    return @(
        @{ Name = 'NIST 800-53'; Controls = @('AC-2', 'AC-6', 'IA-2', 'IA-5'); Pillars = @('Security') },
        @{ Name = 'CIS Controls v8'; Controls = @('5.4', '6.1', '6.8'); Pillars = @('Security') }
    )
}

function Get-IdentityGraphMitre {
    [CmdletBinding()]
    param ()
    return @{
        Tactics    = @('TA0008', 'TA0004')
        Techniques = @('T1078', 'T1098')
    }
}

function Get-EntraPortalDeepLink {
    [CmdletBinding()]
    param (
        [string] $EntityId,
        [string] $EntityType
    )

    if ([string]::IsNullOrWhiteSpace($EntityId)) {
        return 'https://entra.microsoft.com/#view/Microsoft_AAD_IAM/ActiveDirectoryMenuBlade/~/Overview'
    }

    switch ($EntityType) {
        'User' {
            if ($EntityId -match '^objectId:([0-9a-f-]{36})$') {
                return "https://entra.microsoft.com/#view/Microsoft_AAD_UsersAndTenants/UserProfileMenuBlade/~/overview/userId/$($matches[1])"
            }
        }
        'ServicePrincipal' {
            if ($EntityId -match '^appId:([0-9a-f-]{36})$') {
                return "https://entra.microsoft.com/#view/Microsoft_AAD_IAM/ManagedAppMenuBlade/~/Overview/objectId/$($matches[1])"
            }
        }
        'Tenant' {
            return 'https://entra.microsoft.com/#view/Microsoft_AAD_IAM/ActiveDirectoryMenuBlade/~/Overview'
        }
    }

    return 'https://entra.microsoft.com/#view/Microsoft_AAD_IAM/ActiveDirectoryMenuBlade/~/Overview'
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

        [switch] $IncludeGraphLookup,

        # Maximum number of principals to enumerate per collector. Prevents
        # runaway Graph/ARM calls in large tenants; principals beyond the cap
        # are not expanded. An Info finding is emitted when the cap is hit.
        [int] $MaxPrincipals = 1000
    )

    $runId = [guid]::NewGuid().ToString()
    $findings = [System.Collections.Generic.List[PSCustomObject]]::new()
    $edges = [System.Collections.Generic.List[PSCustomObject]]::new()
    $homeTenantCanonical = ConvertTo-CanonicalTenantToken -TenantIdOrDomain $TenantId
    $frameworks = Get-IdentityGraphFrameworks
    $mitre = Get-IdentityGraphMitre
    $wrapperToolVersion = 'identity-graph-expansion@1.0'

    # ------------------------------------------------------------------
    # Data acquisition. Pre-fetched data wins; otherwise opt-in Graph calls.
    # ------------------------------------------------------------------
    $data = if ($PreFetchedData) {
        $PreFetchedData
    } else {
        Get-IdentityGraphExpansionData -IncludeGraphLookup:$IncludeGraphLookup -EntityStore $EntityStore -MaxPrincipals $MaxPrincipals
    }

    # Emit Info finding when the live collector hit the principal cap.
    if ($data -and $data.PSObject.Properties['PrincipalCapHit'] -and $data.PrincipalCapHit) {
        $capFinding = New-FindingRow `
            -Id ([guid]::NewGuid().ToString()) `
            -Source 'identity-graph-expansion' `
            -EntityId $homeTenantCanonical `
            -EntityType 'Tenant' `
            -Title "Identity Graph Expansion capped at $MaxPrincipals principals" `
            -Compliant $true `
            -ProvenanceRunId $runId `
            -Platform 'Entra' `
            -Category 'Expansion Cap' `
            -Severity 'Info' `
            -Confidence 'Confirmed' `
            -Detail "Live collector enumeration was limited to $MaxPrincipals principals from the EntityStore. Remaining principals were not expanded. Re-run with a higher -MaxPrincipals value for full coverage." `
            -Remediation 'Increase -MaxPrincipals or scope the EntityStore to fewer subscriptions/tenants.' `
            -Frameworks $frameworks `
            -Pillar 'Security' `
            -Impact 'Low' `
            -Effort 'Low' `
            -DeepLinkUrl (Get-EntraPortalDeepLink -EntityId $homeTenantCanonical -EntityType 'Tenant') `
            -RemediationSnippets @(@{ language = 'powershell'; code = "Invoke-AzureAnalyzer -IncludeTools 'identity-graph-expansion' -TenantId '$TenantId' -IncludeGraphLookup -MaxPrincipals 5000" }) `
            -EvidenceUris @('https://entra.microsoft.com/#view/Microsoft_AAD_IAM/ActiveDirectoryMenuBlade/~/Overview') `
            -BaselineTags @('identity-graph-expansion', 'collector-cap') `
            -MitreTactics @($mitre.Tactics) `
            -MitreTechniques @($mitre.Techniques) `
            -EntityRefs @($homeTenantCanonical) `
            -ToolVersion $wrapperToolVersion
        if ($capFinding) { $findings.Add($capFinding) }
    }

    # Emit Info finding for each collector that was short-circuited by throttling.
    if ($data -and $data.PSObject.Properties['ThrottledCollectors']) {
        foreach ($collectorName in @($data.ThrottledCollectors)) {
            if (-not $collectorName) { continue }
            $throttleFinding = New-FindingRow `
                -Id ([guid]::NewGuid().ToString()) `
                -Source 'identity-graph-expansion' `
                -EntityId $homeTenantCanonical `
                -EntityType 'Tenant' `
                -Title "Collector '$collectorName' halted after 3 consecutive throttle (429) responses" `
                -Compliant $true `
                -ProvenanceRunId $runId `
                -Platform 'Entra' `
                -Category 'Throttle Skip' `
                -Severity 'Info' `
                -Confidence 'Confirmed' `
                -Detail "The '$collectorName' collector received 3 consecutive 429 responses from Microsoft Graph and was halted to avoid prolonged blocking. Partial data is included. Retry after the throttling window expires (typically 10-60 minutes)." `
                -Remediation 'Wait for the Graph throttling window to expire and re-run with -IncludeGraphLookup. Consider reducing -MaxPrincipals to lower request volume.' `
                -Frameworks $frameworks `
                -Pillar 'Security' `
                -Impact 'Low' `
                -Effort 'Low' `
                -DeepLinkUrl (Get-EntraPortalDeepLink -EntityId $homeTenantCanonical -EntityType 'Tenant') `
                -RemediationSnippets @(@{ language = 'text'; code = "Retry collector '$collectorName' after Graph throttling clears." }) `
                -EvidenceUris @('https://entra.microsoft.com/#view/Microsoft_AAD_IAM/ActiveDirectoryMenuBlade/~/Overview') `
                -BaselineTags @('identity-graph-expansion', 'throttle-skip', "collector:$collectorName") `
                -MitreTactics @($mitre.Tactics) `
                -MitreTechniques @($mitre.Techniques) `
                -EntityRefs @($homeTenantCanonical) `
                -ToolVersion $wrapperToolVersion
            if ($throttleFinding) { $findings.Add($throttleFinding) }
        }
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
                -Remediation 'Audit pending B2B invitations regularly; revoke unused invitations via Entra > External Identities.' `
                -Frameworks $frameworks `
                -Pillar 'Security' `
                -Impact 'Medium' `
                -Effort 'Low' `
                -DeepLinkUrl (Get-EntraPortalDeepLink -EntityId $userCanonical -EntityType 'User') `
                -RemediationSnippets @(@{ language = 'text'; code = 'Review guest accounts in Entra External Identities and remove stale pending invitations.' }) `
                -EvidenceUris @('https://entra.microsoft.com/#view/Microsoft_AAD_UsersAndTenants/UserManagementMenuBlade/~/AllUsers') `
                -BaselineTags @('identity-graph-expansion', 'guest', "external-state:$state") `
                -MitreTactics @($mitre.Tactics) `
                -MitreTechniques @($mitre.Techniques) `
                -EntityRefs @($userCanonical, $tenantToken, $homeTenantCanonical | Where-Object { $_ } | Select-Object -Unique) `
                -ToolVersion $wrapperToolVersion
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
                -Remediation 'Replace standing assignment with PIM-eligible role activation, or scope role to a single resource group.' `
                -Frameworks $frameworks `
                -Pillar 'Security' `
                -Impact 'High' `
                -Effort 'Medium' `
                -DeepLinkUrl (Get-EntraPortalDeepLink -EntityId $srcCanonical -EntityType $entityType) `
                -RemediationSnippets @(@{ language = 'text'; code = "Move role '$roleName' to PIM eligibility and reduce scope from '$scope' where possible." }) `
                -EvidenceUris @("https://portal.azure.com/#@$TenantId/resource$scope", 'https://entra.microsoft.com/#view/Microsoft_AAD_IAM/ActiveDirectoryMenuBlade/~/Overview') `
                -BaselineTags @('identity-graph-expansion', 'rbac', "role:$($roleName.ToLowerInvariant())") `
                -MitreTactics @($mitre.Tactics) `
                -MitreTechniques @($mitre.Techniques) `
                -EntityRefs @($srcCanonical, $tgtCanonical, $homeTenantCanonical | Where-Object { $_ } | Select-Object -Unique) `
                -ToolVersion $wrapperToolVersion
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
                -Remediation 'Review the consent grant in Entra > Enterprise Applications > Permissions and revoke if not justified.' `
                -Frameworks $frameworks `
                -Pillar 'Security' `
                -Impact 'High' `
                -Effort 'Medium' `
                -DeepLinkUrl (Get-EntraPortalDeepLink -EntityId $srcCanonical -EntityType 'ServicePrincipal') `
                -RemediationSnippets @(@{ language = 'text'; code = "Review and revoke risky scopes ($($risky -join ', ')) in Entra Enterprise Applications permissions." }) `
                -EvidenceUris @('https://entra.microsoft.com/#view/Microsoft_AAD_IAM/StartboardApplicationsMenuBlade/~/AppAppsPreview') `
                -BaselineTags @('identity-graph-expansion', 'consent', 'tenant-wide-admin-consent') `
                -MitreTactics @($mitre.Tactics) `
                -MitreTechniques @($mitre.Techniques) `
                -EntityRefs @($srcCanonical, $tgtCanonical, $homeTenantCanonical | Where-Object { $_ } | Select-Object -Unique) `
                -ToolVersion $wrapperToolVersion
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

    $expansionSummary = [object[]] @()
    if ($data -and $data.PSObject.Properties['ExpansionSummary'] -and $data.ExpansionSummary) {
        $expansionSummary = @($data.ExpansionSummary)
    }

    Write-Verbose "IdentityGraphExpansion: emitted $($findings.Count) finding(s) and $($edges.Count) edge(s)."
    return [PSCustomObject]@{
        Status           = 'Success'
        RunId            = $runId
        ToolVersion      = $wrapperToolVersion
        Findings         = @($findings)
        Edges            = @($edges)
        ExpansionSummary = $expansionSummary
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
        [object] $EntityStore,
        [int]    $MaxPrincipals = 1000
    )

    $expansionSummaryList = [System.Collections.Generic.List[PSCustomObject]]::new()
    $throttledCollectors  = [System.Collections.Generic.List[string]]::new()

    $result = [PSCustomObject]@{
        Guests              = @()
        GroupMemberships    = @()
        RbacAssignments     = @()
        AppOwnerships       = @()
        ConsentGrants       = @()
        ExpansionSummary    = $expansionSummaryList
        PrincipalCapHit     = $false
        ThrottledCollectors = $throttledCollectors
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

    # ---- Guests (tenant-wide) ----
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

    # ---- Candidate extraction from EntityStore (candidate-driven expansion) ----
    # Only enumerate for principals already in the EntityStore (O(P) API calls,
    # where P = known principals). Avoids full-tenant enumeration of group members.
    $userOids  = [System.Collections.Generic.List[string]]::new()
    $spnAppIds = [System.Collections.Generic.List[string]]::new()

    if ($EntityStore) {
        try {
            $allEntities = @($EntityStore.GetEntities())
        } catch {
            $allEntities = @()
            Write-Verbose "IdentityGraphExpansion: EntityStore.GetEntities() failed: $(Remove-Credentials $_.Exception.Message)"
        }
        foreach ($entity in $allEntities) {
            if (-not $entity) { continue }
            switch ($entity.EntityType) {
                'User' {
                    if ($entity.EntityId -match '^objectId:([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})$') {
                        $userOids.Add($matches[1])
                    }
                }
                'ServicePrincipal' {
                    if ($entity.EntityId -match '^appId:([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})$') {
                        $spnAppIds.Add($matches[1])
                    }
                }
            }
        }
    }

    $userOids  = @($userOids  | Select-Object -Unique)
    $spnAppIds = @($spnAppIds | Select-Object -Unique)

    # Apply principal cap (split proportionally between users and SPNs).
    $totalPrincipals = $userOids.Count + $spnAppIds.Count
    if ($MaxPrincipals -gt 0 -and $totalPrincipals -gt $MaxPrincipals) {
        Write-Warning "IdentityGraphExpansion: principal count ($totalPrincipals) exceeds cap ($MaxPrincipals); truncating to avoid excessive Graph/ARM calls."
        $result.PrincipalCapHit = $true
        $userSlots = if ($totalPrincipals -gt 0) { [math]::Min($userOids.Count, [int][math]::Ceiling($MaxPrincipals * ($userOids.Count / $totalPrincipals))) } else { 0 }
        $spnSlots  = $MaxPrincipals - $userSlots
        $userOids  = @(if ($userSlots  -gt 0) { $userOids[0..($userSlots  - 1)] })
        $spnAppIds = @(if ($spnSlots   -gt 0) { $spnAppIds[0..($spnSlots  - 1)] })
    }

    # Resolve SPN appId -> objectId (Graph and ARM APIs need the object ID).
    $spnObjectIds = @{}
    if ($spnAppIds.Count -gt 0 -and (Get-Command 'Get-MgServicePrincipal' -ErrorAction SilentlyContinue)) {
        foreach ($appId in $spnAppIds) {
            try {
                $spnRaw = Invoke-WithRetry -ScriptBlock {
                    Get-MgServicePrincipal -Filter "appId eq '$appId'" -Select 'id,appId' -Top 1 -ErrorAction Stop
                }
                if ($spnRaw -and $spnRaw.Id) { $spnObjectIds[$appId] = [string]$spnRaw.Id }
            } catch {
                Write-Warning "IdentityGraphExpansion: SPN objectId lookup failed for appId ${appId}: $(Remove-Credentials $_.Exception.Message)"
            }
        }
    }
    $spnOids = @($spnObjectIds.Values)

    # ---- GroupMemberships collector ----
    # Requires: Microsoft.Graph.Groups (Get-MgUserMemberOf) and/or
    #           Microsoft.Graph.Applications (Get-MgServicePrincipalMemberOf).
    $hasMgUserMemberOf = Get-Command 'Get-MgUserMemberOf'            -ErrorAction SilentlyContinue
    $hasMgSpnMemberOf  = Get-Command 'Get-MgServicePrincipalMemberOf' -ErrorAction SilentlyContinue
    if ($hasMgUserMemberOf -or $hasMgSpnMemberOf) {
        $memberships    = [System.Collections.Generic.List[PSCustomObject]]::new()
        $consecutive429 = 0
        $throttled      = $false
        $principalQueue = @(
            @($userOids | ForEach-Object { [PSCustomObject]@{ Oid = $_; Type = 'User' } })
            @($spnOids  | ForEach-Object { [PSCustomObject]@{ Oid = $_; Type = 'ServicePrincipal' } })
        ) | Where-Object { $_ }
        foreach ($p in $principalQueue) {
            if ($throttled) { break }
            try {
                $rawItems = if ($p.Type -eq 'User' -and $hasMgUserMemberOf) {
                    Invoke-WithRetry -ScriptBlock { Get-MgUserMemberOf -UserId $p.Oid -Property 'id,displayName' -All -ErrorAction Stop }
                } elseif ($p.Type -eq 'ServicePrincipal' -and $hasMgSpnMemberOf) {
                    Invoke-WithRetry -ScriptBlock { Get-MgServicePrincipalMemberOf -ServicePrincipalId $p.Oid -Property 'id,displayName' -All -ErrorAction Stop }
                } else { @() }
                $consecutive429 = 0
                foreach ($m in @($rawItems)) {
                    if (-not $m -or -not $m.Id) { continue }
                    $memberships.Add([PSCustomObject]@{
                        PrincipalId   = $p.Oid
                        PrincipalType = $p.Type
                        GroupId       = [string]$m.Id
                        GroupName     = if ($m.PSObject.Properties['DisplayName'] -and $m.DisplayName) { [string]$m.DisplayName } else { '' }
                    })
                }
            } catch {
                $errMsg = Remove-Credentials $_.Exception.Message
                if ($errMsg -match '\b429\b|throttl|rate.?limit') {
                    $consecutive429++
                    Write-Warning "IdentityGraphExpansion: GroupMemberships throttled for $($p.Oid) ($consecutive429/3): $errMsg"
                    if ($consecutive429 -ge 3) { $throttled = $true; $throttledCollectors.Add('GroupMemberships'); break }
                } else {
                    Write-Warning "IdentityGraphExpansion: GroupMemberships failed for $($p.Oid): $errMsg"
                    $consecutive429 = 0
                }
            }
        }
        $result.GroupMemberships = @($memberships)
        $expansionSummaryList.Add([PSCustomObject]@{
            Collector      = 'GroupMemberships'
            PrincipalCount = @($principalQueue).Count
            EdgeCount      = $memberships.Count
            Skipped        = $throttled
            SkipReason     = if ($throttled) { '3 consecutive 429 responses from Microsoft Graph; retry after throttling window' } else { $null }
        })
    } else {
        Write-Warning 'IdentityGraphExpansion: Get-MgUserMemberOf not available; skipping GroupMemberships collector.'
        $expansionSummaryList.Add([PSCustomObject]@{ Collector = 'GroupMemberships'; PrincipalCount = 0; EdgeCount = 0; Skipped = $true; SkipReason = 'Microsoft.Graph.Groups module not loaded' })
    }

    # ---- RbacAssignments collector (Azure ARM RBAC via Az.Resources) ----
    # Uses Get-AzRoleAssignment (ARM scopes) NOT Get-MgRoleManagementDirectoryRoleAssignment
    # (which returns Entra ID directory roles at scope="/", not ARM resource scopes).
    $hasAzRoleAssignment = Get-Command 'Get-AzRoleAssignment' -ErrorAction SilentlyContinue
    if ($hasAzRoleAssignment) {
        $rbacList       = [System.Collections.Generic.List[PSCustomObject]]::new()
        $consecutive429 = 0
        $throttled      = $false
        $allPrincipals  = @(
            @($userOids | ForEach-Object { [PSCustomObject]@{ Oid = $_; Type = 'User' } })
            @($spnOids  | ForEach-Object { [PSCustomObject]@{ Oid = $_; Type = 'ServicePrincipal' } })
        ) | Where-Object { $_ }
        foreach ($p in $allPrincipals) {
            if ($throttled) { break }
            try {
                $assignments = Invoke-WithRetry -ScriptBlock { Get-AzRoleAssignment -ObjectId $p.Oid -ErrorAction Stop }
                $consecutive429 = 0
                foreach ($a in @($assignments)) {
                    if (-not $a) { continue }
                    $rbacList.Add([PSCustomObject]@{
                        PrincipalId        = $p.Oid
                        PrincipalType      = $p.Type
                        Scope              = if ($a.PSObject.Properties['Scope'])              { [string]$a.Scope }              else { $null }
                        RoleDefinitionName = if ($a.PSObject.Properties['RoleDefinitionName']) { [string]$a.RoleDefinitionName } else { $null }
                    })
                }
            } catch {
                $errMsg = Remove-Credentials $_.Exception.Message
                if ($errMsg -match '\b429\b|throttl|rate.?limit') {
                    $consecutive429++
                    Write-Warning "IdentityGraphExpansion: RbacAssignments throttled for $($p.Oid) ($consecutive429/3): $errMsg"
                    if ($consecutive429 -ge 3) { $throttled = $true; $throttledCollectors.Add('RbacAssignments'); break }
                } else {
                    Write-Warning "IdentityGraphExpansion: RbacAssignments failed for $($p.Oid): $errMsg"
                    $consecutive429 = 0
                }
            }
        }
        $result.RbacAssignments = @($rbacList)
        $expansionSummaryList.Add([PSCustomObject]@{
            Collector      = 'RbacAssignments'
            PrincipalCount = @($allPrincipals).Count
            EdgeCount      = $rbacList.Count
            Skipped        = $throttled
            SkipReason     = if ($throttled) { '3 consecutive 429 responses from ARM; retry after throttling window' } else { $null }
        })
    } else {
        Write-Warning 'IdentityGraphExpansion: Get-AzRoleAssignment not available (Az.Resources not loaded); skipping RbacAssignments collector.'
        $expansionSummaryList.Add([PSCustomObject]@{ Collector = 'RbacAssignments'; PrincipalCount = 0; EdgeCount = 0; Skipped = $true; SkipReason = 'Az.Resources module not loaded' })
    }

    # ---- AppOwnerships collector ----
    # Requires Microsoft.Graph.Applications.
    $hasMgUserOwnedApp   = Get-Command 'Get-MgUserOwnedApplication'       -ErrorAction SilentlyContinue
    $hasMgSpnOwnedObject = Get-Command 'Get-MgServicePrincipalOwnedObject' -ErrorAction SilentlyContinue
    if ($hasMgUserOwnedApp -or $hasMgSpnOwnedObject) {
        $ownershipList  = [System.Collections.Generic.List[PSCustomObject]]::new()
        $consecutive429 = 0
        $throttled      = $false
        $principalQueue = @(
            @($userOids | ForEach-Object { [PSCustomObject]@{ Oid = $_; Type = 'User' } })
            @($spnOids  | ForEach-Object { [PSCustomObject]@{ Oid = $_; Type = 'ServicePrincipal' } })
        ) | Where-Object { $_ }
        foreach ($p in $principalQueue) {
            if ($throttled) { break }
            try {
                $ownedApps = if ($p.Type -eq 'User' -and $hasMgUserOwnedApp) {
                    Invoke-WithRetry -ScriptBlock { Get-MgUserOwnedApplication -UserId $p.Oid -Property 'id,displayName' -All -ErrorAction Stop }
                } elseif ($p.Type -eq 'ServicePrincipal' -and $hasMgSpnOwnedObject) {
                    Invoke-WithRetry -ScriptBlock { Get-MgServicePrincipalOwnedObject -ServicePrincipalId $p.Oid -Property 'id,displayName' -All -ErrorAction Stop }
                } else { @() }
                $consecutive429 = 0
                foreach ($app in @($ownedApps)) {
                    if (-not $app -or -not $app.Id) { continue }
                    $ownershipList.Add([PSCustomObject]@{
                        OwnerId        = $p.Oid
                        OwnerType      = $p.Type
                        AppId          = [string]$app.Id
                        AppDisplayName = if ($app.PSObject.Properties['DisplayName'] -and $app.DisplayName) { [string]$app.DisplayName } else { '' }
                    })
                }
            } catch {
                $errMsg = Remove-Credentials $_.Exception.Message
                if ($errMsg -match '\b429\b|throttl|rate.?limit') {
                    $consecutive429++
                    Write-Warning "IdentityGraphExpansion: AppOwnerships throttled for $($p.Oid) ($consecutive429/3): $errMsg"
                    if ($consecutive429 -ge 3) { $throttled = $true; $throttledCollectors.Add('AppOwnerships'); break }
                } else {
                    Write-Warning "IdentityGraphExpansion: AppOwnerships failed for $($p.Oid): $errMsg"
                    $consecutive429 = 0
                }
            }
        }
        $result.AppOwnerships = @($ownershipList)
        $expansionSummaryList.Add([PSCustomObject]@{
            Collector      = 'AppOwnerships'
            PrincipalCount = @($principalQueue).Count
            EdgeCount      = $ownershipList.Count
            Skipped        = $throttled
            SkipReason     = if ($throttled) { '3 consecutive 429 responses from Microsoft Graph; retry after throttling window' } else { $null }
        })
    } else {
        Write-Warning 'IdentityGraphExpansion: Get-MgUserOwnedApplication not available; skipping AppOwnerships collector.'
        $expansionSummaryList.Add([PSCustomObject]@{ Collector = 'AppOwnerships'; PrincipalCount = 0; EdgeCount = 0; Skipped = $true; SkipReason = 'Microsoft.Graph.Applications module not loaded' })
    }

    # ---- ConsentGrants collector (bulk: single tenant-wide call, filter client-side) ----
    # Unlike other collectors, this is O(1) calls regardless of principal count.
    $hasMgOAuth2Grant = Get-Command 'Get-MgOAuth2PermissionGrant' -ErrorAction SilentlyContinue
    if ($hasMgOAuth2Grant) {
        try {
            $allGrants = Invoke-WithRetry -ScriptBlock {
                Get-MgOAuth2PermissionGrant -All -Property 'clientId,resourceId,consentType,scope' -ErrorAction Stop
            }
            $result.ConsentGrants = @($allGrants | ForEach-Object {
                if (-not $_) { return }
                [PSCustomObject]@{
                    ClientId    = if ($_.PSObject.Properties['ClientId']    -and $_.ClientId)    { [string]$_.ClientId }    else { '' }
                    ResourceId  = if ($_.PSObject.Properties['ResourceId']  -and $_.ResourceId)  { [string]$_.ResourceId }  else { '' }
                    ConsentType = if ($_.PSObject.Properties['ConsentType'] -and $_.ConsentType) { [string]$_.ConsentType } else { '' }
                    Scope       = if ($_.PSObject.Properties['Scope']       -and $_.Scope)       { [string]$_.Scope }       else { '' }
                }
            } | Where-Object { $_ })
            $expansionSummaryList.Add([PSCustomObject]@{
                Collector      = 'ConsentGrants'
                PrincipalCount = 0
                EdgeCount      = $result.ConsentGrants.Count
                Skipped        = $false
                SkipReason     = $null
            })
        } catch {
            $errMsg = Remove-Credentials $_.Exception.Message
            Write-Warning "IdentityGraphExpansion: ConsentGrants query failed: $errMsg"
            $expansionSummaryList.Add([PSCustomObject]@{ Collector = 'ConsentGrants'; PrincipalCount = 0; EdgeCount = 0; Skipped = $true; SkipReason = "Query failed: $errMsg" })
        }
    } else {
        Write-Warning 'IdentityGraphExpansion: Get-MgOAuth2PermissionGrant not available; skipping ConsentGrants collector.'
        $expansionSummaryList.Add([PSCustomObject]@{ Collector = 'ConsentGrants'; PrincipalCount = 0; EdgeCount = 0; Skipped = $true; SkipReason = 'Microsoft.Graph.Identity.SignIns module not loaded' })
    }

    return $result
}
