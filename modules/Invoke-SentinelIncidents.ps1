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
$workspaceApiVersion = '2022-10-01'

function ConvertTo-ObjectArray {
    param ([object] $Value)

    if ($null -eq $Value) { return @() }
    if ($Value -is [string]) {
        $trimmed = $Value.Trim()
        if ([string]::IsNullOrWhiteSpace($trimmed)) { return @() }
        if ($trimmed.StartsWith('[') -or $trimmed.StartsWith('{')) {
            try {
                $parsed = $trimmed | ConvertFrom-Json -Depth 30
                return @($parsed)
            } catch {
                return @($trimmed)
            }
        }
        return @($trimmed)
    }

    if ($Value -is [System.Collections.IEnumerable] -and $Value -isnot [string]) {
        return @($Value)
    }

    return @($Value)
}

function ConvertTo-StringArray {
    param ([object] $Value)

    $items = ConvertTo-ObjectArray -Value $Value
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $result = [System.Collections.Generic.List[string]]::new()

    foreach ($item in $items) {
        if ($null -eq $item) { continue }
        $text = [string]$item
        if ([string]::IsNullOrWhiteSpace($text)) { continue }
        $trimmed = $text.Trim()
        if ($seen.Add($trimmed)) {
            $result.Add($trimmed)
        }
    }

    return $result.ToArray()
}

function Get-ObjectPropertyValueSafe {
    param (
        [object] $Object,
        [string[]] $PropertyNames
    )

    foreach ($name in @($PropertyNames)) {
        if ([string]::IsNullOrWhiteSpace($name)) { continue }
        if ($Object -is [System.Collections.IDictionary] -and $Object.Contains($name)) {
            $value = $Object[$name]
            if (-not [string]::IsNullOrWhiteSpace([string]$value)) { return [string]$value }
        }
        if ($Object.PSObject -and $Object.PSObject.Properties[$name]) {
            $value = $Object.$name
            if (-not [string]::IsNullOrWhiteSpace([string]$value)) { return [string]$value }
        }
    }

    return ''
}

function Get-SentinelEntityRefs {
    param ([object] $Value)

    $items = ConvertTo-ObjectArray -Value $Value
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $refs = [System.Collections.Generic.List[string]]::new()

    foreach ($item in $items) {
        if ($null -eq $item) { continue }
        if ($item -is [string]) {
            $raw = $item.Trim().ToLowerInvariant()
            if ($raw -match '^(account|host|ip|filehash):' -and $seen.Add($raw)) {
                $refs.Add($raw)
            }
            continue
        }

        $entityType = (Get-ObjectPropertyValueSafe -Object $item -PropertyNames @('Type', 'EntityType', 'type')).ToLowerInvariant()
        if (-not $entityType) { continue }

        $ref = ''
        switch -Regex ($entityType) {
            '^account$' {
                $accountId = Get-ObjectPropertyValueSafe -Object $item -PropertyNames @('AadUserId', 'AccountAadUserId', 'UserPrincipalName', 'UPN', 'Name', 'Sid', 'ObjectGuid')
                if ($accountId) { $ref = "account:$($accountId.ToLowerInvariant())" }
            }
            '^host$' {
                $hostName = Get-ObjectPropertyValueSafe -Object $item -PropertyNames @('HostName', 'DnsDomain', 'MachineName', 'NtHostName', 'Name')
                if ($hostName) { $ref = "host:$($hostName.ToLowerInvariant())" }
            }
            '^ip$' {
                $ip = Get-ObjectPropertyValueSafe -Object $item -PropertyNames @('Address', 'IpAddress', 'AddressV4', 'AddressV6', 'Name')
                if ($ip) { $ref = "ip:$($ip.ToLowerInvariant())" }
            }
            '^filehash$' {
                $hash = Get-ObjectPropertyValueSafe -Object $item -PropertyNames @('Value', 'HashValue', 'Sha256', 'Sha1', 'Md5', 'FileHash')
                if ($hash) { $ref = "filehash:$($hash.ToLowerInvariant())" }
            }
        }

        if ($ref -and $seen.Add($ref)) {
            $refs.Add($ref)
        }
    }

    return $refs.ToArray()
}

function Get-EvidenceUris {
    param (
        [object] $Comments,
        [object] $RelatedEntities,
        [string] $IncidentDeepLink
    )

    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $uris = [System.Collections.Generic.List[string]]::new()

    foreach ($raw in @($Comments, $RelatedEntities)) {
        foreach ($item in (ConvertTo-ObjectArray -Value $raw)) {
            if ($null -eq $item) { continue }
            if ($item -is [string]) {
                $candidate = $item.Trim()
                if ($candidate -match '^https://') {
                    if ($seen.Add($candidate)) { $uris.Add($candidate) }
                }
                continue
            }

            $uri = Get-ObjectPropertyValueSafe -Object $item -PropertyNames @('Url', 'Uri', 'Link')
            if ($uri -and $uri -match '^https://') {
                if ($seen.Add($uri)) { $uris.Add($uri) }
            }
        }
    }

    if ($IncidentDeepLink) {
        foreach ($suffix in @('comments', 'entities')) {
            $uri = "$($IncidentDeepLink.TrimEnd('/'))/$suffix"
            if ($seen.Add($uri)) { $uris.Add($uri) }
        }
    }

    return $uris.ToArray()
}

function Get-ColumnValue {
    param (
        [object[]] $Row,
        [hashtable] $ColumnIndex,
        [string] $Name
    )

    if (-not $ColumnIndex.ContainsKey($Name)) { return $null }
    $idx = [int]$ColumnIndex[$Name]
    if ($idx -lt 0 -or $idx -ge $Row.Count) { return $null }
    return $Row[$idx]
}

# --- 1. Query SecurityIncident table ---
# SecurityIncident is append-only: every update writes a new row.
# Dedup to the latest row per IncidentNumber, then filter to active.
$queryUri = "https://management.azure.com${WorkspaceResourceId}/api/query?api-version=$workspaceApiVersion"
$incidentKql = @"
SecurityIncident
| where TimeGenerated > ago(${LookbackDays}d)
| summarize arg_max(TimeGenerated, *) by IncidentNumber
| where Status in ('New', 'Active')
| extend AlertCount = array_length(AlertIds)
| extend IncidentAdditionalData = todynamic(column_ifexists('AdditionalData', dynamic({})))
| extend Tactics = todynamic(IncidentAdditionalData.Tactics)
| extend Techniques = todynamic(IncidentAdditionalData.Techniques)
| extend Comments = todynamic(column_ifexists('Comments', dynamic([])))
| extend RelatedEntities = todynamic(column_ifexists('RelatedEntities', dynamic([])))
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
    AlertCount,
    Tactics,
    Techniques,
    Comments,
    RelatedEntities
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
        $incNumber      = [string](Get-ColumnValue -Row $row -ColumnIndex $colIdx -Name 'IncidentNumber')
        $title          = [string](Get-ColumnValue -Row $row -ColumnIndex $colIdx -Name 'Title')
        $severity       = [string](Get-ColumnValue -Row $row -ColumnIndex $colIdx -Name 'Severity')
        $status         = [string](Get-ColumnValue -Row $row -ColumnIndex $colIdx -Name 'Status')
        $classification = [string](Get-ColumnValue -Row $row -ColumnIndex $colIdx -Name 'Classification')
        $owner          = [string](Get-ColumnValue -Row $row -ColumnIndex $colIdx -Name 'Owner')
        $incUrl         = [string](Get-ColumnValue -Row $row -ColumnIndex $colIdx -Name 'IncidentUrl')
        $provider       = [string](Get-ColumnValue -Row $row -ColumnIndex $colIdx -Name 'ProviderName')
        $createdTime    = [string](Get-ColumnValue -Row $row -ColumnIndex $colIdx -Name 'CreatedTime')
        $modifiedTime   = [string](Get-ColumnValue -Row $row -ColumnIndex $colIdx -Name 'LastModifiedTime')
        $description    = [string](Get-ColumnValue -Row $row -ColumnIndex $colIdx -Name 'Description')
        $alertCountRaw  = Get-ColumnValue -Row $row -ColumnIndex $colIdx -Name 'AlertCount'
        $tacticsRaw     = Get-ColumnValue -Row $row -ColumnIndex $colIdx -Name 'Tactics'
        $techniquesRaw  = Get-ColumnValue -Row $row -ColumnIndex $colIdx -Name 'Techniques'
        $commentsRaw    = Get-ColumnValue -Row $row -ColumnIndex $colIdx -Name 'Comments'
        $entitiesRaw    = Get-ColumnValue -Row $row -ColumnIndex $colIdx -Name 'RelatedEntities'

        $alertCount = 0
        if ($null -ne $alertCountRaw -and "$alertCountRaw" -ne '') {
            $alertCount = [int]$alertCountRaw
        }

        if (-not $severity) { $severity = 'Medium' }

        $mitreTactics = ConvertTo-StringArray -Value $tacticsRaw
        $mitreTechniques = ConvertTo-StringArray -Value $techniquesRaw
        $entityRefs = Get-SentinelEntityRefs -Value $entitiesRaw

        $frameworks = [System.Collections.Generic.List[hashtable]]::new()
        foreach ($techniqueId in $mitreTechniques) {
            $frameworks.Add(@{
                Name      = 'MITRE ATT&CK'
                Controls  = @($techniqueId)
                ControlId = $techniqueId
                kind      = 'MITRE ATT&CK'
            }) | Out-Null
        }

        $deepLink = $incUrl
        if (-not $deepLink -and $incNumber) {
            $escapedWorkspaceId = [System.Uri]::EscapeDataString($WorkspaceResourceId)
            $deepLink = "https://portal.azure.com/#view/Microsoft_Azure_Security_Insights/IncidentDetailsBlade/workspaceResourceId/$escapedWorkspaceId/incidentNumber/$incNumber"
        }

        $evidenceUris = Get-EvidenceUris -Comments $commentsRaw -RelatedEntities $entitiesRaw -IncidentDeepLink $deepLink
        $detail = if ($description) { $description } else { "Sentinel incident #$incNumber requires triage." }

        $findings.Add([pscustomobject]@{
            Id               = "sentinel/incident/$incNumber"
            Source           = 'sentinel-incidents'
            Category         = 'ThreatDetection'
            Severity         = $severity
            Compliant        = $false
            Title            = $title
            Detail           = $detail
            Remediation      = "Investigate incident #$incNumber in the Sentinel portal and triage or resolve."
            ResourceId       = $WorkspaceResourceId
            IncidentNumber   = $incNumber
            IncidentStatus   = $status
            Classification   = $classification
            AlertCount       = $alertCount
            IncidentUrl      = $deepLink
            DeepLinkUrl      = $deepLink
            ProviderName     = $provider
            Owner            = $owner
            Description      = $description
            CreatedTime      = $createdTime
            LastModifiedTime = $modifiedTime
            LearnMoreUrl     = 'https://learn.microsoft.com/azure/sentinel/investigate-incidents'
            ToolVersion      = $workspaceApiVersion
            Pillar           = 'Security'
            MitreTactics     = @($mitreTactics)
            MitreTechniques  = @($mitreTechniques)
            Frameworks       = @($frameworks)
            EntityRefs       = @($entityRefs)
            EvidenceUris     = @($evidenceUris)
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
        Set-Content -Path $raw -Value (Remove-Credentials ($result | ConvertTo-Json -Depth 20)) -Encoding utf8
    } catch {
        Write-Warning "Failed to write raw Sentinel JSON: $(Remove-Credentials -Text ([string]$_.Exception.Message))"
    }
}

return [pscustomobject]$result
