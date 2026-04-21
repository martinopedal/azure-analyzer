#requires -Version 7.0
<#
.SYNOPSIS
    Wrapper for Application Insights performance and reliability KQL signals.

.DESCRIPTION
    Discovers Microsoft.Insights/components resources and queries telemetry for:
      - Slow requests
      - Dependency failures
      - Exception clusters

    Query calls are wrapped with Invoke-WithRetry and Invoke-WithTimeout (300s).
    Optional disk output is sanitized via Remove-Credentials before writing.
#>
[CmdletBinding()]
param (
    [Parameter(Mandatory)] [string] $SubscriptionId,
    [string] $ResourceGroup,
    [string] $AppInsightsName,
    [ValidateRange(1, 168)] [int] $TimeRangeHours = 24,
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

$installerPath = Join-Path $PSScriptRoot 'shared' 'Installer.ps1'
if (Test-Path $installerPath) { . $installerPath }
$timeoutCmd = Get-Command Invoke-WithTimeout -ErrorAction SilentlyContinue
if (-not $timeoutCmd -or -not $timeoutCmd.Parameters.ContainsKey('ScriptBlock')) {
    function Invoke-WithTimeout {
        param(
            [Parameter(Mandatory)] [scriptblock] $ScriptBlock,
            [int] $TimeoutSec = 300
        )
        return & $ScriptBlock
    }
}

$result = [ordered]@{
    SchemaVersion = '1.0'
    Source        = 'appinsights'
    Status        = 'Success'
    Message       = ''
    Findings      = @()
    Subscription  = $SubscriptionId
    Timestamp     = (Get-Date).ToUniversalTime().ToString('o')
}

if (-not (Get-Module -ListAvailable -Name Az.Accounts)) {
    $result.Status = 'Skipped'
    $result.Message = 'Az.Accounts module not installed. Run: Install-Module Az.Accounts -Scope CurrentUser'
    return [PSCustomObject]$result
}

try {
    Import-Module Az.Accounts -ErrorAction SilentlyContinue -WarningAction SilentlyContinue
    Import-Module Az.ApplicationInsights -ErrorAction SilentlyContinue -WarningAction SilentlyContinue
    Import-Module Az.Monitor -ErrorAction SilentlyContinue -WarningAction SilentlyContinue
} catch {
    Write-Verbose "App Insights module import warning: $(Remove-Credentials -Text ([string]$_.Exception.Message))"
}

try {
    $ctx = Get-AzContext -ErrorAction Stop
    if (-not $ctx) { throw 'No Az context' }
} catch {
    $result.Status = 'Skipped'
    $result.Message = 'Not signed in. Run Connect-AzAccount first.'
    return [PSCustomObject]$result
}

function Get-QueryCommandName {
    if (Get-Command Invoke-AzApplicationInsightsQuery -ErrorAction SilentlyContinue) {
        return 'Invoke-AzApplicationInsightsQuery'
    }
    if (Get-Command Invoke-AzOperationalInsightsQuery -ErrorAction SilentlyContinue) {
        return 'Invoke-AzOperationalInsightsQuery'
    }
    return ''
}

function Convert-AppInsightsQueryResults {
    param([object] $QueryResult)

    if ($null -eq $QueryResult) { return @() }
    if ($QueryResult.PSObject.Properties['Results'] -and $QueryResult.Results) {
        return @($QueryResult.Results)
    }
    if ($QueryResult.PSObject.Properties['value'] -and $QueryResult.value) {
        return @($QueryResult.value)
    }
    if ($QueryResult.PSObject.Properties['Tables'] -and $QueryResult.Tables -and $QueryResult.Tables.Count -gt 0) {
        $table = $QueryResult.Tables[0]
        $columns = @($table.Columns | ForEach-Object { [string]$_.Name })
        $rows = [System.Collections.Generic.List[object]]::new()
        foreach ($r in @($table.Rows)) {
            $obj = [ordered]@{}
            for ($i = 0; $i -lt $columns.Count; $i++) {
                $obj[$columns[$i]] = $r[$i]
            }
            $rows.Add([pscustomobject]$obj) | Out-Null
        }
        return @($rows)
    }
    return @()
}

function ConvertTo-DurationSeconds {
    param([object] $Value)

    if ($null -eq $Value) { return 0.0 }
    if ($Value -is [timespan]) { return [math]::Round($Value.TotalSeconds, 3) }
    if ($Value -is [double] -or $Value -is [single] -or $Value -is [int] -or $Value -is [long]) {
        return [math]::Round([double]$Value, 3)
    }
    $text = [string]$Value
    if ([string]::IsNullOrWhiteSpace($text)) { return 0.0 }
    $ts = [timespan]::Zero
    if ([timespan]::TryParse($text, [ref]$ts)) {
        return [math]::Round($ts.TotalSeconds, 3)
    }
    $seconds = 0.0
    if ([double]::TryParse($text, [ref]$seconds)) {
        return [math]::Round($seconds, 3)
    }
    return 0.0
}

function Get-AppInsightsToolVersion {
    $module = Get-Module -ListAvailable -Name Az.ApplicationInsights |
        Sort-Object Version -Descending |
        Select-Object -First 1
    if ($module -and $module.Version) {
        return "Az.ApplicationInsights/$($module.Version)"
    }

    if (Get-Command az -ErrorAction SilentlyContinue) {
        try {
            $cliVersion = az version --query '"azure-cli"' -o tsv 2>$null
            if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace([string]$cliVersion)) {
                return "azure-cli/$([string]$cliVersion)"
            }
        } catch {
            return ''
        }
    }

    return ''
}

function Get-AppInsightsPillar {
    param([string] $QueryType)

    switch ($QueryType) {
        'exceptions' { return 'Reliability' }
        default { return 'PerformanceEfficiency' }
    }
}

function Get-AppInsightsImpact {
    param(
        [string] $QueryType,
        [int] $Count,
        [double] $AvgDurationSeconds = 0.0
    )

    if ($QueryType -eq 'exceptions') {
        if ($Count -ge 150) { return 'High' }
        if ($Count -ge 75) { return 'Medium' }
        return 'Low'
    }

    if ($Count -ge 100 -and $AvgDurationSeconds -ge 10) { return 'High' }
    if ($Count -ge 20 -or $AvgDurationSeconds -ge 5) { return 'Medium' }
    return 'Low'
}

function Get-AppInsightsEffort {
    param(
        [string] $QueryType,
        [double] $AvgDurationSeconds = 0.0
    )

    switch ($QueryType) {
        'exceptions' { return 'Low' }
        'dependencies' {
            if ($AvgDurationSeconds -ge 10) { return 'High' }
            return 'Medium'
        }
        'requests' {
            if ($AvgDurationSeconds -ge 15) { return 'High' }
            return 'Medium'
        }
        default { return 'Medium' }
    }
}

function Get-AppInsightsBaselineTags {
    param([string] $QueryType)

    switch ($QueryType) {
        'requests' { return @('AppInsights-SlowRequests', 'metric:latency') }
        'dependencies' { return @('AppInsights-SlowDependencies', 'metric:dependency-failures') }
        'exceptions' { return @('AppInsights-Exceptions', 'metric:exceptions') }
        default { return @('AppInsights-Unknown', 'metric:telemetry') }
    }
}

function Get-AppInsightsScoreDelta {
    param(
        [pscustomobject] $Row,
        [double] $AvgDurationSeconds = 0.0
    )

    $baseline = $null
    foreach ($prop in @('BaselineAvgDurationSeconds', 'baseline_avg_duration_seconds', 'baseline_avg_duration', 'avg_duration_baseline')) {
        if ($Row.PSObject.Properties[$prop] -and $null -ne $Row.$prop) {
            $candidate = 0.0
            if ([double]::TryParse([string]$Row.$prop, [ref]$candidate)) {
                $baseline = $candidate
                break
            }
        }
    }

    if ($null -ne $baseline) {
        return [math]::Round(($AvgDurationSeconds - [double]$baseline), 3)
    }

    if ($AvgDurationSeconds -gt 0) {
        return [math]::Round($AvgDurationSeconds, 3)
    }

    return $null
}

function Get-AppInsightsEntityRefs {
    param(
        [object] $ResourceItem,
        [string] $ResourceId
    )

    $refs = [System.Collections.Generic.List[string]]::new()
    if (-not [string]::IsNullOrWhiteSpace($ResourceId)) {
        $refs.Add($ResourceId) | Out-Null
    }

    if ($ResourceItem -and $ResourceItem.PSObject.Properties['tags'] -and $ResourceItem.tags) {
        foreach ($entry in $ResourceItem.tags.PSObject.Properties) {
            $name = [string]$entry.Name
            if ($name -notmatch '^hidden-link:(/subscriptions/.+)$') { continue }
            $linkedId = [string]$Matches[1]
            if ($linkedId -match '(?i)/providers/Microsoft\.Web/sites/') {
                if (-not [string]::IsNullOrWhiteSpace($linkedId) -and -not ($refs -contains $linkedId)) {
                    $refs.Add($linkedId) | Out-Null
                }
            }
        }
    }

    return @($refs)
}

function Get-AppInsightsPortalOverviewUrl {
    param([string] $ResourceId)

    return "https://portal.azure.com/#@/resource$ResourceId/overview"
}

function Get-AppInsightsDeepLinkUrl {
    param(
        [string] $ResourceId,
        [string] $QueryType,
        [string] $FilterValue,
        [int] $TimeRangeHours
    )

    $safeValue = if ($FilterValue) { $FilterValue.Replace("'", "''") } else { '' }
    $query = switch ($QueryType) {
        'requests' {
            "requests | where timestamp > ago($($TimeRangeHours)h) | where duration > 5s | where name == '$safeValue' | summarize Count=count(), AvgDurationSeconds=todouble(avg(duration)/1s)"
        }
        'dependencies' {
            "dependencies | where timestamp > ago($($TimeRangeHours)h) | where success == false | where name == '$safeValue' | summarize Count=count() by type"
        }
        'exceptions' {
            "exceptions | where timestamp > ago($($TimeRangeHours)h) | where problemId == '$safeValue' | summarize Count=count()"
        }
        default {
            "traces | where timestamp > ago($($TimeRangeHours)h)"
        }
    }

    $resourceIdEncoded = [System.Uri]::EscapeDataString($ResourceId)
    $queryEncoded = [System.Uri]::EscapeDataString($query)
    return "https://portal.azure.com/#blade/Microsoft_OperationsManagementSuite_Workspace/AnalyticsBlade/resourceId/$resourceIdEncoded/query/$queryEncoded/timespan/PT$($TimeRangeHours)H"
}

function Invoke-AppInsightsQuery {
    param(
        [Parameter(Mandatory)] [string] $CommandName,
        [Parameter(Mandatory)] [pscustomobject] $Resource,
        [Parameter(Mandatory)] [string] $QueryText,
        [Parameter(Mandatory)] [timespan] $QueryTimeSpan
    )

    return Invoke-WithRetry -MaxAttempts 4 -InitialDelaySeconds 2 -MaxDelaySeconds 30 -ScriptBlock {
        Invoke-WithTimeout -TimeoutSec 300 -ScriptBlock {
            if ($CommandName -eq 'Invoke-AzApplicationInsightsQuery') {
                $cmd = Get-Command Invoke-AzApplicationInsightsQuery -ErrorAction Stop
                $splat = @{
                    Query       = $QueryText
                    ErrorAction = 'Stop'
                }
                if ($cmd.Parameters.ContainsKey('AppInsightsName')) {
                    $splat['AppInsightsName'] = $Resource.Name
                } elseif ($cmd.Parameters.ContainsKey('ApplicationInsightsName')) {
                    $splat['ApplicationInsightsName'] = $Resource.Name
                } elseif ($cmd.Parameters.ContainsKey('Name')) {
                    $splat['Name'] = $Resource.Name
                }
                if ($cmd.Parameters.ContainsKey('ResourceGroupName')) {
                    $splat['ResourceGroupName'] = $Resource.ResourceGroup
                }
                if ($cmd.Parameters.ContainsKey('TimeSpan')) {
                    $splat['TimeSpan'] = $QueryTimeSpan
                } elseif ($cmd.Parameters.ContainsKey('Timespan')) {
                    $splat['Timespan'] = $QueryTimeSpan
                }
                return Invoke-AzApplicationInsightsQuery @splat
            }

            if ([string]::IsNullOrWhiteSpace([string]$Resource.WorkspaceId)) {
                throw "Resource '$($Resource.Name)' is missing WorkspaceId for Invoke-AzOperationalInsightsQuery fallback."
            }
            return Invoke-AzOperationalInsightsQuery -WorkspaceId $Resource.WorkspaceId -Query $QueryText -Timespan $QueryTimeSpan -ErrorAction Stop
        }
    }
}

function Add-AppInsightsFinding {
    param(
        [System.Collections.Generic.List[object]] $Collection,
        [string] $Id,
        [string] $Severity,
        [bool] $Compliant,
        [string] $Title,
        [string] $Detail,
        [string] $ResourceId,
        [string] $QueryType,
        [hashtable] $Extras
    )

    $row = [ordered]@{
        Id           = $Id
        Source       = 'appinsights'
        Category     = 'Performance'
        Severity     = $Severity
        Compliant    = $Compliant
        Title        = $Title
        Detail       = $Detail
        Remediation  = 'Investigate telemetry trends, correlate with recent changes, and tune performance budgets and alerts.'
        ResourceId   = $ResourceId
        LearnMoreUrl = (Get-AppInsightsPortalOverviewUrl -ResourceId $ResourceId)
        QueryType    = $QueryType
    }
    if ($Extras) {
        foreach ($key in $Extras.Keys) {
            $row[$key] = $Extras[$key]
        }
    }
    $Collection.Add([pscustomobject]$row) | Out-Null
}

try {
    $commandName = Get-QueryCommandName
    $toolVersion = Get-AppInsightsToolVersion
    if (-not $commandName) {
        $result.Status = 'Skipped'
        $result.Message = 'No App Insights query cmdlet available. Install Az.ApplicationInsights or Az.Monitor.'
        return [PSCustomObject]$result
    }

    $apiVersion = '2020-02-02'
    $resourceUri = if ($ResourceGroup -and $AppInsightsName) {
        "https://management.azure.com/subscriptions/$SubscriptionId/resourceGroups/$([System.Uri]::EscapeDataString($ResourceGroup))/providers/Microsoft.Insights/components/$([System.Uri]::EscapeDataString($AppInsightsName))?api-version=$apiVersion"
    } elseif ($ResourceGroup) {
        "https://management.azure.com/subscriptions/$SubscriptionId/resourceGroups/$([System.Uri]::EscapeDataString($ResourceGroup))/providers/Microsoft.Insights/components?api-version=$apiVersion"
    } else {
        "https://management.azure.com/subscriptions/$SubscriptionId/providers/Microsoft.Insights/components?api-version=$apiVersion"
    }

    $discoveryResponse = Invoke-WithRetry -MaxAttempts 4 -InitialDelaySeconds 2 -MaxDelaySeconds 30 -ScriptBlock {
        Invoke-AzRestMethod -Method GET -Uri $resourceUri -ErrorAction Stop
    }
    if (-not $discoveryResponse -or $discoveryResponse.StatusCode -ge 400) {
        throw "App Insights discovery failed (HTTP $($discoveryResponse.StatusCode)): $($discoveryResponse.Content)"
    }
    $payload = $discoveryResponse.Content | ConvertFrom-Json -Depth 30
    $resourceItems = if ($payload.PSObject.Properties['value']) { @($payload.value) } else { @($payload) }
    if ($AppInsightsName -and -not $ResourceGroup) {
        $resourceItems = @($resourceItems | Where-Object { ([string]$_.name) -ieq $AppInsightsName })
    }

    if ($resourceItems.Count -eq 0) {
        $result.Status = 'Skipped'
        $result.Message = 'No Application Insights resources found in the requested scope.'
        return [pscustomobject]$result
    }

    $querySpan = [timespan]::FromHours($TimeRangeHours)
    $slowRequestQuery = "requests | where timestamp > ago($($TimeRangeHours)h) | where duration > 5s | summarize count(), avg(duration) by name | where count_ > 10"
    $dependencyFailureQuery = "dependencies | where timestamp > ago($($TimeRangeHours)h) | where success == false | summarize count() by name, type | where count_ > 5"
    $exceptionRateQuery = "exceptions | where timestamp > ago($($TimeRangeHours)h) | summarize count() by problemId | where count_ > 50"

    $findings = [System.Collections.Generic.List[object]]::new()

    foreach ($item in $resourceItems) {
        $resourceId = [string]$item.id
        $name = [string]$item.name
        if (-not $resourceId -or -not $name) { continue }
        $rg = if ($resourceId -match '/resourceGroups/([^/]+)') { $Matches[1] } else { '' }
        $workspaceId = ''
        if ($item.PSObject.Properties['properties'] -and $item.properties) {
            if ($item.properties.PSObject.Properties['WorkspaceResourceId']) {
                $workspaceId = [string]$item.properties.WorkspaceResourceId
            } elseif ($item.properties.PSObject.Properties['workspaceResourceId']) {
                $workspaceId = [string]$item.properties.workspaceResourceId
            }
        }
        $resourceRef = [pscustomobject]@{
            Name          = $name
            ResourceGroup = $rg
            ResourceId    = $resourceId
            WorkspaceId   = $workspaceId
        }

        $slowRows = @(Convert-AppInsightsQueryResults (Invoke-AppInsightsQuery -CommandName $commandName -Resource $resourceRef -QueryText $slowRequestQuery -QueryTimeSpan $querySpan))
        foreach ($row in $slowRows) {
            $requestName = [string]$row.name
            if ([string]::IsNullOrWhiteSpace($requestName)) { $requestName = 'unknown-request' }
            $count = 0
            if ($row.PSObject.Properties['count_'] -and $row.count_ -ne $null) { $count = [int]$row.count_ }
            if ($count -le 10) { continue }
            $avgSeconds = ConvertTo-DurationSeconds -Value $(if ($row.PSObject.Properties['avg_duration']) { $row.avg_duration } elseif ($row.PSObject.Properties['avg_duration_']) { $row.avg_duration_ } elseif ($row.PSObject.Properties['average_duration']) { $row.average_duration } else { $null })
            $severity = if ($avgSeconds -gt 30) { 'High' } else { 'Medium' }
            Add-AppInsightsFinding -Collection $findings `
                -Id "appinsights/$name/requests/$([System.Uri]::EscapeDataString($requestName))" `
                -Severity $severity -Compliant $false `
                -Title "Slow request signal for '$requestName'" `
                -Detail "Request '$requestName' averaged $avgSeconds second(s) across $count call(s) in the last $TimeRangeHours hour(s)." `
                -ResourceId $resourceId -QueryType 'requests' `
                -Extras @{
                    RequestName         = $requestName
                    Count               = $count
                    AvgDurationSeconds  = $avgSeconds
                    TimeRangeHours      = $TimeRangeHours
                    Pillar              = (Get-AppInsightsPillar -QueryType 'requests')
                    Impact              = (Get-AppInsightsImpact -QueryType 'requests' -Count $count -AvgDurationSeconds $avgSeconds)
                    Effort              = (Get-AppInsightsEffort -QueryType 'requests' -AvgDurationSeconds $avgSeconds)
                    DeepLinkUrl         = (Get-AppInsightsDeepLinkUrl -ResourceId $resourceId -QueryType 'requests' -FilterValue $requestName -TimeRangeHours $TimeRangeHours)
                    BaselineTags        = @(Get-AppInsightsBaselineTags -QueryType 'requests')
                    ScoreDelta          = (Get-AppInsightsScoreDelta -Row $row -AvgDurationSeconds $avgSeconds)
                    EntityRefs          = @(Get-AppInsightsEntityRefs -ResourceItem $item -ResourceId $resourceId)
                    ToolVersion         = $toolVersion
                }
            $latestFinding = $findings[$findings.Count - 1]
            $latestEvidenceUris = @($latestFinding.LearnMoreUrl, $latestFinding.DeepLinkUrl | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Select-Object -Unique)
            $latestFinding | Add-Member -NotePropertyName EvidenceUris -NotePropertyValue $latestEvidenceUris -Force
        }

        $dependencyRows = @(Convert-AppInsightsQueryResults (Invoke-AppInsightsQuery -CommandName $commandName -Resource $resourceRef -QueryText $dependencyFailureQuery -QueryTimeSpan $querySpan))
        foreach ($row in $dependencyRows) {
            $depName = [string]$row.name
            if ([string]::IsNullOrWhiteSpace($depName)) { $depName = 'unknown-dependency' }
            $depType = [string]$row.type
            if ([string]::IsNullOrWhiteSpace($depType)) { $depType = 'unknown' }
            $count = 0
            if ($row.PSObject.Properties['count_'] -and $row.count_ -ne $null) { $count = [int]$row.count_ }
            if ($count -le 5) { continue }
            Add-AppInsightsFinding -Collection $findings `
                -Id "appinsights/$name/dependencies/$([System.Uri]::EscapeDataString($depName))/$([System.Uri]::EscapeDataString($depType))" `
                -Severity 'Medium' -Compliant $false `
                -Title "Dependency failure signal for '$depName'" `
                -Detail "Dependency '$depName' ($depType) failed $count time(s) in the last $TimeRangeHours hour(s)." `
                -ResourceId $resourceId -QueryType 'dependencies' `
                -Extras @{
                    DependencyName      = $depName
                    DependencyType      = $depType
                    Count               = $count
                    TimeRangeHours      = $TimeRangeHours
                    Pillar              = (Get-AppInsightsPillar -QueryType 'dependencies')
                    Impact              = (Get-AppInsightsImpact -QueryType 'dependencies' -Count $count -AvgDurationSeconds 0)
                    Effort              = (Get-AppInsightsEffort -QueryType 'dependencies' -AvgDurationSeconds 0)
                    DeepLinkUrl         = (Get-AppInsightsDeepLinkUrl -ResourceId $resourceId -QueryType 'dependencies' -FilterValue $depName -TimeRangeHours $TimeRangeHours)
                    BaselineTags        = @(Get-AppInsightsBaselineTags -QueryType 'dependencies')
                    ScoreDelta          = $null
                    EntityRefs          = @(Get-AppInsightsEntityRefs -ResourceItem $item -ResourceId $resourceId)
                    ToolVersion         = $toolVersion
                }
            $latestFinding = $findings[$findings.Count - 1]
            $latestEvidenceUris = @($latestFinding.LearnMoreUrl, $latestFinding.DeepLinkUrl | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Select-Object -Unique)
            $latestFinding | Add-Member -NotePropertyName EvidenceUris -NotePropertyValue $latestEvidenceUris -Force
        }

        $exceptionRows = @(Convert-AppInsightsQueryResults (Invoke-AppInsightsQuery -CommandName $commandName -Resource $resourceRef -QueryText $exceptionRateQuery -QueryTimeSpan $querySpan))
        foreach ($row in $exceptionRows) {
            $problemId = [string]$row.problemId
            if ([string]::IsNullOrWhiteSpace($problemId)) { $problemId = 'unknown-problem' }
            $count = 0
            if ($row.PSObject.Properties['count_'] -and $row.count_ -ne $null) { $count = [int]$row.count_ }
            if ($count -le 50) { continue }
            Add-AppInsightsFinding -Collection $findings `
                -Id "appinsights/$name/exceptions/$([System.Uri]::EscapeDataString($problemId))" `
                -Severity 'High' -Compliant $false `
                -Title "Exception cluster signal for '$problemId'" `
                -Detail "Exception problemId '$problemId' occurred $count time(s) in the last $TimeRangeHours hour(s)." `
                -ResourceId $resourceId -QueryType 'exceptions' `
                -Extras @{
                    ProblemId           = $problemId
                    Count               = $count
                    TimeRangeHours      = $TimeRangeHours
                    Pillar              = (Get-AppInsightsPillar -QueryType 'exceptions')
                    Impact              = (Get-AppInsightsImpact -QueryType 'exceptions' -Count $count -AvgDurationSeconds 0)
                    Effort              = (Get-AppInsightsEffort -QueryType 'exceptions' -AvgDurationSeconds 0)
                    DeepLinkUrl         = (Get-AppInsightsDeepLinkUrl -ResourceId $resourceId -QueryType 'exceptions' -FilterValue $problemId -TimeRangeHours $TimeRangeHours)
                    BaselineTags        = @(Get-AppInsightsBaselineTags -QueryType 'exceptions')
                    ScoreDelta          = $null
                    EntityRefs          = @(Get-AppInsightsEntityRefs -ResourceItem $item -ResourceId $resourceId)
                    ToolVersion         = $toolVersion
                }
            $latestFinding = $findings[$findings.Count - 1]
            $latestEvidenceUris = @($latestFinding.LearnMoreUrl, $latestFinding.DeepLinkUrl | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Select-Object -Unique)
            $latestFinding | Add-Member -NotePropertyName EvidenceUris -NotePropertyValue $latestEvidenceUris -Force
        }
    }

    $result.Findings = @($findings)
    $result.Message = "Scanned Application Insights telemetry for the last $TimeRangeHours hour(s); emitted $($findings.Count) finding(s)."
} catch {
    $result.Status = 'Failed'
    $result.Message = "Application Insights query failed: $(Remove-Credentials -Text ([string]$_.Exception.Message))"
    return [pscustomobject]$result
}

if ($OutputPath) {
    try {
        if (-not (Test-Path $OutputPath)) { New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null }
        $raw = Join-Path $OutputPath "appinsights-$SubscriptionId-$(Get-Date -Format yyyyMMddHHmmss).json"
        Set-Content -Path $raw -Value (Remove-Credentials ($result | ConvertTo-Json -Depth 30)) -Encoding utf8
    } catch {
        Write-Warning "Failed to write App Insights raw JSON: $(Remove-Credentials -Text ([string]$_.Exception.Message))"
    }
}

return [pscustomobject]$result
