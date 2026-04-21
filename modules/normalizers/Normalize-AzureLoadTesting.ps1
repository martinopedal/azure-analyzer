#Requires -Version 7.4
[CmdletBinding()]
param ()

. "$PSScriptRoot\..\shared\Schema.ps1"
. "$PSScriptRoot\..\shared\Canonicalize.ps1"

function Get-LoadTestingSeverity {
    param([string] $Severity)
    switch -Regex ($Severity) {
        '^(?i)critical$' { 'Critical' }
        '^(?i)high$'     { 'High' }
        '^(?i)medium$'   { 'Medium' }
        '^(?i)low$'      { 'Low' }
        '^(?i)info.*'    { 'Info' }
        default          { 'Medium' }
    }
}

function Get-LoadTestingTitle {
    param([pscustomobject] $Finding)

    if ($Finding.PSObject.Properties['Title'] -and $Finding.Title) {
        return [string]$Finding.Title
    }

    $testName = if ($Finding.PSObject.Properties['TestName']) { [string]$Finding.TestName } else { 'unknown-test' }
    $runId = if ($Finding.PSObject.Properties['TestRunId']) { [string]$Finding.TestRunId } else { 'unknown-run' }
    $metric = if ($Finding.PSObject.Properties['MetricDisplayName']) { [string]$Finding.MetricDisplayName } elseif ($Finding.PSObject.Properties['MetricName']) { [string]$Finding.MetricName } else { 'metric' }
    $delta = if ($Finding.PSObject.Properties['RegressionPercent']) { [math]::Round([double]$Finding.RegressionPercent, 2) } else { 0 }
    $cause = if ($Finding.PSObject.Properties['FailureCause']) { [string]$Finding.FailureCause } else { 'No failure cause provided by the API.' }

    if ($Finding.Id -like '*/failed') {
        return "Load test '$testName' run $runId failed: $cause"
    }
    if ($Finding.Id -like '*/regression/*') {
        return "Load test '$testName' regressed by $delta% in $metric"
    }
    if ($Finding.Id -like '*/no-runs') {
        return "Load test '$testName' has no recent runs"
    }
    if ($Finding.Id -like '*/healthy') {
        return "Load test '$testName' run $runId is healthy"
    }
    return "Load test '$testName' finding"
}

function Convert-ToStringArray {
    param([object] $Value)

    if ($null -eq $Value) { return @() }

    $items = [System.Collections.Generic.List[string]]::new()
    if ($Value -is [string]) {
        if (-not [string]::IsNullOrWhiteSpace($Value)) {
            $items.Add($Value.Trim()) | Out-Null
        }
        return @($items.ToArray())
    }

    foreach ($item in @($Value)) {
        if ($null -eq $item) { continue }
        $text = [string]$item
        if ([string]::IsNullOrWhiteSpace($text)) { continue }
        $items.Add($text.Trim()) | Out-Null
    }

    return @($items.ToArray())
}

function Normalize-AzureLoadTesting {
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

        $title = Get-LoadTestingTitle -Finding $f
        $detail = if ($f.PSObject.Properties['Detail']) { [string]$f.Detail } else { '' }
        $severityRaw = ''
        if ($f.PSObject.Properties['Severity']) { $severityRaw = [string]$f.Severity }
        $severity = Get-LoadTestingSeverity -Severity $severityRaw
        $compliant = $false
        if ($f.PSObject.Properties['Compliant']) { $compliant = [bool]$f.Compliant }
        $findingId = if ($f.PSObject.Properties['Id'] -and $f.Id) { [string]$f.Id } else { [guid]::NewGuid().ToString() }
        $category = if ($f.PSObject.Properties['Category'] -and $f.Category) { [string]$f.Category } else { 'Performance' }
        $remediation = if ($f.PSObject.Properties['Remediation']) { [string]$f.Remediation } else { '' }
        $learnMoreUrl = if ($f.PSObject.Properties['LearnMoreUrl']) { [string]$f.LearnMoreUrl } else { '' }
        $source = if ($f.PSObject.Properties['Source'] -and $f.Source) { [string]$f.Source } else { 'loadtesting' }
        $pillar = if ($f.PSObject.Properties['Pillar']) { [string]$f.Pillar } else { 'Performance Efficiency' }
        $impact = if ($f.PSObject.Properties['Impact']) { [string]$f.Impact } else { '' }
        $effort = if ($f.PSObject.Properties['Effort']) { [string]$f.Effort } else { '' }
        $deepLinkUrl = if ($f.PSObject.Properties['DeepLinkUrl'] -and $f.DeepLinkUrl) { [string]$f.DeepLinkUrl } else { $learnMoreUrl }
        $evidenceUris = if ($f.PSObject.Properties['EvidenceUris']) { @(Convert-ToStringArray -Value $f.EvidenceUris) } else { @() }
        $baselineTags = if ($f.PSObject.Properties['BaselineTags']) { @(Convert-ToStringArray -Value $f.BaselineTags) } else { @() }
        $entityRefs = if ($f.PSObject.Properties['EntityRefs']) { @(Convert-ToStringArray -Value $f.EntityRefs) } else { @() }
        $toolVersion = if ($f.PSObject.Properties['ToolVersion']) { [string]$f.ToolVersion } elseif ($ToolResult.PSObject.Properties['ToolVersion']) { [string]$ToolResult.ToolVersion } else { '' }
        $scoreDelta = $null
        if ($f.PSObject.Properties['ScoreDelta'] -and $null -ne $f.ScoreDelta) {
            try { $scoreDelta = [double]$f.ScoreDelta } catch { $scoreDelta = $null }
        } elseif ($f.PSObject.Properties['RegressionPercent'] -and $null -ne $f.RegressionPercent) {
            try { $scoreDelta = [double]$f.RegressionPercent } catch { $scoreDelta = $null }
        }

        $row = New-FindingRow -Id $findingId `
            -Source $source -EntityId $canonicalId -EntityType 'AzureResource' `
            -Title $title -Compliant $compliant -ProvenanceRunId $runId `
            -Platform 'Azure' -Category $category -Severity $severity `
            -Detail $detail -Remediation $remediation `
            -LearnMoreUrl $learnMoreUrl -ResourceId $rawId `
            -SubscriptionId $subId -ResourceGroup $rg `
            -Pillar $pillar -Impact $impact -Effort $effort `
            -DeepLinkUrl $deepLinkUrl -EvidenceUris $evidenceUris `
            -BaselineTags $baselineTags -ScoreDelta $scoreDelta `
            -EntityRefs $entityRefs -ToolVersion $toolVersion

        if ($null -eq $row) { continue }

        foreach ($extra in @(
                'LoadTestResourceName',
                'TestName',
                'TestRunId',
                'RunStatus',
                'FailureCause',
                'PassFailCriteriaFailed',
                'MetricName',
                'MetricDisplayName',
                'BaselineValue',
                'CurrentValue',
                'RegressionPercent',
                'ThresholdPercent',
                'DaysBack'
            )) {
            if ($f.PSObject.Properties[$extra] -and $null -ne $f.$extra) {
                $row | Add-Member -NotePropertyName $extra -NotePropertyValue $f.$extra -Force
            }
        }

        $normalized.Add($row)
    }

    return @($normalized)
}
