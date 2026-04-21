#Requires -Version 7.4
[CmdletBinding()]
param ()

. "$PSScriptRoot\..\shared\Schema.ps1"
. "$PSScriptRoot\..\shared\Canonicalize.ps1"

function Get-PropertyValue {
    param ([object]$Obj, [string]$Name, [object]$Default = '')
    if ($null -eq $Obj) { return $Default }
    $p = $Obj.PSObject.Properties[$Name]
    if ($null -eq $p -or $null -eq $p.Value) { return $Default }
    return $p.Value
}

function Convert-ProwlerFrameworks {
    param (
        [object[]] $Frameworks,
        [string] $RuleId
    )

    $converted = [System.Collections.Generic.List[hashtable]]::new()
    foreach ($fw in @($Frameworks)) {
        $name = [string](Get-PropertyValue -Obj $fw -Name 'Name' (Get-PropertyValue -Obj $fw -Name 'kind' ''))
        if ([string]::IsNullOrWhiteSpace($name)) { continue }
        $controls = @(Get-PropertyValue -Obj $fw -Name 'Controls' @())
        if (@($controls).Count -eq 0) {
            $singleControl = [string](Get-PropertyValue -Obj $fw -Name 'controlId' $RuleId)
            if (-not [string]::IsNullOrWhiteSpace($singleControl)) {
                $controls = @($singleControl)
            }
        }
        if (@($controls).Count -eq 0) { $controls = @($RuleId) }

        foreach ($control in @($controls)) {
            $controlId = [string]$control
            if ([string]::IsNullOrWhiteSpace($controlId)) { continue }
            $converted.Add(@{
                    kind      = $name
                    controlId = $controlId
                }) | Out-Null
        }
    }
    return @($converted)
}

function Convert-ProwlerRemediationSnippets {
    param ([object[]] $Snippets)
    $converted = [System.Collections.Generic.List[hashtable]]::new()
    foreach ($snippet in @($Snippets)) {
        $code = [string](Get-PropertyValue -Obj $snippet -Name 'Code' '')
        if ([string]::IsNullOrWhiteSpace($code)) { continue }
        $type = [string](Get-PropertyValue -Obj $snippet -Name 'Type' '')
        if ([string]::IsNullOrWhiteSpace($type)) { $type = 'General' }
        $converted.Add(@{
                Type = $type
                Code = $code
            }) | Out-Null
    }
    return @($converted)
}

function Normalize-Prowler {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [PSCustomObject] $ToolResult
    )

    if ($ToolResult.Status -ne 'Success' -or -not $ToolResult.Findings) {
        return @()
    }

    $runId = [guid]::NewGuid().ToString()
    $toolVersion = [string](Get-PropertyValue -Obj $ToolResult -Name 'ToolVersion' '')
    $normalized = [System.Collections.Generic.List[PSCustomObject]]::new()

    foreach ($finding in $ToolResult.Findings) {
        $rawId = [string](Get-PropertyValue -Obj $finding -Name 'ResourceId' '')
        $resourceArn = [string](Get-PropertyValue -Obj $finding -Name 'ResourceArn' '')
        $ruleId = [string](Get-PropertyValue -Obj $finding -Name 'RuleId' (Get-PropertyValue -Obj $finding -Name 'Id' ([guid]::NewGuid().ToString())))

        $subId = ''
        $rg = ''
        $canonicalId = ''
        if ($rawId -and $rawId -match '^/subscriptions/') {
            try {
                $canonicalId = (ConvertTo-CanonicalEntityId -RawId $rawId -EntityType 'AzureResource').CanonicalId
            } catch {
                $canonicalId = $rawId.ToLowerInvariant()
            }
            if ($rawId -match '(?i)/subscriptions/([^/]+)') { $subId = $Matches[1].ToLowerInvariant() }
            if ($rawId -match '(?i)/resourcegroups/([^/]+)') { $rg = $Matches[1] }
        }

        if (-not $canonicalId) {
            $fallbackSub = if ($subId -match '^[0-9a-fA-F-]{36}$') { $subId } else { '00000000-0000-0000-0000-000000000000' }
            $fallbackArmId = "/subscriptions/$fallbackSub/providers/microsoft.security/prowlerfindings/$ruleId"
            $canonicalId = (ConvertTo-CanonicalEntityId -RawId $fallbackArmId -EntityType 'AzureResource').CanonicalId
        }

        $severityRaw = [string](Get-PropertyValue -Obj $finding -Name 'Severity' 'Medium')
        $severity = switch -Regex ($severityRaw.ToLowerInvariant()) {
            'critical' { 'Critical' }
            '^high$' { 'High' }
            '^medium$' { 'Medium' }
            '^low$' { 'Low' }
            '^info' { 'Info' }
            default { 'Medium' }
        }

        $compliant = [bool](Get-PropertyValue -Obj $finding -Name 'Compliant' $false)
        $frameworks = Convert-ProwlerFrameworks -Frameworks @(Get-PropertyValue -Obj $finding -Name 'Frameworks' @()) -RuleId $ruleId
        $toolVersionResolved = [string](Get-PropertyValue -Obj $finding -Name 'ToolVersion' $toolVersion)

        $evidenceUris = [System.Collections.Generic.List[string]]::new()
        foreach ($uri in @(Get-PropertyValue -Obj $finding -Name 'EvidenceUris' @())) {
            if (-not [string]::IsNullOrWhiteSpace([string]$uri)) { $evidenceUris.Add([string]$uri) | Out-Null }
        }
        if (-not [string]::IsNullOrWhiteSpace($resourceArn)) {
            $evidenceUris.Add($resourceArn) | Out-Null
        }

        $row = New-FindingRow -Id ([string](Get-PropertyValue -Obj $finding -Name 'Id' $ruleId)) `
            -Source 'prowler' -EntityId $canonicalId -EntityType 'AzureResource' `
            -Title ([string](Get-PropertyValue -Obj $finding -Name 'Title' $ruleId)) `
            -RuleId $ruleId -Compliant $compliant -ProvenanceRunId $runId `
            -Platform 'Azure' -Category ([string](Get-PropertyValue -Obj $finding -Name 'Category' 'SecurityPosture')) `
            -Severity $severity -Detail ([string](Get-PropertyValue -Obj $finding -Name 'Detail' '')) `
            -Remediation ([string](Get-PropertyValue -Obj $finding -Name 'Remediation' '')) `
            -LearnMoreUrl ([string](Get-PropertyValue -Obj $finding -Name 'LearnMoreUrl' '')) `
            -ResourceId $rawId -SubscriptionId $subId -ResourceGroup $rg `
            -Pillar ([string](Get-PropertyValue -Obj $finding -Name 'Pillar' 'Security')) `
            -Frameworks $frameworks `
            -DeepLinkUrl ([string](Get-PropertyValue -Obj $finding -Name 'DeepLinkUrl' '')) `
            -RemediationSnippets @(Convert-ProwlerRemediationSnippets -Snippets @(Get-PropertyValue -Obj $finding -Name 'RemediationSnippets' @())) `
            -EvidenceUris @($evidenceUris) `
            -BaselineTags @(Get-PropertyValue -Obj $finding -Name 'BaselineTags' @()) `
            -MitreTactics @(Get-PropertyValue -Obj $finding -Name 'MitreTactics' @()) `
            -MitreTechniques @(Get-PropertyValue -Obj $finding -Name 'MitreTechniques' @()) `
            -ToolVersion $toolVersionResolved

        if ($null -ne $row) {
            $normalized.Add($row)
        }
    }

    return @($normalized)
}
