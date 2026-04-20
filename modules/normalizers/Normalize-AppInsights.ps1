#Requires -Version 7.4
[CmdletBinding()]
param ()

. "$PSScriptRoot\..\shared\Schema.ps1"
. "$PSScriptRoot\..\shared\Canonicalize.ps1"

function Get-AppInsightsSeverity {
    param([pscustomobject] $Finding)

    $queryType = if ($Finding.PSObject.Properties['QueryType']) { [string]$Finding.QueryType } else { '' }
    if ($queryType -eq 'requests') {
        $avg = 0.0
        if ($Finding.PSObject.Properties['AvgDurationSeconds']) { $avg = [double]$Finding.AvgDurationSeconds }
        if ($avg -gt 30) { return 'High' }
        if ($avg -gt 5) { return 'Medium' }
        return 'Low'
    }
    if ($queryType -eq 'exceptions') { return 'High' }
    if ($queryType -eq 'dependencies') { return 'Medium' }

    switch -Regex ([string]$Finding.Severity) {
        '^(?i)critical$' { 'Critical' }
        '^(?i)high$'     { 'High' }
        '^(?i)medium$'   { 'Medium' }
        '^(?i)low$'      { 'Low' }
        default          { 'Info' }
    }
}

function Get-AppInsightsTitle {
    param([pscustomobject] $Finding)

    $queryType = if ($Finding.PSObject.Properties['QueryType']) { [string]$Finding.QueryType } else { '' }
    $count = if ($Finding.PSObject.Properties['Count']) { [int]$Finding.Count } else { 0 }

    switch ($queryType) {
        'requests' {
            $name = if ($Finding.PSObject.Properties['RequestName']) { [string]$Finding.RequestName } else { 'unknown-request' }
            $avg = if ($Finding.PSObject.Properties['AvgDurationSeconds']) { [math]::Round([double]$Finding.AvgDurationSeconds, 3) } else { 0 }
            return "Slow request: $name avg $avg`s over $count calls"
        }
        'dependencies' {
            $name = if ($Finding.PSObject.Properties['DependencyName']) { [string]$Finding.DependencyName } else { 'unknown-dependency' }
            $type = if ($Finding.PSObject.Properties['DependencyType']) { [string]$Finding.DependencyType } else { 'unknown' }
            return "Dependency failures: $name ($type) failed $count times"
        }
        'exceptions' {
            $problem = if ($Finding.PSObject.Properties['ProblemId']) { [string]$Finding.ProblemId } else { 'unknown-problem' }
            return "Exception cluster: $problem hit $count times"
        }
        default {
            if ($Finding.PSObject.Properties['Title'] -and $Finding.Title) { return [string]$Finding.Title }
            return 'Application Insights finding'
        }
    }
}

function Get-AppInsightsLearnMoreUrl {
    param([pscustomobject] $Finding)

    if ($Finding.PSObject.Properties['LearnMoreUrl'] -and ([string]$Finding.LearnMoreUrl).StartsWith('https://', [System.StringComparison]::OrdinalIgnoreCase)) {
        return [string]$Finding.LearnMoreUrl
    }

    $resourceId = if ($Finding.PSObject.Properties['ResourceId']) { [string]$Finding.ResourceId } else { '' }
    if ([string]::IsNullOrWhiteSpace($resourceId)) { return 'https://portal.azure.com/' }

    $timeRangeHours = if ($Finding.PSObject.Properties['TimeRangeHours']) { [int]$Finding.TimeRangeHours } else { 24 }
    $query = switch ([string]$Finding.QueryType) {
        'requests'     { "requests | where timestamp > ago($($timeRangeHours)h)" }
        'dependencies' { "dependencies | where timestamp > ago($($timeRangeHours)h) | where success == false" }
        'exceptions'   { "exceptions | where timestamp > ago($($timeRangeHours)h)" }
        default        { "traces | where timestamp > ago($($timeRangeHours)h)" }
    }
    $encodedQuery = [System.Uri]::EscapeDataString($query)
    return "https://portal.azure.com/#@/resource$resourceId/logs?timespan=PT$($timeRangeHours)H&query=$encodedQuery"
}

function Normalize-AppInsights {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [PSCustomObject] $ToolResult
    )

    if ($ToolResult.Status -ne 'Success' -or -not $ToolResult.Findings) {
        return @()
    }

    $runId = [guid]::NewGuid().ToString()
    $normalized = [System.Collections.Generic.List[PSCustomObject]]::new()

    foreach ($f in $ToolResult.Findings) {
        $rawId = if ($f.PSObject.Properties['ResourceId'] -and $f.ResourceId) { [string]$f.ResourceId } else { '' }
        if (-not $rawId) { continue }

        $subId = ''
        $rg = ''
        if ($rawId -match '/subscriptions/([^/]+)') { $subId = $Matches[1] }
        if ($rawId -match '/resourceGroups/([^/]+)') { $rg = $Matches[1] }

        try {
            $canonicalId = (ConvertTo-CanonicalEntityId -RawId $rawId -EntityType 'AzureResource').CanonicalId
        } catch {
            $canonicalId = $rawId.ToLowerInvariant()
        }

        $row = New-FindingRow -Id $(if ($f.PSObject.Properties['Id']) { [string]$f.Id } else { [guid]::NewGuid().ToString() }) `
            -Source $(if ($f.PSObject.Properties['Source']) { [string]$f.Source } else { 'appinsights' }) `
            -EntityId $canonicalId -EntityType 'AzureResource' `
            -Title (Get-AppInsightsTitle -Finding $f) `
            -Compliant $(if ($f.PSObject.Properties['Compliant']) { [bool]$f.Compliant } else { $false }) `
            -ProvenanceRunId $runId -Platform 'Azure' `
            -Category $(if ($f.PSObject.Properties['Category']) { [string]$f.Category } else { 'Performance' }) `
            -Severity (Get-AppInsightsSeverity -Finding $f) `
            -Detail $(if ($f.PSObject.Properties['Detail']) { [string]$f.Detail } else { '' }) `
            -Remediation $(if ($f.PSObject.Properties['Remediation']) { [string]$f.Remediation } else { '' }) `
            -LearnMoreUrl (Get-AppInsightsLearnMoreUrl -Finding $f) `
            -ResourceId $rawId -SubscriptionId $subId -ResourceGroup $rg

        if ($null -eq $row) { continue }

        foreach ($extra in @('QueryType', 'RequestName', 'DependencyName', 'DependencyType', 'ProblemId', 'Count', 'AvgDurationSeconds', 'TimeRangeHours')) {
            if ($f.PSObject.Properties[$extra] -and $null -ne $f.$extra) {
                $row | Add-Member -NotePropertyName $extra -NotePropertyValue $f.$extra -Force
            }
        }

        $normalized.Add($row)
    }

    return @($normalized)
}
