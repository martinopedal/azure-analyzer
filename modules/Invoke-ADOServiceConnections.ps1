#Requires -Version 7.4
<#
.SYNOPSIS
    ADO service connection inventory scanner.
.DESCRIPTION
    Queries Azure DevOps REST API to inventory service connections across one or
    all projects in an organization. Returns the v1 wrapper contract with Source,
    Status, Message, and Findings. Each finding is an informational inventory
    record (Compliant=$true, Severity=Info) capturing connection type, auth
    scheme, and sharing status.
.PARAMETER AdoOrg
    Azure DevOps organization name (required).
.PARAMETER AdoProject
    Project name. When omitted, all projects in the organization are scanned.
.PARAMETER AdoPat
    Personal access token. Falls back to ADO_PAT_TOKEN, AZURE_DEVOPS_EXT_PAT,
    or AZ_DEVOPS_PAT environment variables when not provided.
#>
[CmdletBinding()]
param (
    [Parameter(Mandatory)]
    [Alias('AdoOrganization')]
    [ValidateNotNullOrEmpty()]
    [string] $AdoOrg,

    [string] $AdoProject,

    [Alias('AdoPatToken')]
    [string] $AdoPat
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Dot-source shared helpers
$sharedDir = Join-Path $PSScriptRoot 'shared'
. (Join-Path $sharedDir 'Retry.ps1')
. (Join-Path $sharedDir 'Sanitize.ps1')

# ---------------------------------------------------------------------------
# Resolve PAT
# ---------------------------------------------------------------------------
function Resolve-AdoPat {
    param ([string]$Explicit)
    if ($Explicit) { return $Explicit }
    if ($env:ADO_PAT_TOKEN) { return $env:ADO_PAT_TOKEN }
    if ($env:AZURE_DEVOPS_EXT_PAT) { return $env:AZURE_DEVOPS_EXT_PAT }
    if ($env:AZ_DEVOPS_PAT) { return $env:AZ_DEVOPS_PAT }
    return $null
}

$pat = Resolve-AdoPat -Explicit $AdoPat
if (-not $pat) {
    return [PSCustomObject]@{
        Source   = 'ado-connections'
        Status   = 'Skipped'
        Message  = 'No ADO PAT provided. Set -AdoPat/-AdoPatToken, ADO_PAT_TOKEN, AZURE_DEVOPS_EXT_PAT, or AZ_DEVOPS_PAT.'
        Findings = @()
    }
}

# Build auth header: Basic base64(:$pat)
$pair = ":$pat"
$bytes = [System.Text.Encoding]::UTF8.GetBytes($pair)
$base64 = [System.Convert]::ToBase64String($bytes)
$headers = @{ Authorization = "Basic $base64" }

# ---------------------------------------------------------------------------
# API helpers
# ---------------------------------------------------------------------------
function Invoke-AdoApi {
    param (
        [Parameter(Mandatory)]
        [string] $Uri,
        [Parameter(Mandatory)]
        [hashtable] $Headers
    )
    Invoke-WithRetry -ScriptBlock {
        $webResponse = Invoke-WebRequest -Uri $Uri -Headers $Headers -Method Get -ContentType 'application/json'
        $body = $webResponse.Content | ConvertFrom-Json
        $ct = $null
        if ($webResponse.Headers.ContainsKey('x-ms-continuationtoken')) {
            $headerValue = $webResponse.Headers['x-ms-continuationtoken']
            # Headers may return as string[] or string
            if ($headerValue -is [array]) {
                $ct = $headerValue[0]
            } else {
                $ct = $headerValue
            }
        }
        [PSCustomObject]@{
            Body              = $body
            ContinuationToken = $ct
        }
    }
}

# ---------------------------------------------------------------------------
# List projects (when no specific project given)
# ---------------------------------------------------------------------------
function Get-AdoProjects {
    param (
        [string] $Org,
        [hashtable] $Headers
    )
    $projects = [System.Collections.Generic.List[string]]::new()
    $continuationToken = $null
    $orgEnc = [uri]::EscapeDataString($Org)
    do {
        $uri = "https://dev.azure.com/$orgEnc/_apis/projects?api-version=7.1&`$top=100"
        if ($continuationToken) {
            $uri += "&continuationToken=$continuationToken"
        }
        $response = Invoke-AdoApi -Uri $uri -Headers $Headers
        $body = if ($response) { $response.Body } else { $null }
        if ($body -and $body.PSObject.Properties['value']) {
            foreach ($p in @($body.value)) {
                $projects.Add($p.name)
            }
        }
        $continuationToken = if ($response) { $response.ContinuationToken } else { $null }
    } while ($continuationToken)
    return @($projects)
}

# ---------------------------------------------------------------------------
# List service connections for a project
# ---------------------------------------------------------------------------
function Get-AdoServiceConnections {
    param (
        [string] $Org,
        [string] $Project,
        [hashtable] $Headers
    )
    $connections = [System.Collections.Generic.List[PSCustomObject]]::new()
    $continuationToken = $null
    $orgEnc     = [uri]::EscapeDataString($Org)
    $projectEnc = [uri]::EscapeDataString($Project)
    do {
        $uri = "https://dev.azure.com/$orgEnc/$projectEnc/_apis/serviceendpoint/endpoints?api-version=7.1&`$top=100"
        if ($continuationToken) {
            $uri += "&continuationToken=$continuationToken"
        }
        $response = Invoke-AdoApi -Uri $uri -Headers $Headers
        $body = if ($response) { $response.Body } else { $null }
        if ($body -and $body.PSObject.Properties['value']) {
            foreach ($c in @($body.value)) {
                $connections.Add($c)
            }
        }
        $continuationToken = if ($response) { $response.ContinuationToken } else { $null }
    } while ($continuationToken)
    return @($connections)
}

# ---------------------------------------------------------------------------
# Build a finding from a service connection
# ---------------------------------------------------------------------------
function ConvertTo-ConnectionFinding {
    param (
        [string] $Org,
        [string] $Project,
        [PSCustomObject] $Connection
    )
    $connName = if ($Connection.PSObject.Properties['name'] -and $Connection.name) {
        $Connection.name
    } else { 'unknown' }

    $connType = if ($Connection.PSObject.Properties['type'] -and $Connection.type) {
        $Connection.type
    } else { 'Unknown' }

    # Extract authorization scheme
    $authScheme = 'Unknown'
    if ($Connection.PSObject.Properties['authorization'] -and $Connection.authorization) {
        $auth = $Connection.authorization
        if ($auth.PSObject.Properties['scheme'] -and $auth.scheme) {
            $authScheme = $auth.scheme
        }
    }

    $normalizedAuthScheme = switch ($authScheme) {
        'Token'                  { 'PAT' }
        'ManagedServiceIdentity' { 'ManagedIdentity' }
        default                  { $authScheme }
    }

    function Get-ConnectionAuthMechanism {
        param (
            [string] $Scheme,
            [PSCustomObject] $ConnectionObject
        )

        switch ($Scheme) {
            'Token' { return 'PAT' }
            'WorkloadIdentityFederation' { return 'WorkloadIdentityFederation' }
            'ManagedServiceIdentity' { return 'ManagedIdentity' }
            'ManagedIdentity' { return 'ManagedIdentity' }
            'ServicePrincipal' {
                $parameters = $null
                if ($ConnectionObject -and
                    $ConnectionObject.PSObject.Properties['authorization'] -and
                    $ConnectionObject.authorization -and
                    $ConnectionObject.authorization.PSObject.Properties['parameters']) {
                    $parameters = $ConnectionObject.authorization.parameters
                }

                if ($parameters) {
                    $parameterMap = @{}
                    foreach ($p in $parameters.PSObject.Properties) {
                        $parameterMap[$p.Name.ToLowerInvariant()] = [string]$p.Value
                    }

                    if ($parameterMap.ContainsKey('authenticationtype') -and
                        $parameterMap['authenticationtype'].ToLowerInvariant().Contains('certificate')) {
                        return 'Certificate'
                    }
                    if ($parameterMap.ContainsKey('serviceprincipalcertificate') -or
                        $parameterMap.ContainsKey('clientcertificate')) {
                        return 'Certificate'
                    }
                    if ($parameterMap.ContainsKey('serviceprincipalkey') -or
                        $parameterMap.ContainsKey('clientsecret')) {
                        return 'ClientSecret'
                    }
                }

                return 'ClientSecret'
            }
            default { return $Scheme }
        }
    }

    $authMechanism = Get-ConnectionAuthMechanism -Scheme $authScheme -ConnectionObject $Connection

    # isShared flag
    $isShared = $false
    if ($Connection.PSObject.Properties['isShared']) {
        $isShared = [bool]$Connection.isShared
    }

    $connId = if ($Connection.PSObject.Properties['id'] -and $Connection.id) {
        $Connection.id
    } else { '' }

    $resourceId = "ado://$($Org.ToLowerInvariant())/$($Project.ToLowerInvariant())/serviceconnection/$($connName.ToLowerInvariant())"
    $orgEnc = [uri]::EscapeDataString($Org)
    $projectEnc = [uri]::EscapeDataString($Project)
    $connIdEnc = [uri]::EscapeDataString($connId)
    $deepLinkUrl = "https://dev.azure.com/$orgEnc/$projectEnc/_settings/adminservices?resourceId=$connIdEnc"
    $connectionApiUri = "https://dev.azure.com/$orgEnc/$projectEnc/_apis/serviceendpoint/endpoints/${connIdEnc}?api-version=7.1"
    $auditLogUri = "https://dev.azure.com/$orgEnc/_settings/audit"

    $impact = 'Medium'
    $authSchemeForImpact = $normalizedAuthScheme.ToLowerInvariant()
    $authMechanismForImpact = $authMechanism.ToLowerInvariant()
    if ($isShared -and (($authSchemeForImpact -eq 'pat') -or ($authMechanismForImpact -eq 'clientsecret'))) {
        $impact = 'High'
    } elseif ((-not $isShared -and $authMechanismForImpact -eq 'clientsecret') -or
        ($isShared -and $authSchemeForImpact -eq 'managedidentity')) {
        $impact = 'Medium'
    } elseif ((@('workloadidentityfederation', 'managedidentity') -contains $authMechanismForImpact) -and (-not $isShared)) {
        $impact = 'Low'
    }

    $effort = if ($isShared) { 'Medium' } else { 'Low' }
    $sharingTag = if ($isShared) { 'Connection-Shared' } else { 'Connection-Scoped' }
    $baselineTags = @(
        "AuthScheme-$normalizedAuthScheme",
        "Auth-$authMechanism",
        $sharingTag
    )
    $entityRefs = @(
        "ado-org:$Org",
        "ado-project:$Org/$Project",
        "ado-service-connection:$Org/$Project/$connId"
    )
    $remediationText = if ($isShared) {
        'Migrate the shared service connection to workload identity federation and coordinate with dependent teams.'
    } else {
        'Migrate this service connection to workload identity federation and remove long-lived credentials.'
    }
    $remediationSnippets = @(
        @{
            language = 'bash'
            content  = "az devops service-endpoint update --id `"$connId`" --organization `"https://dev.azure.com/$Org`" --project `"$Project`""
        }
    )

    [PSCustomObject]@{
        Source        = 'ado-connections'
        ResourceId    = $resourceId
        Category      = 'Service Connection'
        Title         = "$connType connection: $connName"
        Compliant     = $true
        Severity      = 'Info'
        Detail        = "Type=$connType; AuthScheme=$normalizedAuthScheme; AuthMechanism=$authMechanism; IsShared=$isShared"
        Remediation   = $remediationText
        LearnMoreUrl  = 'https://learn.microsoft.com/en-us/azure/devops/pipelines/library/service-endpoints'
        SchemaVersion = '1.0'
        Pillar        = 'Security'
        Impact        = $impact
        Effort        = $effort
        DeepLinkUrl   = $deepLinkUrl
        RemediationSnippets = $remediationSnippets
        EvidenceUris  = @($connectionApiUri, $auditLogUri)
        BaselineTags  = $baselineTags
        EntityRefs    = $entityRefs
        ToolVersion   = 'ado-rest-api-7.1'
        AdoOrg        = $Org
        AdoProject    = $Project
        ConnectionId  = $connId
        ConnectionType = $connType
        AuthScheme    = $normalizedAuthScheme
        AuthMechanism = $authMechanism
        IsShared      = $isShared
    }
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
try {
    $projects = @()
    if ($AdoProject) {
        $projects = @($AdoProject)
    } else {
        $projects = @(Get-AdoProjects -Org $AdoOrg -Headers $headers)
        if ($projects.Count -eq 0) {
            return [PSCustomObject]@{
                Source   = 'ado-connections'
                Status   = 'Success'
                Message  = "No projects found in organization '$AdoOrg'."
                Findings = @()
            }
        }
    }

    $findings = [System.Collections.Generic.List[PSCustomObject]]::new()
    $failedProjects = [System.Collections.Generic.List[string]]::new()

    foreach ($proj in $projects) {
        try {
            $connections = Get-AdoServiceConnections -Org $AdoOrg -Project $proj -Headers $headers
            foreach ($conn in $connections) {
                $finding = ConvertTo-ConnectionFinding -Org $AdoOrg -Project $proj -Connection $conn
                $findings.Add($finding)
            }
        } catch {
            Write-Warning (Remove-Credentials "Failed to scan project '$proj': $_")
            $failedProjects.Add($proj)
        }
    }

    $status = if ($failedProjects.Count -gt 0 -and $failedProjects.Count -lt $projects.Count) {
        'PartialSuccess'
    } elseif ($failedProjects.Count -ge $projects.Count -and $projects.Count -gt 0) {
        'Failed'
    } else {
        'Success'
    }
    $message = "Scanned $($projects.Count) project(s), found $($findings.Count) service connection(s)."
    if ($failedProjects.Count -gt 0) {
        $message += " Failed projects: $($failedProjects -join ', ')."
    }

    return [PSCustomObject]@{
        Source   = 'ado-connections'
        Status   = $status
        Message  = $message
        Findings = @($findings)
    }
} catch {
    $errMsg = Remove-Credentials "$_"
    Write-Warning "ADO service connection scan failed: $errMsg"
    return [PSCustomObject]@{
        Source   = 'ado-connections'
        Status   = 'Failed'
        Message  = $errMsg
        Findings = @()
    }
}
