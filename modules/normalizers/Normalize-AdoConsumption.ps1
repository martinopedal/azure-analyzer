#Requires -Version 7.4
[CmdletBinding()]
param ()

. "$PSScriptRoot\..\shared\Schema.ps1"
. "$PSScriptRoot\..\shared\Canonicalize.ps1"

function Get-PropertyValue {
    param ([object]$Obj, [string]$Name, [object]$Default = $null)
    if ($null -eq $Obj) { return $Default }
    $p = $Obj.PSObject.Properties[$Name]
    if ($null -eq $p -or $null -eq $p.Value) { return $Default }
    return $p.Value
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

function Convert-ToNullableDouble {
    param ([object]$Value)
    if ($null -eq $Value) { return $null }
    $parsed = 0.0
    if ([double]::TryParse([string]$Value, [System.Globalization.NumberStyles]::Float -bor [System.Globalization.NumberStyles]::AllowThousands, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$parsed)) {
        return [double]$parsed
    }
    return $null
}

function Normalize-AdoConsumption {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [PSCustomObject] $ToolResult
    )

    if ($ToolResult.Status -notin @('Success', 'PartialSuccess') -or -not $ToolResult.Findings) {
        return @()
    }

    $runId = [guid]::NewGuid().ToString()
    $normalized = [System.Collections.Generic.List[PSCustomObject]]::new()

    foreach ($finding in @($ToolResult.Findings)) {
        $rawId = if ($finding.PSObject.Properties['ResourceId'] -and $finding.ResourceId) { [string]$finding.ResourceId } else { '' }
        if ([string]::IsNullOrWhiteSpace($rawId)) { continue }

        $canonicalId = $rawId.ToLowerInvariant()
        try {
            $canonicalId = (ConvertTo-CanonicalEntityId -RawId $rawId -EntityType 'AdoProject').CanonicalId
        } catch {
            $canonicalId = $rawId.ToLowerInvariant()
        }

        $severity = switch -Regex ([string]$finding.Severity) {
            '^(?i)critical$' { 'Critical' }
            '^(?i)high$'     { 'High' }
            '^(?i)medium$'   { 'Medium' }
            '^(?i)low$'      { 'Low' }
            default          { 'Info' }
        }

        $ruleId = if ($finding.PSObject.Properties['RuleId'] -and $finding.RuleId) { [string]$finding.RuleId } else { '' }
        $pillar = [string](Get-PropertyValue -Obj $finding -Name 'Pillar' -Default '')
        $impact = [string](Get-PropertyValue -Obj $finding -Name 'Impact' -Default '')
        $effort = [string](Get-PropertyValue -Obj $finding -Name 'Effort' -Default '')
        $deepLinkUrl = [string](Get-PropertyValue -Obj $finding -Name 'DeepLinkUrl' -Default '')
        $evidenceUris = @(Convert-ToStringArray (Get-PropertyValue -Obj $finding -Name 'EvidenceUris' -Default @()))
        $baselineTags = @(Convert-ToStringArray (Get-PropertyValue -Obj $finding -Name 'BaselineTags' -Default @()))
        $entityRefs = @(Convert-ToStringArray (Get-PropertyValue -Obj $finding -Name 'EntityRefs' -Default @()))
        $scoreDelta = Convert-ToNullableDouble (Get-PropertyValue -Obj $finding -Name 'ScoreDelta' -Default $null)
        $toolVersion = [string](Get-PropertyValue -Obj $finding -Name 'ToolVersion' -Default (Get-PropertyValue -Obj $ToolResult -Name 'ToolVersion' -Default ''))
        $row = New-FindingRow -Id ([string]$finding.Id) `
            -Source 'ado-consumption' -EntityId $canonicalId -EntityType 'AdoProject' `
            -Title ([string]$finding.Title) -Compliant ([bool]$finding.Compliant) -ProvenanceRunId $runId `
            -Platform 'ADO' -Category ([string]$finding.Category) -Severity $severity `
            -Detail ([string]$finding.Detail) -Remediation ([string]$finding.Remediation) `
            -LearnMoreUrl ([string]$finding.LearnMoreUrl) -ResourceId $rawId -RuleId $ruleId `
            -Pillar $pillar -Impact $impact -Effort $effort -DeepLinkUrl $deepLinkUrl `
            -EvidenceUris $evidenceUris -BaselineTags $baselineTags -ScoreDelta $scoreDelta `
            -EntityRefs $entityRefs -ToolVersion $toolVersion

        if ($null -ne $row) {
            $normalized.Add($row)
        }
    }

    return @($normalized)
}
