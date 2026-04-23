#requires -Version 7.0
<#
.SYNOPSIS
    Wrapper for Microsoft Sentinel coverage / posture -- analytic rules,
    watchlists, hunting queries, and connectors.

.DESCRIPTION
    Companion to Invoke-SentinelIncidents.ps1. Whereas the incidents wrapper
    surfaces detection *output* (live SecurityIncident rows), this wrapper
    surfaces detection *posture* by enumerating the workspace's:

      * Microsoft.SecurityInsights/alertRules     -- analytic rules
      * Microsoft.SecurityInsights/watchlists     -- watchlists + items
      * Microsoft.SecurityInsights/dataConnectors -- connector inventory
      * Microsoft.OperationalInsights/.../savedSearches -- hunting queries
        (filtered to category 'Hunting Queries')

    Detection categories shipped (issue #159):

      1. Sentinel-enabled workspaces with NO analytic rules           (High)
      2. Disabled analytic rules whose last edit is >7 days old       (Medium)
      3. Workspaces with <3 enabled / connected data connectors       (Medium)
      4. Watchlists whose default item TTL (defaultDuration) <30 days (Medium)
      5. Empty watchlists (zero items)                                (Low)
      6. Workspaces with no hunting queries at all                    (Info)

    Categories explicitly DEFERRED (require telemetry the REST surface does
    not expose; would need extra KQL crossref against SecurityIncident /
    saved-search execution records):

      * Enabled analytic rules with no incidents in 30 days
      * Hunting queries not run in 90 days

    Emits a v1 envelope (SchemaVersion 1.0). Normalize-SentinelCoverage.ps1
    converts each finding to a v2 FindingRow keyed to the workspace ARM ID.
    All REST calls are wrapped in Invoke-WithRetry. All disk writes go
    through Remove-Credentials.

.PARAMETER WorkspaceResourceId
    Full ARM resource ID of the Log Analytics workspace linked to Sentinel.

.PARAMETER LookbackDays
    Days threshold for "disabled analytic rule is stale" (detection #2).
    Default 30 (matches the orchestrator-supplied default for workspace-scope
    tools and the watchlist-TTL minimum). A rule whose lastModifiedUtc is
    older than this threshold AND is currently disabled emits a Medium
    finding. Also accepted for orchestrator-shape parity with
    Invoke-SentinelIncidents.

.PARAMETER OutputPath
    Optional directory for raw API JSON (sanitized).
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

$errorsPath = Join-Path $PSScriptRoot 'shared' 'Errors.ps1'
if (Test-Path $errorsPath) { . $errorsPath }
$envelopePath = Join-Path $PSScriptRoot 'shared' 'New-WrapperEnvelope.ps1'
if (Test-Path $envelopePath) { . $envelopePath }
if (-not (Get-Command New-WrapperEnvelope -ErrorAction SilentlyContinue)) { function New-WrapperEnvelope { param([string]$Source,[string]$Status='Failed',[string]$Message='',[object[]]$FindingErrors=@()) return [PSCustomObject]@{ Source=$Source; SchemaVersion='1.0'; Status=$Status; Message=$Message; Findings=@(); Errors=@($FindingErrors) } } }
if (-not (Get-Command New-FindingError -ErrorAction SilentlyContinue)) {
    function New-FindingError { param([string]$Source,[string]$Category,[string]$Reason,[string]$Remediation,[string]$Details) return [pscustomobject]@{ Source=$Source; Category=$Category; Reason=$Reason; Remediation=$Remediation; Details=$Details } }
}
if (-not (Get-Command Format-FindingErrorMessage -ErrorAction SilentlyContinue)) {
    function Format-FindingErrorMessage {
        param([Parameter(Mandatory)]$FindingError)
        $line = "[{0}] {1}: {2}" -f $FindingError.Source, $FindingError.Category, $FindingError.Reason
        if ($FindingError.Remediation) { $line += " Action: $($FindingError.Remediation)" }
        return $line
    }
}

# --- API versions (Microsoft Learn, verified 2024) --------------------------
# https://learn.microsoft.com/rest/api/securityinsights/alert-rules/list
# https://learn.microsoft.com/rest/api/securityinsights/watchlists/list
# https://learn.microsoft.com/rest/api/securityinsights/data-connectors/list
# https://learn.microsoft.com/rest/api/loganalytics/saved-searches/list-by-workspace
$script:SentinelApiVersion = '2024-09-01'
$script:LogAnalyticsApiVersion = '2020-08-01'
$script:ToolVersion = "securityinsights-$($script:SentinelApiVersion)+loganalytics-$($script:LogAnalyticsApiVersion)"
$script:DisabledRuleStaleDays = 7  # legacy default, overridden by -LookbackDays at runtime
$script:WatchlistTtlMinDays   = 30
$script:MinEnabledConnectors  = 3

$subId = ''
if ($WorkspaceResourceId -match '/subscriptions/([^/]+)') { $subId = $Matches[1] }
$rgName = ''
if ($WorkspaceResourceId -match '/resourceGroups/([^/]+)') { $rgName = $Matches[1] }
$workspaceName = ''
if ($WorkspaceResourceId -match '/workspaces/([^/]+)$') { $workspaceName = $Matches[1] }
$analyticsBladeUrl = "https://portal.azure.com/#view/Microsoft_Azure_Security_Insights/MainMenuBlade/~/Analytics/subscriptionId/$subId/resourceGroup/$rgName/workspaceName/$workspaceName"

$result = [ordered]@{
    SchemaVersion = '1.0'
    Source        = 'sentinel-coverage'
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
    if (-not $ctx) { Write-Error 'No Az context' -ErrorAction Stop }
} catch {
    $result.Status  = 'Skipped'
    $result.Message = 'Not signed in. Run Connect-AzAccount first.'
    return [pscustomobject]$result
}

if ($WorkspaceResourceId -notmatch '^/subscriptions/[^/]+/resourceGroups/[^/]+/providers/Microsoft\.OperationalInsights/workspaces/[^/]+$') {
    $result.Status  = 'Failed'
    $result.Message = 'Invalid WorkspaceResourceId format. Expected: /subscriptions/{guid}/resourceGroups/{rg}/providers/Microsoft.OperationalInsights/workspaces/{name}'
    return [pscustomobject]$result
}

$findings = [System.Collections.Generic.List[object]]::new()

function Invoke-SentinelGet {
    param ([Parameter(Mandatory)] [string] $Uri)
    $resp = Invoke-WithRetry -MaxAttempts 3 -ScriptBlock {
        Invoke-AzRestMethod -Method GET -Uri $Uri -ErrorAction Stop
    }
    return $resp
}

function Invoke-SentinelGetPaged {
    <#
    Iterates ARM list responses by following payload.nextLink until exhausted
    or MaxPages hit. Returns an aggregate object:
      { StatusCode = <last>; Items = @(...); TerminalResponse = <last raw> }
    Non-200 on the first page short-circuits with the raw response (no Items).
    Non-200 on a subsequent page is treated as best-effort: a warning is
    emitted, pagination stops, and items collected so far are returned.
    #>
    param (
        [Parameter(Mandatory)] [string] $Uri,
        [int] $MaxPages = 20
    )
    $items = [System.Collections.Generic.List[object]]::new()
    $next = $Uri
    $pages = 0
    $last = $null
    while ($next -and $pages -lt $MaxPages) {
        $resp = Invoke-SentinelGet -Uri $next
        $last = $resp
        $pages++
        if (-not $resp -or $resp.StatusCode -ne 200) {
            if ($pages -eq 1) {
                return [pscustomobject]@{ StatusCode = (if ($resp) { $resp.StatusCode } else { 0 }); Items = @(); TerminalResponse = $resp }
            }
            $code = if ($resp) { $resp.StatusCode } else { 'null' }
            Write-Warning ("Pagination stopped at page {0} (HTTP {1}); returning {2} item(s)." -f $pages, $code, $items.Count)
            break
        }
        $payload = $resp.Content | ConvertFrom-Json -Depth 20
        if ($payload.PSObject.Properties['value'] -and $payload.value) {
            foreach ($v in @($payload.value)) { $items.Add($v) | Out-Null }
        }
        $next = $null
        if ($payload.PSObject.Properties['nextLink'] -and $payload.nextLink) {
            $next = [string]$payload.nextLink
        }
    }
    return [pscustomobject]@{ StatusCode = 200; Items = @($items); TerminalResponse = $last }
}

function ConvertFrom-Iso8601Duration {
    <#
    Returns a [TimeSpan] for an ISO-8601 duration like P30D, PT1H, P1Y2M3DT4H5M.
    Returns $null when the input cannot be parsed. Years are approximated
    as 365 days and months as 30 days (sufficient for "<30d" comparisons).
    #>
    param ([string] $Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $null }
    $pattern = '^P(?:(?<y>\d+)Y)?(?:(?<mo>\d+)M)?(?:(?<d>\d+)D)?(?:T(?:(?<h>\d+)H)?(?:(?<mi>\d+)M)?(?:(?<s>\d+(?:\.\d+)?)S)?)?$'
    if ($Value -notmatch $pattern) { return $null }
    $days = 0.0
    if ($Matches['y'])  { $days += [double]$Matches['y']  * 365 }
    if ($Matches['mo']) { $days += [double]$Matches['mo'] * 30 }
    if ($Matches['d'])  { $days += [double]$Matches['d'] }
    $hours = 0.0
    if ($Matches['h'])  { $hours += [double]$Matches['h'] }
    if ($Matches['mi']) { $hours += [double]$Matches['mi'] / 60 }
    if ($Matches['s'])  { $hours += [double]$Matches['s']  / 3600 }
    return [TimeSpan]::FromDays($days) + [TimeSpan]::FromHours($hours)
}

function Add-Finding {
    param (
        [Parameter(Mandatory)] [string] $Id,
        [Parameter(Mandatory)] [string] $Category,
        [Parameter(Mandatory)] [string] $Severity,
        [Parameter(Mandatory)] [string] $Title,
        [Parameter(Mandatory)] [string] $Detail,
        [Parameter(Mandatory)] [string] $Remediation,
        [string] $LearnMoreUrl,
        [string[]] $MitreTactics = @(),
        [string[]] $MitreTechniques = @(),
        [object[]] $Frameworks = @(),
        [string] $DeepLinkUrl = '',
        [hashtable] $Extras
    )
    $frameworkRows = @($Frameworks)
    if ($frameworkRows.Count -eq 0 -and @($MitreTechniques).Count -gt 0) {
        $frameworkRows = @(
            [ordered]@{
                Name     = 'MITRE ATT&CK'
                Controls = @($MitreTechniques)
            }
        )
    }
    $row = [ordered]@{
        Id           = $Id
        Source       = 'sentinel-coverage'
        Category     = $Category
        Severity     = $Severity
        Compliant    = $false
        Title        = $Title
        Detail       = $Detail
        Remediation  = $Remediation
        ResourceId   = $WorkspaceResourceId
        LearnMoreUrl = if ($LearnMoreUrl) { $LearnMoreUrl } else { 'https://learn.microsoft.com/azure/sentinel/' }
        ToolVersion  = $script:ToolVersion
        Pillar       = 'Security'
        Frameworks   = $frameworkRows
        MitreTactics = @($MitreTactics)
        MitreTechniques = @($MitreTechniques)
        DeepLinkUrl  = if ($DeepLinkUrl) { $DeepLinkUrl } else { $analyticsBladeUrl }
    }
    if ($Extras) {
        foreach ($k in $Extras.Keys) { $row[$k] = $Extras[$k] }
    }
    $findings.Add([pscustomobject]$row) | Out-Null
}

function ConvertTo-StringArray {
    param ([object] $Value)
    $result = [System.Collections.Generic.List[string]]::new()
    if ($null -eq $Value) { return @($result) }
    foreach ($item in @($Value)) {
        if ($null -eq $item) { continue }
        if ($item -is [string]) {
            if (-not [string]::IsNullOrWhiteSpace($item)) { $result.Add($item) | Out-Null }
            continue
        }
        if ($item.PSObject.Properties['name'] -and $item.name) {
            $result.Add([string]$item.name) | Out-Null
            continue
        }
        if ($item.PSObject.Properties['id'] -and $item.id) {
            $result.Add([string]$item.id) | Out-Null
            continue
        }
        $s = [string]$item
        if (-not [string]::IsNullOrWhiteSpace($s)) { $result.Add($s) | Out-Null }
    }
    return @($result)
}

$base       = "https://management.azure.com${WorkspaceResourceId}"
$sentinelOK = $true
$summary    = [ordered]@{ AlertRules = 0; Watchlists = 0; Connectors = 0; HuntingQueries = 0 }

# --- 0. Onboarding probe ---------------------------------------------------
# Microsoft.SecurityInsights/onboardingStates/default returns 200 when the
# workspace is onboarded to Sentinel, 404 when it is not. The alertRules
# endpoint returns 200 + empty array on a non-onboarded workspace, so we
# cannot rely on it for the skip path. See:
# https://learn.microsoft.com/rest/api/securityinsights/sentinel-onboarding-states/get
try {
    $probeUri = "${base}/providers/Microsoft.SecurityInsights/onboardingStates/default?api-version=$($script:SentinelApiVersion)"
    $probeResp = Invoke-SentinelGet -Uri $probeUri
    if ($probeResp -and $probeResp.StatusCode -eq 404) {
        $result.Status  = 'Skipped'
        $result.Message = 'Sentinel is not onboarded on this workspace (onboardingStates/default returned 404).'
        return [pscustomobject]$result
    } elseif (-not $probeResp -or $probeResp.StatusCode -ge 400) {
        # 401/403 = not authorized; treat as Skipped rather than Failed since
        # the user may have Reader on the workspace but not Sentinel Reader.
        $code = if ($probeResp) { $probeResp.StatusCode } else { 'null' }
        if ($probeResp -and ($probeResp.StatusCode -eq 401 -or $probeResp.StatusCode -eq 403)) {
            $result.Status  = 'Skipped'
            $result.Message = "Sentinel onboarding probe denied (HTTP $code). Microsoft Sentinel Reader role required."
            return [pscustomobject]$result
        }
        # Other non-200 (5xx, 409 etc): try alertRules anyway as a best-effort fallback.
        Write-Warning ("Sentinel onboarding probe returned HTTP {0}; continuing with best-effort detection." -f $code)
    }
} catch {
    Write-Warning ("Sentinel onboarding probe failed: {0}; continuing with best-effort detection." -f (Remove-Credentials -Text ([string]$_.Exception.Message)))
}

# --- 1. Analytic rules ------------------------------------------------------
$rules = @()
try {
    $uri  = "${base}/providers/Microsoft.SecurityInsights/alertRules?api-version=$($script:SentinelApiVersion)"
    $paged = Invoke-SentinelGetPaged -Uri $uri
    if ($paged.StatusCode -eq 200) {
        $rules = @($paged.Items)
    } elseif ($paged.StatusCode -eq 404 -or $paged.StatusCode -eq 409) {
        # Defensive fallback: probe missed it but alertRules is definitive.
        $sentinelOK = $false
        $result.Status  = 'Skipped'
        $result.Message = "Microsoft.SecurityInsights/alertRules returned HTTP $($paged.StatusCode). Sentinel may not be onboarded."
        return [pscustomobject]$result
    } else {
        $resp = $paged.TerminalResponse
        $statusCode = if ($resp) { $resp.StatusCode } else { 'null' }
        $content    = if ($resp) { $resp.Content }    else { 'No response' }
        throw (Format-FindingErrorMessage (New-FindingError `
            -Source 'wrapper:sentinel-coverage' `
            -Category 'TransientFailure' `
            -Reason "alertRules list returned HTTP ${statusCode}." `
            -Remediation 'Verify Microsoft Sentinel Reader role on the workspace and retry.' `
            -Details (Remove-Credentials -Text ([string]$content))))
    }
} catch {
    $result.Status  = 'Failed'
    $result.Message = "Sentinel alertRules query failed: $(Remove-Credentials -Text ([string]$_.Exception.Message))"
    return [pscustomobject]$result
}

$summary.AlertRules = $rules.Count
$enabledRules  = @($rules | Where-Object { $_.properties.PSObject.Properties['enabled'] -and $_.properties.enabled })
$disabledRules = @($rules | Where-Object { $_.properties.PSObject.Properties['enabled'] -and -not $_.properties.enabled })

# Detection #1: workspace has NO analytic rules at all (High).
if ($rules.Count -eq 0) {
    Add-Finding -Id "sentinel/coverage/no-analytic-rules" `
        -Category 'ThreatDetection' -Severity 'High' `
        -Title 'Sentinel workspace has no analytic rules' `
        -Detail 'No analytic rules are configured on this workspace. Sentinel cannot generate incidents without enabled analytic rules.' `
        -Remediation 'Enable Microsoft-provided analytic rule templates in the Sentinel portal (Analytics blade) or deploy ALZ Sentinel content packs.' `
        -LearnMoreUrl 'https://learn.microsoft.com/azure/sentinel/detect-threats-built-in' `
        -Extras @{ AnalyticRuleCount = 0 }
}

# Detection #2: disabled analytic rules whose last edit is >LookbackDays old (Medium).
$staleThreshold = [TimeSpan]::FromDays($LookbackDays)
$now = (Get-Date).ToUniversalTime()
foreach ($r in $disabledRules) {
    $name = [string]$r.name
    $lastModRaw = $null
    $lastModUtc = $null
    if ($r.properties.PSObject.Properties['lastModifiedUtc']) {
        $rawValue = $r.properties.lastModifiedUtc
        if ($rawValue -is [datetime]) {
            # ConvertFrom-Json auto-parses ISO-8601 strings to DateTime; preserve the canonical 'o' format for output.
            $lastModUtc = $rawValue.ToUniversalTime()
            $lastModRaw = $lastModUtc.ToString('o')
        } else {
            $lastModRaw = [string]$rawValue
            try { $lastModUtc = ([datetime]::Parse($lastModRaw, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind)).ToUniversalTime() } catch { $lastModUtc = $null }
        }
    }
    $age = $null
    if ($lastModUtc) { $age = $now - $lastModUtc }
    if ($null -eq $age -or $age -ge $staleThreshold) {
        $ageDays = if ($age) { [math]::Round($age.TotalDays, 1) } else { 'unknown' }
        $title   = if ($r.properties.PSObject.Properties['displayName']) { [string]$r.properties.displayName } else { $name }
        $mitreTactics = @()
        $mitreTechniques = @()
        if ($r.properties.PSObject.Properties['tactics']) {
            $mitreTactics = @(ConvertTo-StringArray -Value $r.properties.tactics)
        }
        if ($r.properties.PSObject.Properties['techniques']) {
            $mitreTechniques = @(ConvertTo-StringArray -Value $r.properties.techniques)
        }
        Add-Finding -Id "sentinel/coverage/disabled-rule/$name" `
            -Category 'ThreatDetection' -Severity 'Medium' `
            -Title "Analytic rule disabled >$LookbackDays days: $title" `
            -Detail "Rule '$title' (id $name) has been disabled for $ageDays day(s). Disabled rules generate no incidents." `
            -Remediation 'Re-enable the rule, archive it via configuration-as-code, or document the exception.' `
            -LearnMoreUrl 'https://learn.microsoft.com/azure/sentinel/detect-threats-custom' `
            -MitreTactics $mitreTactics `
            -MitreTechniques $mitreTechniques `
            -Extras @{ RuleId = $name; RuleDisplayName = $title; LastModifiedUtc = $lastModRaw; AgeDays = $ageDays; StaleThresholdDays = $LookbackDays }
    }
}

# --- 2. Data connectors ----------------------------------------------------
$connectors = @()
try {
    $uri  = "${base}/providers/Microsoft.SecurityInsights/dataConnectors?api-version=$($script:SentinelApiVersion)"
    $paged = Invoke-SentinelGetPaged -Uri $uri
    if ($paged.StatusCode -eq 200) {
        $connectors = @($paged.Items)
    } elseif ($paged.StatusCode -ge 400) {
        Write-Warning ("Sentinel dataConnectors query returned HTTP {0}; skipping connector checks." -f $paged.StatusCode)
    }
} catch {
    Write-Warning ("Sentinel dataConnectors query failed: {0}" -f (Remove-Credentials -Text ([string]$_.Exception.Message)))
}
$summary.Connectors = $connectors.Count

# Filter to connectors that have at least one dataType in an "Enabled" state.
# Connectors registered but with all dataTypes Disabled do not produce telemetry.
function Test-ConnectorEnabled {
    param ($Connector)
    if (-not $Connector -or -not $Connector.PSObject.Properties['properties']) { return $false }
    $props = $Connector.properties
    if (-not $props.PSObject.Properties['dataTypes'] -or -not $props.dataTypes) { return $false }
    $dataTypes = $props.dataTypes
    # dataTypes can be either an object whose properties are dataType buckets,
    # or an array. Normalize to a list of bucket objects.
    $buckets = @()
    if ($dataTypes -is [System.Collections.IEnumerable] -and $dataTypes -isnot [string]) {
        $buckets = @($dataTypes)
    } else {
        foreach ($p in $dataTypes.PSObject.Properties) { $buckets += $p.Value }
    }
    foreach ($b in $buckets) {
        if ($b -and $b.PSObject.Properties['state'] -and ([string]$b.state) -ieq 'Enabled') { return $true }
    }
    return $false
}
$enabledConnectors = @($connectors | Where-Object { Test-ConnectorEnabled -Connector $_ })
$summary['EnabledConnectors'] = $enabledConnectors.Count

# Detection #3: workspace has <3 ENABLED connectors (Medium -- under-monitored).
if ($enabledConnectors.Count -lt $script:MinEnabledConnectors) {
    Add-Finding -Id "sentinel/coverage/few-connectors" `
        -Category 'ThreatDetection' -Severity 'Medium' `
        -Title "Sentinel workspace has only $($enabledConnectors.Count) enabled data connector(s) (<$($script:MinEnabledConnectors))" `
        -Detail "Workspace has $($connectors.Count) data connector(s) registered, of which $($enabledConnectors.Count) have at least one dataType in 'Enabled' state. A healthy Sentinel deployment typically has at least $($script:MinEnabledConnectors) enabled data sources (e.g., Azure Activity, Entra ID sign-ins, Defender XDR). Note: the dataConnectors REST surface does not enumerate every modern connector type (CCP / Defender XDR may be under-reported)." `
        -Remediation 'Connect additional data sources (Azure Activity, Microsoft Entra ID, Microsoft 365 Defender, Threat Intelligence) via the Sentinel Data connectors blade.' `
        -LearnMoreUrl 'https://learn.microsoft.com/azure/sentinel/connect-data-sources' `
        -Extras @{ ConnectorCount = $connectors.Count; EnabledConnectorCount = $enabledConnectors.Count; MinExpected = $script:MinEnabledConnectors }
}

# --- 3. Watchlists ---------------------------------------------------------
$watchlists = @()
try {
    $uri  = "${base}/providers/Microsoft.SecurityInsights/watchlists?api-version=$($script:SentinelApiVersion)"
    $paged = Invoke-SentinelGetPaged -Uri $uri
    if ($paged.StatusCode -eq 200) {
        $watchlists = @($paged.Items)
    } elseif ($paged.StatusCode -ge 400) {
        Write-Warning ("Sentinel watchlists query returned HTTP {0}; skipping watchlist checks." -f $paged.StatusCode)
    }
} catch {
    Write-Warning ("Sentinel watchlists query failed: {0}" -f (Remove-Credentials -Text ([string]$_.Exception.Message)))
}
$summary.Watchlists = $watchlists.Count

foreach ($w in $watchlists) {
    $alias = if ($w.properties.PSObject.Properties['watchlistAlias']) { [string]$w.properties.watchlistAlias } else { [string]$w.name }
    $name  = [string]$w.name

    # Detection #4: watchlist default TTL <30 days (Medium).
    if ($w.properties.PSObject.Properties['defaultDuration'] -and $w.properties.defaultDuration) {
        $ttl = ConvertFrom-Iso8601Duration -Value ([string]$w.properties.defaultDuration)
        if ($ttl -and $ttl.TotalDays -lt $script:WatchlistTtlMinDays) {
            Add-Finding -Id "sentinel/coverage/watchlist-ttl/$alias" `
                -Category 'ThreatDetection' -Severity 'Medium' `
                -Title "Watchlist '$alias' has TTL <$($script:WatchlistTtlMinDays) days" `
                -Detail "Watchlist '$alias' defaultDuration is $([string]$w.properties.defaultDuration) (~$([math]::Round($ttl.TotalDays,1)) days). Items may expire before analytic rules can use them." `
                -Remediation 'Increase the watchlist defaultDuration in the Sentinel portal or via ARM template.' `
                -LearnMoreUrl 'https://learn.microsoft.com/azure/sentinel/watchlists' `
                -Extras @{ WatchlistAlias = $alias; WatchlistName = $name; DefaultDuration = ([string]$w.properties.defaultDuration); TtlDays = [math]::Round($ttl.TotalDays, 1) }
        }
    }

    # Detection #5: empty watchlist (Low).
    $itemCount = $null
    try {
        $aliasEnc = [uri]::EscapeDataString($alias)
        $itemUri  = "${base}/providers/Microsoft.SecurityInsights/watchlists/$aliasEnc/watchlistItems?api-version=$($script:SentinelApiVersion)"
        $itemPaged = Invoke-SentinelGetPaged -Uri $itemUri
        if ($itemPaged.StatusCode -eq 200) {
            $itemCount = @($itemPaged.Items).Count
        }
    } catch {
        Write-Warning ("watchlistItems query failed for {0}: {1}" -f $alias, (Remove-Credentials -Text ([string]$_.Exception.Message)))
    }
    if ($null -ne $itemCount -and $itemCount -eq 0) {
        Add-Finding -Id "sentinel/coverage/watchlist-empty/$alias" `
            -Category 'ThreatDetection' -Severity 'Low' `
            -Title "Watchlist '$alias' is empty" `
            -Detail "Watchlist '$alias' contains 0 items. Analytic rules referencing it will produce no matches." `
            -Remediation 'Populate the watchlist via CSV upload, ARM template, or the Sentinel Logic Apps connector.' `
            -LearnMoreUrl 'https://learn.microsoft.com/azure/sentinel/watchlists-create' `
            -Extras @{ WatchlistAlias = $alias; WatchlistName = $name; ItemCount = 0 }
    }
}

# --- 4. Hunting queries (saved searches with category 'Hunting Queries') ---
$hunting = @()
try {
    $uri  = "${base}/savedSearches?api-version=$($script:LogAnalyticsApiVersion)"
    $paged = Invoke-SentinelGetPaged -Uri $uri
    if ($paged.StatusCode -eq 200) {
        $hunting = @($paged.Items | Where-Object {
            $_.properties.PSObject.Properties['category'] -and
            ([string]$_.properties.category) -match '(?i)hunting'
        })
    } elseif ($paged.StatusCode -ge 400) {
        Write-Warning ("savedSearches query returned HTTP {0}; skipping hunting-query checks." -f $paged.StatusCode)
    }
} catch {
    Write-Warning ("savedSearches query failed: {0}" -f (Remove-Credentials -Text ([string]$_.Exception.Message)))
}
$summary.HuntingQueries = $hunting.Count

# Detection #6: workspace has no hunting queries at all (Info).
if ($hunting.Count -eq 0) {
    Add-Finding -Id "sentinel/coverage/no-hunting-queries" `
        -Category 'ThreatDetection' -Severity 'Info' `
        -Title 'Sentinel workspace has no hunting queries' `
        -Detail 'No saved searches with category "Hunting Queries" are configured. Hunting queries enable proactive threat investigation beyond automated analytic rules.' `
        -Remediation 'Import Microsoft-provided hunting query templates (Hunting blade) or deploy queries from the Sentinel content hub.' `
        -LearnMoreUrl 'https://learn.microsoft.com/azure/sentinel/hunting' `
        -Extras @{ HuntingQueryCount = 0 }
}

$result.Findings = @($findings)
$enabledCount = $summary['EnabledConnectors']
if ($null -eq $enabledCount) { $enabledCount = 0 }
$result.Message  = "Sentinel coverage scan: $($findings.Count) finding(s). Inventory -- analyticRules: $($summary.AlertRules) (enabled: $($enabledRules.Count), disabled: $($disabledRules.Count)); watchlists: $($summary.Watchlists); connectors: $($summary.Connectors) (enabled: $enabledCount); huntingQueries: $($summary.HuntingQueries)."

if ($OutputPath) {
    try {
        if (-not (Test-Path $OutputPath)) { New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null }
        $raw = Join-Path $OutputPath "sentinel-coverage-$(Get-Date -Format yyyyMMddHHmmss).json"
        Set-Content -Path $raw -Value (Remove-Credentials ($result | ConvertTo-Json -Depth 20)) -Encoding utf8
    } catch {
        Write-Warning "Failed to write raw Sentinel coverage JSON: $(Remove-Credentials -Text ([string]$_.Exception.Message))"
    }
}

return [pscustomobject]$result
