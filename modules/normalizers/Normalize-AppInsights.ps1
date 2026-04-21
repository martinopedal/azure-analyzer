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

    return "https://portal.azure.com/#@/resource$resourceId/overview"
}

function Get-AppInsightsDeepLinkUrl {
    param([pscustomobject] $Finding)

    if ($Finding.PSObject.Properties['DeepLinkUrl'] -and ([string]$Finding.DeepLinkUrl).StartsWith('https://', [System.StringComparison]::OrdinalIgnoreCase)) {
        return [string]$Finding.DeepLinkUrl
    }

    $resourceId = if ($Finding.PSObject.Properties['ResourceId']) { [string]$Finding.ResourceId } else { '' }
    if ([string]::IsNullOrWhiteSpace($resourceId)) { return '' }

    $timeRangeHours = if ($Finding.PSObject.Properties['TimeRangeHours']) { [int]$Finding.TimeRangeHours } else { 24 }
    $query = switch ([string]$Finding.QueryType) {
        'requests'     { "requests | where timestamp > ago($($timeRangeHours)h) | where duration > 5s" }
        'dependencies' { "dependencies | where timestamp > ago($($timeRangeHours)h) | where success == false" }
        'exceptions'   { "exceptions | where timestamp > ago($($timeRangeHours)h)" }
        default        { "traces | where timestamp > ago($($timeRangeHours)h)" }
    }
    $resourceIdEncoded = [System.Uri]::EscapeDataString($resourceId)
    $queryEncoded = [System.Uri]::EscapeDataString($query)
    return "https://portal.azure.com/#blade/Microsoft_OperationsManagementSuite_Workspace/AnalyticsBlade/resourceId/$resourceIdEncoded/query/$queryEncoded/timespan/PT$($timeRangeHours)H"
}

function Convert-ToStringArray {
    param ([object]$Value)
    if ($null -eq $Value) { return @() }

    $items = [System.Collections.Generic.List[string]]::new()
    if ($Value -is [string]) {
        if (-not [string]::IsNullOrWhiteSpace($Value)) { $items.Add($Value.Trim()) | Out-Null }
    } else {
        foreach ($item in @($Value)) {
            if ($null -eq $item) { continue }
            $text = [string]$item
            if (-not [string]::IsNullOrWhiteSpace($text)) { $items.Add($text.Trim()) | Out-Null }
        }
    }

    return @($items)
}

function Resolve-AppInsightsPillar {
    param([pscustomobject] $Finding)

    if ($Finding.PSObject.Properties['Pillar'] -and -not [string]::IsNullOrWhiteSpace([string]$Finding.Pillar)) {
        return [string]$Finding.Pillar
    }

    if ([string]$Finding.QueryType -eq 'exceptions') { return 'Reliability' }
    return 'PerformanceEfficiency'
}

function Resolve-AppInsightsImpact {
    param([pscustomobject] $Finding)

    if ($Finding.PSObject.Properties['Impact'] -and -not [string]::IsNullOrWhiteSpace([string]$Finding.Impact)) {
        return [string]$Finding.Impact
    }

    $count = if ($Finding.PSObject.Properties['Count']) { [int]$Finding.Count } else { 0 }
    $avg = if ($Finding.PSObject.Properties['AvgDurationSeconds']) { [double]$Finding.AvgDurationSeconds } else { 0.0 }
    if ([string]$Finding.QueryType -eq 'exceptions') {
        if ($count -ge 150) { return 'High' }
        if ($count -ge 75) { return 'Medium' }
        return 'Low'
    }

    if ($count -ge 100 -and $avg -ge 10) { return 'High' }
    if ($count -ge 20 -or $avg -ge 5) { return 'Medium' }
    return 'Low'
}

function Resolve-AppInsightsEffort {
    param([pscustomobject] $Finding)

    if ($Finding.PSObject.Properties['Effort'] -and -not [string]::IsNullOrWhiteSpace([string]$Finding.Effort)) {
        return [string]$Finding.Effort
    }

    $avg = if ($Finding.PSObject.Properties['AvgDurationSeconds']) { [double]$Finding.AvgDurationSeconds } else { 0.0 }
    switch ([string]$Finding.QueryType) {
        'exceptions' { return 'Low' }
        'dependencies' {
            if ($avg -ge 10) { return 'High' }
            return 'Medium'
        }
        'requests' {
            if ($avg -ge 15) { return 'High' }
            return 'Medium'
        }
        default { return 'Medium' }
    }
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

        $pillar = Resolve-AppInsightsPillar -Finding $f
        $impact = Resolve-AppInsightsImpact -Finding $f
        $effort = Resolve-AppInsightsEffort -Finding $f
        $deepLinkUrl = Get-AppInsightsDeepLinkUrl -Finding $f
        $evidenceUris = @(Convert-ToStringArray -Value $(if ($f.PSObject.Properties['EvidenceUris']) { $f.EvidenceUris } else { @() }))
        if ($deepLinkUrl) { $evidenceUris = @($evidenceUris + @($deepLinkUrl) | Select-Object -Unique) }
        $learnMoreUrl = Get-AppInsightsLearnMoreUrl -Finding $f
        if ($learnMoreUrl) { $evidenceUris = @($evidenceUris + @($learnMoreUrl) | Select-Object -Unique) }
        $baselineTags = @(Convert-ToStringArray -Value $(if ($f.PSObject.Properties['BaselineTags']) { $f.BaselineTags } else { @() }))
        $entityRefs = @(Convert-ToStringArray -Value $(if ($f.PSObject.Properties['EntityRefs']) { $f.EntityRefs } else { @() }))
        $toolVersion = if ($f.PSObject.Properties['ToolVersion']) { [string]$f.ToolVersion } elseif ($ToolResult.PSObject.Properties['ToolVersion']) { [string]$ToolResult.ToolVersion } else { '' }
        $scoreDelta = $null
        if ($f.PSObject.Properties['ScoreDelta'] -and $null -ne $f.ScoreDelta) {
            $scoreDelta = [Nullable[double]]([double]$f.ScoreDelta)
        } elseif ($f.PSObject.Properties['AvgDurationSeconds'] -and $null -ne $f.AvgDurationSeconds) {
            $scoreDelta = [Nullable[double]]([double]$f.AvgDurationSeconds)
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
            -LearnMoreUrl $learnMoreUrl `
            -ResourceId $rawId -SubscriptionId $subId -ResourceGroup $rg `
            -Pillar $pillar -Impact $impact -Effort $effort `
            -DeepLinkUrl $deepLinkUrl -EvidenceUris $evidenceUris `
            -BaselineTags $baselineTags -ScoreDelta $scoreDelta `
            -EntityRefs $entityRefs -ToolVersion $toolVersion

        if ($null -eq $row) { continue }

        foreach ($extra in @('QueryType', 'RequestName', 'DependencyName', 'DependencyType', 'ProblemId', 'Count', 'AvgDurationSeconds', 'TimeRangeHours', 'ScoreDelta')) {
            if ($f.PSObject.Properties[$extra] -and $null -ne $f.$extra) {
                $row | Add-Member -NotePropertyName $extra -NotePropertyValue $f.$extra -Force
            }
        }

        $normalized.Add($row)
    }

    return @($normalized)
}
