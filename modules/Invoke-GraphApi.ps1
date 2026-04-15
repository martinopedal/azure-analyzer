#Requires -Version 7.0
<#
.SYNOPSIS
    Microsoft Graph API module for Entra ID security posture checks.
.DESCRIPTION
    Runs five Entra ID / Microsoft Graph checks:
      1. Conditional Access policy coverage
      2. PIM permanent Global Administrator assignments
      3. MFA registration campaign enablement
      4. Security defaults enforcement
      5. Guest access restrictions (authorization policy)
    Gracefully degrades on missing permissions (emits non-compliant finding).
.PARAMETER TenantId
    Azure tenant ID. Used for scope context.
.PARAMETER AccessToken
    Optional Bearer token for Microsoft Graph. If omitted, obtained via Get-AzAccessToken.
.EXAMPLE
    .\Invoke-GraphApi.ps1 -TenantId "00000000-0000-0000-0000-000000000000"
#>
[CmdletBinding()]
param (
    [Parameter(Mandatory)]
    [string] $TenantId,
    [string] $AccessToken
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$findings = [System.Collections.Generic.List[PSCustomObject]]::new()

# --- Resolve Bearer token ---
$token = $AccessToken
if ([string]::IsNullOrEmpty($token)) {
    try {
        $tokenObj = Get-AzAccessToken -ResourceUrl 'https://graph.microsoft.com/' -ErrorAction Stop
        $token = $tokenObj.Token
    } catch {
        Write-Warning "Invoke-GraphApi: Could not obtain Graph token via Get-AzAccessToken: $_"
        $findings.Add([PSCustomObject]@{
            Id          = [guid]::NewGuid().ToString()
            Source      = 'graph-api'
            Category    = 'Identity'
            Title       = 'Graph API token unavailable'
            Severity    = 'High'
            Compliant   = $false
            Detail      = "Could not obtain Microsoft Graph access token. Ensure Az context is authenticated: $_"
            Remediation = 'Run Connect-AzAccount before executing this module.'
        })
        return [PSCustomObject]@{ Source = 'graph-api'; Findings = $findings.ToArray() }
    }
}

$headers = @{ Authorization = "Bearer $token" }

# Helper: call Graph and return the parsed response, or $null on error with a warning
function Invoke-GraphRequest {
    param ([string]$Uri, [string]$CheckName)
    try {
        return Invoke-RestMethod -Uri $Uri -Headers $headers -ErrorAction Stop
    } catch {
        $statusCode = $_.Exception.Response?.StatusCode?.value__
        if ($statusCode -eq 403) {
            Write-Warning "Invoke-GraphApi [$CheckName]: 403 Forbidden — insufficient Graph permissions."
            return $null
        }
        Write-Warning "Invoke-GraphApi [$CheckName]: API call failed ($statusCode): $_"
        return $null
    }
}

# -------------------------------------------------------------------------
# Check 1 — Conditional Access policy coverage
# -------------------------------------------------------------------------
$caResp = Invoke-GraphRequest -Uri 'https://graph.microsoft.com/v1.0/identity/conditionalAccess/policies' -CheckName 'ConditionalAccess'

$activeCaPoliciesExist = $false   # used by check 4

if ($null -eq $caResp) {
    $findings.Add([PSCustomObject]@{
        Id          = [guid]::NewGuid().ToString()
        Source      = 'graph-api'
        Category    = 'Identity'
        Title       = 'Conditional Access policy coverage — check failed'
        Severity    = 'High'
        Compliant   = $false
        Detail      = 'Insufficient permissions to read Conditional Access policies. Requires Policy.Read.All.'
        Remediation = 'Grant the service principal the Policy.Read.All Microsoft Graph API permission.'
    })
} else {
    $policies = $null
    if (-not $null -eq $caResp.PSObject.Properties['value']) {
        $policies = $caResp.value
    }

    $policyCount = if ($null -ne $policies) { @($policies).Count } else { 0 }
    $hasAllUsersPolicy = $false
    if ($policyCount -gt 0) {
        $activeCaPoliciesExist = $true
        foreach ($policy in $policies) {
            $includeUsers = $policy.PSObject.Properties['conditions']?.Value?.PSObject.Properties['users']?.Value?.PSObject.Properties['includeUsers']?.Value
            if ($null -ne $includeUsers -and @($includeUsers) -contains 'All') {
                $hasAllUsersPolicy = $true
                break
            }
        }
    }

    $compliant = $policyCount -gt 0 -and $hasAllUsersPolicy
    $findings.Add([PSCustomObject]@{
        Id          = [guid]::NewGuid().ToString()
        Source      = 'graph-api'
        Category    = 'Identity'
        Title       = 'Conditional Access — all-users policy present'
        Severity    = 'High'
        Compliant   = $compliant
        Detail      = "Found $policyCount CA policy/policies. At least one targeting all users: $hasAllUsersPolicy."
        Remediation = 'https://learn.microsoft.com/en-us/entra/identity/conditional-access/overview'
    })
}

# -------------------------------------------------------------------------
# Check 2 — PIM permanent Global Administrator assignments
# -------------------------------------------------------------------------
$globalAdminRoleId = '62e90394-69f5-4237-9190-012177145e10'
$pimUri = "https://graph.microsoft.com/v1.0/roleManagement/directory/roleAssignments?`$filter=roleDefinitionId eq '$globalAdminRoleId'"
$pimResp = Invoke-GraphRequest -Uri $pimUri -CheckName 'PIMPermanentGA'

if ($null -eq $pimResp) {
    $findings.Add([PSCustomObject]@{
        Id          = [guid]::NewGuid().ToString()
        Source      = 'graph-api'
        Category    = 'Identity'
        Title       = 'PIM permanent Global Administrator assignments — check failed'
        Severity    = 'High'
        Compliant   = $false
        Detail      = 'Insufficient permissions to read role assignments. Requires RoleManagement.Read.Directory.'
        Remediation = 'Grant the service principal the RoleManagement.Read.Directory Microsoft Graph API permission.'
    })
} else {
    $assignments = $null
    if (-not $null -eq $pimResp.PSObject.Properties['value']) {
        $assignments = $pimResp.value
    }
    $assignmentCount = if ($null -ne $assignments) { @($assignments).Count } else { 0 }
    $compliant = $assignmentCount -eq 0
    $findings.Add([PSCustomObject]@{
        Id          = [guid]::NewGuid().ToString()
        Source      = 'graph-api'
        Category    = 'Identity'
        Title       = 'PIM — no permanent Global Administrator assignments'
        Severity    = 'High'
        Compliant   = $compliant
        Detail      = "Found $assignmentCount permanent (non-eligible) Global Administrator assignment(s). Use PIM eligible assignments instead."
        Remediation = 'https://learn.microsoft.com/en-us/entra/id-governance/privileged-identity-management/pim-configure'
    })
}

# -------------------------------------------------------------------------
# Check 3 — MFA registration campaign (combined security info registration)
# -------------------------------------------------------------------------
$mfaResp = Invoke-GraphRequest -Uri 'https://graph.microsoft.com/v1.0/policies/authenticationMethodsPolicy' -CheckName 'MFARegistration'

if ($null -eq $mfaResp) {
    $findings.Add([PSCustomObject]@{
        Id          = [guid]::NewGuid().ToString()
        Source      = 'graph-api'
        Category    = 'Identity'
        Title       = 'MFA registration campaign enablement — check failed'
        Severity    = 'High'
        Compliant   = $false
        Detail      = 'Insufficient permissions to read authentication methods policy. Requires Policy.Read.All.'
        Remediation = 'Grant the service principal the Policy.Read.All Microsoft Graph API permission.'
    })
} else {
    $campaignState = $mfaResp.PSObject.Properties['registrationEnforcement']?.Value?.PSObject.Properties['authenticationMethodsRegistrationCampaign']?.Value?.PSObject.Properties['state']?.Value
    $compliant = $campaignState -eq 'enabled'
    $findings.Add([PSCustomObject]@{
        Id          = [guid]::NewGuid().ToString()
        Source      = 'graph-api'
        Category    = 'Identity'
        Title       = 'MFA registration campaign enabled'
        Severity    = 'Medium'
        Compliant   = $compliant
        Detail      = "Combined security info registration campaign state: '$campaignState'. Expected: 'enabled'."
        Remediation = 'https://learn.microsoft.com/en-us/entra/identity/authentication/howto-registration-mfa-sspr-combined'
    })
}

# -------------------------------------------------------------------------
# Check 4 — Security defaults (OR active CA policies is acceptable)
# -------------------------------------------------------------------------
$secDefaultsResp = Invoke-GraphRequest -Uri 'https://graph.microsoft.com/v1.0/policies/identitySecurityDefaultsEnforcementPolicy' -CheckName 'SecurityDefaults'

if ($null -eq $secDefaultsResp) {
    $findings.Add([PSCustomObject]@{
        Id          = [guid]::NewGuid().ToString()
        Source      = 'graph-api'
        Category    = 'Identity'
        Title       = 'Security defaults enforcement — check failed'
        Severity    = 'High'
        Compliant   = $false
        Detail      = 'Insufficient permissions to read security defaults policy. Requires Policy.Read.All.'
        Remediation = 'Grant the service principal the Policy.Read.All Microsoft Graph API permission.'
    })
} else {
    $isEnabledProp = $secDefaultsResp.PSObject.Properties['isEnabled']
    $secDefaultsEnabled = $null -ne $isEnabledProp -and $isEnabledProp.Value -eq $true
    $compliant = $secDefaultsEnabled -or $activeCaPoliciesExist
    $detail = if ($secDefaultsEnabled) {
        'Security defaults are enabled.'
    } elseif ($activeCaPoliciesExist) {
        'Security defaults are disabled but active Conditional Access policies are present (acceptable).'
    } else {
        'Security defaults are disabled and no active Conditional Access policies were found.'
    }
    $findings.Add([PSCustomObject]@{
        Id          = [guid]::NewGuid().ToString()
        Source      = 'graph-api'
        Category    = 'Identity'
        Title       = 'Security defaults or Conditional Access policies enforced'
        Severity    = 'High'
        Compliant   = $compliant
        Detail      = $detail
        Remediation = 'https://learn.microsoft.com/en-us/entra/fundamentals/security-defaults'
    })
}

# -------------------------------------------------------------------------
# Check 5 — Guest access restrictions (authorization policy)
# -------------------------------------------------------------------------
$authPolicyResp = Invoke-GraphRequest -Uri 'https://graph.microsoft.com/v1.0/policies/authorizationPolicy' -CheckName 'GuestAccessRestrictions'

if ($null -eq $authPolicyResp) {
    $findings.Add([PSCustomObject]@{
        Id          = [guid]::NewGuid().ToString()
        Source      = 'graph-api'
        Category    = 'Identity'
        Title       = 'Guest access restrictions — check failed'
        Severity    = 'Medium'
        Compliant   = $false
        Detail      = 'Insufficient permissions to read authorization policy. Requires Policy.Read.All.'
        Remediation = 'Grant the service principal the Policy.Read.All Microsoft Graph API permission.'
    })
} else {
    # authorizationPolicy may be returned as an array or a single object
    $policy = $authPolicyResp
    $valueArr = $authPolicyResp.PSObject.Properties['value']
    if ($null -ne $valueArr -and $null -ne $valueArr.Value) {
        $arr = @($valueArr.Value)
        if ($arr.Count -gt 0) { $policy = $arr[0] }
    }

    $allowInvitesFrom = $policy.PSObject.Properties['allowInvitesFrom']?.Value
    $restrictedValues = @('adminsAndGuestInviters', 'adminsGuestInvitersAndAllMembers')
    $compliant = $null -ne $allowInvitesFrom -and $restrictedValues -contains $allowInvitesFrom
    $findings.Add([PSCustomObject]@{
        Id          = [guid]::NewGuid().ToString()
        Source      = 'graph-api'
        Category    = 'Identity'
        Title       = 'Guest invitations restricted to admins'
        Severity    = 'Medium'
        Compliant   = $compliant
        Detail      = "allowInvitesFrom = '$allowInvitesFrom'. Compliant values: 'adminsAndGuestInviters', 'adminsGuestInvitersAndAllMembers'."
        Remediation = 'https://learn.microsoft.com/en-us/entra/external-id/external-collaboration-settings-configure'
    })
}

return [PSCustomObject]@{ Source = 'graph-api'; Findings = $findings.ToArray() }
