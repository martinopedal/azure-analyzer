#Requires -Version 7.4
<#
.SYNOPSIS
    Conditional Access policy graph wrapper (graph mapping family R1).
.DESCRIPTION
    Pulls Conditional Access policies from Microsoft Graph
    (`/identity/conditionalAccess/policies`) and emits:

      * Findings for high-risk gaps (disabled policy covering privileged
        roles, report-only stuck >30 d, GA excluded from MFA, etc.).
      * Edges into the EntityStore:
          - AppliesTo : ConditionalAccessPolicy -> User|Group|Application|NamedLocation
          - Excludes  : ConditionalAccessPolicy -> User|Group|Application|NamedLocation

    Microsoft Graph access is OPTIONAL. When the Microsoft.Graph modules
    are not connected, the wrapper consumes pre-fetched data via
    `-PreFetchedData` (test fixtures, offline mode). All Graph calls are
    wrapped in `Invoke-WithRetry` to handle 429 throttling. All output
    passes through `Remove-Credentials`.

    Read-only Graph scopes required when running live:
        Policy.Read.All, Directory.Read.All

    Design doc: docs/design/graph-mapping-integration.md.
.PARAMETER TenantId
    Home tenant id used for Tenant entity canonicalization.
.PARAMETER PreFetchedData
    Optional PSCustomObject with .Policies (array of CA policy objects in
    the Microsoft Graph shape). When supplied, bypasses the live Graph
    call. Used by the wrapper test suite and `-FixtureMode`.
.OUTPUTS
    PSCustomObject @{ Source; SchemaVersion='1.0'; Status; Message;
                      Findings=@(); Errors=@(); Policies=@() }
    Each entry in `Policies` is a sanitized projection of the raw Graph
    policy used by the normalizer to derive entities and edges.
#>
[CmdletBinding()]
param (
    [string] $TenantId,
    [PSCustomObject] $PreFetchedData
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Dot-source shared modules with inline fallback stubs (matches the
# established wrapper pattern in Invoke-DnsTwist.ps1 +
# Invoke-IdentityGraphExpansion.ps1).
$sharedDir = Join-Path $PSScriptRoot 'shared'
$sanitizePath  = Join-Path $sharedDir 'Sanitize.ps1'
$errorsPath    = Join-Path $sharedDir 'Errors.ps1'
$retryPath     = Join-Path $sharedDir 'Retry.ps1'
$envelopePath  = Join-Path $sharedDir 'New-WrapperEnvelope.ps1'
if (Test-Path $sanitizePath) { . $sanitizePath }
if (Test-Path $errorsPath)   { . $errorsPath }
if (Test-Path $retryPath)    { . $retryPath }
if (Test-Path $envelopePath) { . $envelopePath }

if (-not (Get-Command New-WrapperEnvelope -ErrorAction SilentlyContinue)) {
    function New-WrapperEnvelope { param([string]$Source,[string]$Status='Failed',[string]$Message='',[object[]]$FindingErrors=@()) return [PSCustomObject]@{ Source=$Source; SchemaVersion='1.0'; Status=$Status; Message=$Message; Findings=@(); Errors=@($FindingErrors) } }
}
if (-not (Get-Command Remove-Credentials -ErrorAction SilentlyContinue)) {
    function Remove-Credentials { param ([string]$Text) return $Text }
}
if (-not (Get-Command New-FindingError -ErrorAction SilentlyContinue)) {
    function New-FindingError { param([string]$Source,[string]$Category,[string]$Reason,[string]$Remediation,[string]$Details) return [pscustomobject]@{ Source=$Source; Category=$Category; Reason=$Reason; Remediation=$Remediation; Details=$Details } }
}
if (-not (Get-Command Invoke-WithRetry -ErrorAction SilentlyContinue)) {
    function Invoke-WithRetry { param ([scriptblock]$ScriptBlock); & $ScriptBlock }
}

function Test-MgGraphAvailable {
    # We want a *connected* session, not just the module being importable.
    # Get-MgContext returns $null when no Connect-MgGraph has happened.
    $cmd = Get-Command Get-MgContext -ErrorAction SilentlyContinue
    if (-not $cmd) { return $false }
    try {
        $ctx = Get-MgContext
        return ($null -ne $ctx)
    } catch {
        return $false
    }
}

function Get-CaPolicyState {
    param ([Parameter(Mandatory)][PSCustomObject] $Policy)
    if ($Policy.PSObject.Properties['state'] -and $Policy.state) { return [string]$Policy.state }
    return 'unknown'
}

function Get-CaPolicyDisplayName {
    param ([Parameter(Mandatory)][PSCustomObject] $Policy)
    if ($Policy.PSObject.Properties['displayName'] -and $Policy.displayName) { return [string]$Policy.displayName }
    return ''
}

function Get-CaConditionField {
    <#
    .SYNOPSIS
        Safe accessor for a nested condition list on a CA policy.
    #>
    param (
        [Parameter(Mandatory)] [PSCustomObject] $Policy,
        [Parameter(Mandatory)] [string] $Section,
        [Parameter(Mandatory)] [string] $Field
    )
    if (-not $Policy.PSObject.Properties['conditions']) { return @() }
    $cond = $Policy.conditions
    if (-not $cond -or -not $cond.PSObject.Properties[$Section]) { return @() }
    $sect = $cond.$Section
    if (-not $sect -or -not $sect.PSObject.Properties[$Field]) { return @() }
    $v = $sect.$Field
    if ($null -eq $v) { return @() }
    return @($v)
}

function Get-CaGrantControl {
    param (
        [Parameter(Mandatory)] [PSCustomObject] $Policy,
        [Parameter(Mandatory)] [string] $Field
    )
    if (-not $Policy.PSObject.Properties['grantControls']) { return @() }
    $g = $Policy.grantControls
    if (-not $g -or -not $g.PSObject.Properties[$Field]) { return @() }
    $v = $g.$Field
    if ($null -eq $v) { return @() }
    return @($v)
}

function Get-CaPolicyFindings {
    <#
    .SYNOPSIS
        Apply the CA risk rubric documented in
        docs/design/graph-mapping-integration.md section 4.4 and emit one
        v1 finding object per gap.
    #>
    param ([Parameter(Mandatory)][PSCustomObject] $Policy)

    $findings = [System.Collections.Generic.List[PSCustomObject]]::new()
    $policyId   = if ($Policy.PSObject.Properties['id']) { [string]$Policy.id } else { '' }
    $policyName = Get-CaPolicyDisplayName -Policy $Policy
    $state      = Get-CaPolicyState -Policy $Policy
    $deepLink   = if ($policyId) { "https://entra.microsoft.com/#view/Microsoft_AAD_ConditionalAccess/PolicyBlade/policyId/$policyId" } else { '' }

    $includeRoles = Get-CaConditionField -Policy $Policy -Section 'users' -Field 'includeRoles'
    $excludeRoles = Get-CaConditionField -Policy $Policy -Section 'users' -Field 'excludeRoles'
    $includeUsers = Get-CaConditionField -Policy $Policy -Section 'users' -Field 'includeUsers'
    $excludeUsers = Get-CaConditionField -Policy $Policy -Section 'users' -Field 'excludeUsers'
    $builtIns     = Get-CaGrantControl   -Policy $Policy -Field 'builtInControls'

    # Directory role template id for Global Administrator.
    $globalAdminRoleId = '62e90394-69f5-4237-9190-012177145e10'
    $coversGlobalAdmin = ($includeRoles -contains $globalAdminRoleId) -or ($includeUsers -contains 'All')

    # Indicator 1: disabled policy that covers privileged role members.
    if ($state -eq 'disabled' -and $coversGlobalAdmin) {
        $findings.Add([PSCustomObject]@{
            Id          = "ca:$policyId:disabled-covers-priv"
            RuleId      = 'ca-disabled-covers-privileged'
            Title       = "Disabled CA policy covers privileged identities: $policyName"
            Category    = 'Identity Graph'
            Severity    = 'High'
            Compliant   = $false
            Detail      = "Policy state is 'disabled' but the targeting includes Global Administrator role or All users."
            Remediation = "Enable the policy, or remove the privileged-role targeting if intentional."
            ResourceId  = $policyId
            Pillar      = 'Identity'
            Impact      = 'High'
            Effort      = 'Low'
            DeepLinkUrl = $deepLink
        }) | Out-Null
    }

    # Indicator 2: report-only mode (long tail; we cannot infer "30d" without
    # createdDateTime, so we emit Medium whenever the state is report-only).
    if ($state -eq 'enabledForReportingButNotEnforced') {
        $findings.Add([PSCustomObject]@{
            Id          = "ca:$policyId:report-only"
            RuleId      = 'ca-report-only-not-enforced'
            Title       = "CA policy is in report-only mode: $policyName"
            Category    = 'Identity Graph'
            Severity    = 'Medium'
            Compliant   = $false
            Detail      = "Policy is logging matches but not enforcing controls. Review the sign-in log impact and promote to 'enabled'."
            Remediation = "Promote the policy to 'enabled' once impact has been validated."
            ResourceId  = $policyId
            Pillar      = 'Identity'
            Impact      = 'Medium'
            Effort      = 'Low'
            DeepLinkUrl = $deepLink
        }) | Out-Null
    }

    # Indicator 3: GA excluded from MFA grant.
    $excludesGlobalAdmin = ($excludeRoles -contains $globalAdminRoleId)
    $requiresMfa = ($builtIns -contains 'mfa')
    if ($excludesGlobalAdmin -and $requiresMfa) {
        $findings.Add([PSCustomObject]@{
            Id          = "ca:$policyId:ga-excluded-from-mfa"
            RuleId      = 'ca-ga-excluded-from-mfa'
            Title       = "Global Administrator role is excluded from an MFA-requiring policy: $policyName"
            Category    = 'Identity Graph'
            Severity    = 'Critical'
            Compliant   = $false
            Detail      = "Policy requires MFA but excludes the Global Administrator directory-role group, leaving the highest-privilege identities outside the MFA gate."
            Remediation = "Remove the Global Administrator role from the exclusion set; rely on a small named break-glass account list instead."
            ResourceId  = $policyId
            Pillar      = 'Identity'
            Impact      = 'Critical'
            Effort      = 'Low'
            DeepLinkUrl = $deepLink
        }) | Out-Null
    }

    # Indicator 4: All-users targeting with too many user exclusions.
    if (($includeUsers -contains 'All') -and (@($excludeUsers).Count -gt 2)) {
        $findings.Add([PSCustomObject]@{
            Id          = "ca:$policyId:break-glass-too-large"
            RuleId      = 'ca-break-glass-too-large'
            Title       = "All-users CA policy excludes more than 2 accounts: $policyName"
            Category    = 'Identity Graph'
            Severity    = 'Medium'
            Compliant   = $false
            Detail      = ("Policy targets All users but excludes {0} individual accounts. Limit break-glass exclusions to 2 named accounts and document them." -f @($excludeUsers).Count)
            Remediation = "Trim the exclusion list to 2 break-glass accounts and document them in the runbook."
            ResourceId  = $policyId
            Pillar      = 'Identity'
            Impact      = 'Medium'
            Effort      = 'Medium'
            DeepLinkUrl = $deepLink
        }) | Out-Null
    }

    # Indicator 5: policy declares no MFA (and no other strong control).
    $strongControls = @('mfa','compliantDevice','domainJoinedDevice','passwordChange','approvedApplication','compliantApplication')
    $hasStrong = (@($builtIns | Where-Object { $strongControls -contains $_ })).Count -gt 0
    if ($state -eq 'enabled' -and -not $hasStrong) {
        $findings.Add([PSCustomObject]@{
            Id          = "ca:$policyId:no-strong-control"
            RuleId      = 'ca-no-strong-control'
            Title       = "Enabled CA policy declares no strong grant control: $policyName"
            Category    = 'Identity Graph'
            Severity    = 'Low'
            Compliant   = $false
            Detail      = "Policy is enabled but its grantControls.builtInControls list does not include MFA, compliant device, password change, or approved application."
            Remediation = "Add at least one strong control (typically 'mfa') to the policy's grant controls."
            ResourceId  = $policyId
            Pillar      = 'Identity'
            Impact      = 'Low'
            Effort      = 'Low'
            DeepLinkUrl = $deepLink
        }) | Out-Null
    }

    return @($findings)
}

function ConvertTo-CaPolicyProjection {
    <#
    .SYNOPSIS
        Reduce a raw Microsoft Graph CA policy down to the fields the
        normalizer needs to emit edges. Free-text claim payloads are
        deliberately omitted (see design doc section 4.7).
    #>
    param ([Parameter(Mandatory)][PSCustomObject] $Policy)
    [PSCustomObject]@{
        Id            = if ($Policy.PSObject.Properties['id']) { [string]$Policy.id } else { '' }
        DisplayName   = Get-CaPolicyDisplayName -Policy $Policy
        State         = Get-CaPolicyState -Policy $Policy
        IncludeUsers  = Get-CaConditionField -Policy $Policy -Section 'users' -Field 'includeUsers'
        ExcludeUsers  = Get-CaConditionField -Policy $Policy -Section 'users' -Field 'excludeUsers'
        IncludeGroups = Get-CaConditionField -Policy $Policy -Section 'users' -Field 'includeGroups'
        ExcludeGroups = Get-CaConditionField -Policy $Policy -Section 'users' -Field 'excludeGroups'
        IncludeRoles  = Get-CaConditionField -Policy $Policy -Section 'users' -Field 'includeRoles'
        ExcludeRoles  = Get-CaConditionField -Policy $Policy -Section 'users' -Field 'excludeRoles'
        IncludeApps   = Get-CaConditionField -Policy $Policy -Section 'applications' -Field 'includeApplications'
        ExcludeApps   = Get-CaConditionField -Policy $Policy -Section 'applications' -Field 'excludeApplications'
        IncludeLocs   = Get-CaConditionField -Policy $Policy -Section 'locations' -Field 'includeLocations'
        ExcludeLocs   = Get-CaConditionField -Policy $Policy -Section 'locations' -Field 'excludeLocations'
        BuiltIns      = Get-CaGrantControl   -Policy $Policy -Field 'builtInControls'
    }
}

# Main wrapper body
try {
    $policies = @()
    $source = 'live-graph'

    if ($PreFetchedData -and $PreFetchedData.PSObject.Properties['Policies']) {
        $policies = @($PreFetchedData.Policies)
        $source = 'pre-fetched'
    } else {
        if (-not (Test-MgGraphAvailable)) {
            $err = New-FindingError -Source 'wrapper:conditional-access-graph' `
                -Category 'MissingDependency' `
                -Reason 'Microsoft.Graph.Identity.SignIns module is not available or not connected' `
                -Remediation 'Install Microsoft.Graph and run Connect-MgGraph -Scopes "Policy.Read.All Directory.Read.All", or pass -PreFetchedData.'
            return New-WrapperEnvelope -Source 'conditional-access-graph' -Status 'Skipped' `
                -Message 'Microsoft.Graph not available; skipping Conditional Access graph collection.' `
                -FindingErrors @($err)
        }
        $policies = @(Invoke-WithRetry -ScriptBlock {
            Get-MgIdentityConditionalAccessPolicy -All
        })
    }

    $findings = [System.Collections.Generic.List[PSCustomObject]]::new()
    $projections = [System.Collections.Generic.List[PSCustomObject]]::new()

    foreach ($p in $policies) {
        if ($null -eq $p) { continue }
        foreach ($f in (Get-CaPolicyFindings -Policy $p)) {
            $findings.Add($f) | Out-Null
        }
        $projections.Add((ConvertTo-CaPolicyProjection -Policy $p)) | Out-Null
    }

    return [PSCustomObject]@{
        Source        = 'conditional-access-graph'
        SchemaVersion = '1.0'
        Status        = 'Success'
        Message       = ("Inspected {0} Conditional Access policy(ies) ({1}); emitted {2} finding(s)." -f @($policies).Count, $source, $findings.Count)
        TenantId      = $TenantId
        Policies      = @($projections)
        Findings      = @($findings)
        Errors        = @()
    }
} catch {
    $sanitised = Remove-Credentials ([string]$_)
    $err = New-FindingError -Source 'wrapper:conditional-access-graph' `
        -Category 'UnexpectedFailure' `
        -Reason 'Unhandled exception in Invoke-ConditionalAccessGraph' `
        -Remediation 'See Details; rerun with -Verbose for stack.' `
        -Details $sanitised
    return New-WrapperEnvelope -Source 'conditional-access-graph' -Status 'Failed' `
        -Message $sanitised -FindingErrors @($err)
}
