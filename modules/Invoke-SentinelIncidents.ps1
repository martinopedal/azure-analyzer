#requires -Version 7.0
<#
.SYNOPSIS
    Wrapper for Microsoft Sentinel -- active incidents and alerts from a Log Analytics workspace.

.DESCRIPTION
    Queries the Log Analytics workspace API with KQL against the SecurityIncident
    table. Emits a v1 tool-result shape that the Normalize-SentinelIncidents
    normalizer converts into v2 FindingRows.

    Incidents land on the AzureResource entity (workspace ARM resource). Each
    incident carries severity, status, classification, and
    linked alert count so the EntityStore can fold Sentinel findings next to existing
    Defender for Cloud recommendations.

    Uses Invoke-WithRetry for transient 429/503/timeout handling. Gracefully skips
    when the workspace is unreachable or the SecurityIncident table does not exist.

.PARAMETER WorkspaceResourceId
    Full ARM resource ID of the Log Analytics workspace linked to Sentinel.
    Example: /subscriptions/<guid>/resourceGroups/<rg>/providers/Microsoft.OperationalInsights/workspaces/<name>

.PARAMETER LookbackDays
    Number of days to look back for incidents. Default 30.

.PARAMETER OutputPath
    Optional directory for raw API JSON (for audit).
#>
[CmdletBinding()]
param (
    [Parameter(Mandatory)] [string] $WorkspaceResourceId,
    [ValidateRange(1, 365)]
    [int] $LookbackDays = 30,
    [string] $OutputPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$retryPath = Join-Path $PSScriptRoot 'shared' 'Retry.ps1'
if (Test-Path $retryPath) { . $retryPath }
if (-not (Get-Command Invoke-WithRetry -ErrorAction SilentlyContinue)) {
    function Invoke-WithRetry { param([scriptblock]$ScriptBlock, [int]$MaxAttempts = 3) & $ScriptBlock }
}

$sanitizePath = Join-Path $PSScriptRoot 'shared' 'Sanitize.ps1'
if (Test-Path $sanitizePath) { . $sanitizePath }
if (-not (Get-Command Remove-Credentials -ErrorAction SilentlyContinue)) {
    function Remove-Credentials { param([string]$Text) return $Text }
}

# Extract subscription ID from the workspace ARM ID
$subId = ''
if ($WorkspaceResourceId -match '/subscriptions/([^/]+)') {
    $subId = $Matches[1]
}

$result = [ordered]@{
    SchemaVersion = '1.0'
    Source        = 'sentinel-incidents'
    Status        = 'Success'
    Message       = ''
    Findings      = @()
    Subscription  = $subId
    Timestamp     = (Get-Date).ToUniversalTime().ToString('o')
}

if (-not (Get-Module -ListAvailable -Name Az.Accounts)) {
    $result.Status  = 'Skipped'
    $result.Message = 'Az.Accounts module not installed. Run: Install-Module Az.Accounts -Scope CurrentUser'
    return [pscustomobject]$result
}
Import-Module Az.Accounts -ErrorAction SilentlyContinue

try {
    $ctx = Get-AzContext -ErrorAction Stop
    if (-not $ctx) { throw 'No Az context' }
} catch {
    $result.Status  = 'Skipped'
    $result.Message = 'Not signed in. Run Connect-AzAccount first.'
    return [pscustomobject]$result
}

# Validate workspace ARM ID format
if ($WorkspaceResourceId -notmatch '^/subscriptions/[^/]+/resourceGroups/[^/]+/providers/Microsoft\.OperationalInsights/workspaces/[^/]+$') {
    $result.Status  = 'Failed'
    $result.Message = 'Invalid WorkspaceResourceId format. Expected: /subscriptions/{guid}/resourceGroups/{rg}/providers/Microsoft.OperationalInsights/workspaces/{name}'
    return [pscustomobject]$result
}

$findings = [System.Collections.Generic.List[object]]::new()

# --- 1. Query SecurityIncident table ---
# SecurityIncident is append-only: every update writes a new row.
# Dedup to the latest row per IncidentNumber, then filter to active.
$queryUri = "https://management.azure.com${WorkspaceResourceId}/api/query?api-version=2022-10-01"
$incidentKql = @"
SecurityIncident
| where TimeGenerated > ago(${LookbackDays}d)
| summarize arg_max(TimeGenerated, *) by IncidentNumber
| where Status in ('New', 'Active')
| extend AlertCount = array_length(AlertIds)
| project
    IncidentNumber,
    Title,
    Severity,
    Status,
    Classification,
    Owner = tostring(Owner.assignedTo),
    IncidentUrl,
    ProviderName,
    CreatedTime,
    LastModifiedTime,
    Description,
    AlertCount
| order by case(Severity, "High", 1, "Medium", 2, "Low", 3, "Informational", 4, 5), CreatedTime desc
"@

try {
    $body = @{ query = $incidentKql } | ConvertTo-Json -Depth 5
    $incResp = Invoke-WithRetry -MaxAttempts 3 -ScriptBlock {
        Invoke-AzRestMethod -Method POST -Uri $queryUri -Payload $body -ErrorAction Stop
    }

    if (-not $incResp -or $incResp.StatusCode -ge 400) {
        $statusCode = if ($incResp) { $incResp.StatusCode } else { 'null' }
        $content = if ($incResp) { $incResp.Content } else { 'No response' }

        # HTTP 404: workspace or resource not found
        $isTableNotFound = ($incResp -and $incResp.StatusCode -eq 404)

        # HTTP 400 with semantic error indicating table does not exist
        # Log Analytics returns SemanticError with "could not be resolved" for missing tables
        if (-not $isTableNotFound -and $incResp -and $incResp.StatusCode -eq 400) {
            $isTableNotFound = ($content -match 'SemanticError' -and $content -match 'could not be resolved') -or
                               ($content -match "'SecurityIncident'" -and $content -match 'not found')
        }

        if ($isTableNotFound) {
            $result.Status  = 'Skipped'
            $result.Message = "SecurityIncident table not available (HTTP $statusCode). Sentinel may not be enabled on this workspace."
            return [pscustomobject]$result
        }
        throw "Log Analytics query API returned status ${statusCode}: $(Remove-Credentials -Text ([string]$content))"
    }

    $queryResult = $incResp.Content | ConvertFrom-Json -Depth 20

    # Parse tabular response (columns + rows)
    $tables = $queryResult.tables
    if (-not $tables -or $tables.Count -eq 0) {
        $result.Message = 'No active Sentinel incidents found.'
        $result.Findings = @()
        return [pscustomobject]$result
    }

    $columns = $tables[0].columns
    $rows    = $tables[0].rows

    if (-not $rows -or $rows.Count -eq 0) {
        $result.Message = 'No active Sentinel incidents in the lookback window.'
        $result.Findings = @()
        return [pscustomobject]$result
    }

    # Build column-name index
    $colIdx = @{}
    for ($i = 0; $i -lt $columns.Count; $i++) {
        $colIdx[$columns[$i].name] = $i
    }

    foreach ($row in $rows) {
        $incNumber    = [string]$row[$colIdx['IncidentNumber']]
        $title        = [string]$row[$colIdx['Title']]
        $severity     = [string]$row[$colIdx['Severity']]
        $status       = [string]$row[$colIdx['Status']]
        $classification = [string]$row[$colIdx['Classification']]
        $owner        = [string]$row[$colIdx['Owner']]
        $incUrl       = [string]$row[$colIdx['IncidentUrl']]
        $provider     = [string]$row[$colIdx['ProviderName']]
        $createdTime  = [string]$row[$colIdx['CreatedTime']]
        $modifiedTime = [string]$row[$colIdx['LastModifiedTime']]
        $description  = [string]$row[$colIdx['Description']]
        $alertCount   = [int]$row[$colIdx['AlertCount']]

        if (-not $severity) { $severity = 'Medium' }

        $detail = "Status: $status | Provider: $provider | Alerts: $alertCount | Owner: $owner"
        if ($classification) { $detail += " | Classification: $classification" }
        if ($description) { $detail += " | $description" }

        $findings.Add([pscustomobject]@{
            Id              = "sentinel/incident/$incNumber"
            Source          = 'sentinel-incidents'
            Category        = 'ThreatDetection'
            Severity        = $severity
            Compliant       = $false
            Title           = $title
            Detail          = $detail
            Remediation     = "Investigate incident #$incNumber in the Sentinel portal and triage or resolve."
            ResourceId      = $WorkspaceResourceId
            IncidentNumber  = $incNumber
            IncidentStatus  = $status
            Classification  = $classification
            AlertCount      = $alertCount
            IncidentUrl     = $incUrl
            ProviderName    = $provider
            CreatedTime     = $createdTime
            LastModifiedTime = $modifiedTime
            LearnMoreUrl    = 'https://learn.microsoft.com/azure/sentinel/investigate-incidents'
        }) | Out-Null
    }
} catch {
    $result.Status  = 'Failed'
    $result.Message = "Sentinel incident query failed: $(Remove-Credentials -Text ([string]$_.Exception.Message))"
    return [pscustomobject]$result
}

$result.Findings = @($findings)
$result.Message  = "Found $($findings.Count) active Sentinel incident(s) in the last $LookbackDays day(s)."

if ($OutputPath) {
    try {
        if (-not (Test-Path $OutputPath)) { New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null }
        $raw = Join-Path $OutputPath "sentinel-incidents-$(Get-Date -Format yyyyMMddHHmmss).json"
        (Remove-Credentials ($result | ConvertTo-Json -Depth 20)) | Set-Content -Path $raw -Encoding utf8
    } catch {
        Write-Warning "Failed to write raw Sentinel JSON: $(Remove-Credentials -Text ([string]$_.Exception.Message))"
    }
}

return [pscustomobject]$result
