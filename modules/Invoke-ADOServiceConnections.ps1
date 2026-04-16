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
    Personal access token. Falls back to AZURE_DEVOPS_EXT_PAT or AZ_DEVOPS_PAT
    environment variables when not provided.
#>
[CmdletBinding()]
param (
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string] $AdoOrg,

    [string] $AdoProject,

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
    if ($env:AZURE_DEVOPS_EXT_PAT) { return $env:AZURE_DEVOPS_EXT_PAT }
    if ($env:AZ_DEVOPS_PAT) { return $env:AZ_DEVOPS_PAT }
    return $null
}

$pat = Resolve-AdoPat -Explicit $AdoPat
if (-not $pat) {
    return [PSCustomObject]@{
        Source   = 'ado-connections'
        Status   = 'Skipped'
        Message  = 'No ADO PAT provided. Set -AdoPat, AZURE_DEVOPS_EXT_PAT, or AZ_DEVOPS_PAT.'
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
        Invoke-RestMethod -Uri $Uri -Headers $Headers -Method Get -ContentType 'application/json'
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
    do {
        $uri = "https://dev.azure.com/$Org/_apis/projects?api-version=7.1&`$top=100"
        if ($continuationToken) {
            $uri += "&continuationToken=$continuationToken"
        }
        $response = Invoke-AdoApi -Uri $uri -Headers $Headers
        if ($response -and $response.PSObject.Properties['value']) {
            foreach ($p in @($response.value)) {
                $projects.Add($p.name)
            }
        }
        # ADO returns continuation token in the response header; Invoke-RestMethod
        # doesn't expose headers easily, so check the response body count.
        # If we got a full page, there may be more.
        $continuationToken = $null
        if ($response -and $response.PSObject.Properties['continuationToken'] -and $response.continuationToken) {
            $continuationToken = $response.continuationToken
        }
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
    do {
        $uri = "https://dev.azure.com/$Org/$Project/_apis/serviceendpoint/endpoints?api-version=7.1&`$top=100"
        if ($continuationToken) {
            $uri += "&continuationToken=$continuationToken"
        }
        $response = Invoke-AdoApi -Uri $uri -Headers $Headers
        if ($response -and $response.PSObject.Properties['value']) {
            foreach ($c in @($response.value)) {
                $connections.Add($c)
            }
        }
        $continuationToken = $null
        if ($response -and $response.PSObject.Properties['continuationToken'] -and $response.continuationToken) {
            $continuationToken = $response.continuationToken
        }
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

    # Determine auth mechanism from scheme
    $authMechanism = switch ($authScheme) {
        'ServicePrincipal'              { 'SPN' }
        'ManagedServiceIdentity'        { 'ManagedIdentity' }
        'WorkloadIdentityFederation'    { 'Federation' }
        default                         { $authScheme }
    }

    # isShared flag
    $isShared = $false
    if ($Connection.PSObject.Properties['isShared']) {
        $isShared = [bool]$Connection.isShared
    }

    $connId = if ($Connection.PSObject.Properties['id'] -and $Connection.id) {
        $Connection.id
    } else { '' }

    $resourceId = "ado://$($Org.ToLowerInvariant())/$($Project.ToLowerInvariant())/serviceconnection/$($connName.ToLowerInvariant())"

    [PSCustomObject]@{
        Source        = 'ado-connections'
        ResourceId    = $resourceId
        Category      = 'Service Connection'
        Title         = "$connType connection: $connName"
        Compliant     = $true
        Severity      = 'Info'
        Detail        = "Type=$connType; AuthScheme=$authScheme; AuthMechanism=$authMechanism; IsShared=$isShared"
        Remediation   = ''
        LearnMoreUrl  = 'https://learn.microsoft.com/en-us/azure/devops/pipelines/library/service-endpoints'
        SchemaVersion = '1.0'
        AdoOrg        = $Org
        AdoProject    = $Project
        ConnectionId  = $connId
        ConnectionType = $connType
        AuthScheme    = $authScheme
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
