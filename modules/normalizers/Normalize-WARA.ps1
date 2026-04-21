#Requires -Version 7.4
<#
.SYNOPSIS
    Normalizer for Well-Architected Reliability Assessment (WARA) findings.
.DESCRIPTION
    Converts raw WARA wrapper output to v3 FindingRow objects.
    Platform=Azure, EntityType=AzureResource.
    WARA only emits non-compliant findings (Compliant is always $false).
#>
[CmdletBinding()]
param ()

. "$PSScriptRoot\..\shared\Schema.ps1"
. "$PSScriptRoot\..\shared\Canonicalize.ps1"

function Normalize-WARA {
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

    function Get-Text {
        param([object] $Object, [string[]] $Names)
        foreach ($name in $Names) {
            if ($Object.PSObject.Properties[$name]) {
                $value = $Object.$name
                if ($null -ne $value -and -not [string]::IsNullOrWhiteSpace([string]$value)) {
                    return [string]$value
                }
            }
        }
        return ''
    }

    function Normalize-Pillar {
        param([string] $Value)
        if ([string]::IsNullOrWhiteSpace($Value)) { return '' }
        $input = $Value.Trim().ToLowerInvariant()
        if ($input -match 'reliab') { return 'Reliability' }
        if ($input -match 'secur') { return 'Security' }
        if ($input -match 'cost') { return 'Cost' }
        if ($input -match 'perform') { return 'Performance' }
        if ($input -match 'operat') { return 'Operational' }
        return ''
    }

    foreach ($finding in $ToolResult.Findings) {
        $rawId = ''
        if ($finding.PSObject.Properties['ResourceId'] -and $finding.ResourceId) {
            $rawId = [string]$finding.ResourceId
        }

        $subId = ''
        $rg = ''
        $canonicalId = ''

        if ($rawId -and $rawId -match '^/subscriptions/') {
            try {
                $canonicalId = (ConvertTo-CanonicalEntityId -RawId $rawId -EntityType 'AzureResource').CanonicalId
            } catch {
                $canonicalId = $rawId.ToLowerInvariant()
            }
            if ($rawId -match '/subscriptions/([^/]+)') { $subId = $Matches[1] }
            if ($rawId -match '/resourceGroups/([^/]+)') { $rg = $Matches[1] }
        }

        $findingId = if ($finding.PSObject.Properties['Id'] -and $finding.Id) {
            [string]$finding.Id
        } else {
            [guid]::NewGuid().ToString()
        }
        if (-not $canonicalId) {
            $canonicalId = "wara/$findingId"
        }

        $title = Get-Text -Object $finding -Names @('Title')
        if ([string]::IsNullOrWhiteSpace($title)) { $title = 'Unknown' }
        $category = Get-Text -Object $finding -Names @('Category')
        if ([string]::IsNullOrWhiteSpace($category)) { $category = 'Reliability' }

        $rawSev = Get-Text -Object $finding -Names @('Severity')
        if ([string]::IsNullOrWhiteSpace($rawSev)) { $rawSev = 'Medium' }
        $severity = switch -Regex ($rawSev.ToString().ToLowerInvariant()) {
            'critical'         { 'Critical' }
            'high'             { 'High' }
            'medium|moderate'  { 'Medium' }
            'low'              { 'Low' }
            'info'             { 'Info' }
            default            { 'Medium' }
        }

        $detail = Get-Text -Object $finding -Names @('Detail')
        $remediation = Get-Text -Object $finding -Names @('Remediation')
        $learnMore = Get-Text -Object $finding -Names @('LearnMoreUrl')
        $deepLink = Get-Text -Object $finding -Names @('DeepLinkUrl', 'LearnMoreUrl')
        $pillar = Normalize-Pillar (Get-Text -Object $finding -Names @('Pillar', 'Category'))
        $impact = Get-Text -Object $finding -Names @('Impact')
        $effort = Get-Text -Object $finding -Names @('Effort')
        $recommendationId = Get-Text -Object $finding -Names @('RecommendationId', 'Id')
        $controls = @()
        if (-not [string]::IsNullOrWhiteSpace($recommendationId)) { $controls = @($recommendationId) }

        $frameworks = @()
        if (-not [string]::IsNullOrWhiteSpace($pillar) -or $controls.Count -gt 0) {
            $frameworks = @(@{
                    Name     = 'WAF'
                    Pillars  = if ($pillar) { @($pillar) } else { @() }
                    Controls = $controls
                })
        }

        $baselineTags = @()
        if ($finding.PSObject.Properties['BaselineTags'] -and $finding.BaselineTags) {
            $baselineTags = @($finding.BaselineTags | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        }
        if ($baselineTags.Count -eq 0 -and $finding.PSObject.Properties['ServiceCategory'] -and $finding.ServiceCategory) {
            $baselineTags = @("service-category:$([string]$finding.ServiceCategory)")
        }

        $entityRefs = @()
        if ($finding.PSObject.Properties['EntityRefs'] -and $finding.EntityRefs) {
            foreach ($entityRef in @($finding.EntityRefs)) {
                $value = [string]$entityRef
                if ([string]::IsNullOrWhiteSpace($value)) { continue }
                if ($value -match '^/subscriptions/') {
                    try {
                        $entityRefs += (ConvertTo-CanonicalEntityId -RawId $value -EntityType 'AzureResource').CanonicalId
                    } catch {
                        $entityRefs += $value.ToLowerInvariant()
                    }
                } else {
                    $entityRefs += $value
                }
            }
            $entityRefs = @($entityRefs | Select-Object -Unique)
        }

        $remediationSnippets = @()
        if ($finding.PSObject.Properties['RemediationSteps'] -and $finding.RemediationSteps) {
            foreach ($step in @($finding.RemediationSteps)) {
                $text = [string]$step
                if ([string]::IsNullOrWhiteSpace($text)) { continue }
                $remediationSnippets += @{
                    language = 'text'
                    code     = $text.Trim()
                }
            }
        }

        $toolVersion = Get-Text -Object $finding -Names @('ToolVersion')
        if ([string]::IsNullOrWhiteSpace($toolVersion) -and $ToolResult.PSObject.Properties['ToolVersion']) {
            $toolVersion = [string]$ToolResult.ToolVersion
        }

        $row = New-FindingRow -Id $findingId `
            -Source 'wara' -EntityId $canonicalId -EntityType 'AzureResource' `
            -Title $title -Compliant $false -ProvenanceRunId $runId `
            -Platform 'Azure' -Category $category -Severity $severity `
            -Detail $detail -Remediation $remediation `
            -LearnMoreUrl $learnMore -ResourceId ($rawId ?? '') `
            -SubscriptionId $subId -ResourceGroup $rg `
            -Pillar $pillar -Impact $impact -Effort $effort `
            -DeepLinkUrl $deepLink -RemediationSnippets $remediationSnippets `
            -Frameworks $frameworks -Controls $controls `
            -BaselineTags $baselineTags -EntityRefs $entityRefs `
            -ToolVersion $toolVersion
        # Skip null rows (validation failed)
        if ($null -ne $row) {
            $normalized.Add($row)
        }
    }

    return @($normalized)
}
