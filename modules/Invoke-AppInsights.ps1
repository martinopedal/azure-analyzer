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
        LearnMoreUrl = "https://portal.azure.com/#@/resource$ResourceId/overview"
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
                }
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
                }
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
                }
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
