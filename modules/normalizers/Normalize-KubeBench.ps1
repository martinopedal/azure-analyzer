#Requires -Version 7.4
<#
.SYNOPSIS
    Normalizer for kube-bench wrapper output.
.DESCRIPTION
    Converts v1 kube-bench wrapper output to v2 FindingRows.
    Maps kube-bench FAIL/WARN checks onto the AKS cluster AzureResource entity.
#>
[CmdletBinding()]
param ()

. "$PSScriptRoot\..\shared\Schema.ps1"
. "$PSScriptRoot\..\shared\Canonicalize.ps1"

function Normalize-KubeBench {
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

    function ConvertTo-KubeBenchStringArray {
        param([object]$Value)
        $result = [System.Collections.Generic.List[string]]::new()
        $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($item in @($Value)) {
            if ($null -eq $item) { continue }
            $text = [string]$item
            if ([string]::IsNullOrWhiteSpace($text)) { continue }
            $trimmed = $text.Trim()
            if ($seen.Add($trimmed)) { $result.Add($trimmed) }
        }
        return $result.ToArray()
    }

    function Resolve-KubeBenchImpactFromSeverity {
        param([string]$Severity)
        switch -Regex ($Severity) {
            '^(?i)(critical|high)$' { 'High' }
            '^(?i)medium$' { 'Medium' }
            default { 'Low' }
        }
    }

    function Resolve-KubeBenchSnippetLanguage {
        param([string]$Text)
        if ([string]::IsNullOrWhiteSpace($Text)) { return '' }
        if ($Text -match '(?im)^\s*(apiVersion|kind|metadata|spec)\s*:') { return 'yaml' }
        return 'bash'
    }

    function ConvertTo-KubeBenchFrameworks {
        param(
            [object]$RawFrameworks,
            [string]$ControlId,
            [string]$ResourceId
        )

        $frameworks = [System.Collections.Generic.List[hashtable]]::new()
        foreach ($fw in @($RawFrameworks)) {
            if ($null -eq $fw) { continue }

            $kind = ''
            $control = ''
            if ($fw -is [System.Collections.IDictionary]) {
                $kind = [string]($fw['kind'] ?? $fw['Kind'] ?? $fw['Name'])
                $control = [string]($fw['controlId'] ?? $fw['ControlId'])
            } else {
                $kind = [string]($fw.kind ?? $fw.Kind ?? $fw.Name)
                $control = [string]($fw.controlId ?? $fw.ControlId)
            }

            if ([string]::IsNullOrWhiteSpace($kind)) { continue }
            if ([string]::IsNullOrWhiteSpace($control)) { $control = $ControlId }
            if ([string]::IsNullOrWhiteSpace($control)) { continue }
            $frameworks.Add(@{ kind = $kind.Trim(); controlId = $control.Trim() }) | Out-Null
        }

        if ($frameworks.Count -eq 0 -and -not [string]::IsNullOrWhiteSpace($ControlId)) {
            $frameworks.Add(@{ kind = 'CIS Kubernetes Benchmark'; controlId = $ControlId }) | Out-Null
            if (-not [string]::IsNullOrWhiteSpace($ResourceId) -and $ResourceId -match '(?i)/providers/microsoft\.containerservice/managedclusters/') {
                $frameworks.Add(@{ kind = 'CIS-AKS'; controlId = $ControlId }) | Out-Null
            }
        }

        $deduped = [System.Collections.Generic.List[hashtable]]::new()
        $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
        foreach ($fw in $frameworks) {
            $key = "$($fw.kind)|$($fw.controlId)"
            if ($seen.Add($key)) { $deduped.Add($fw) | Out-Null }
        }
        return $deduped.ToArray()
    }

    foreach ($f in $ToolResult.Findings) {
        $statusRaw = if ($f.PSObject.Properties['Status'] -and $f.Status) { [string]$f.Status } else { '' }
        if ($statusRaw -and $statusRaw -notmatch '^(?i)(FAIL|WARN)$') { continue }

        $rawId = if ($f.PSObject.Properties['ResourceId'] -and $f.ResourceId) { [string]$f.ResourceId } else { '' }
        if (-not $rawId) { continue }

        $subId = ''
        $rg = ''
        if ($rawId -match '/subscriptions/([^/]+)') { $subId = $Matches[1] }
        if ($rawId -match '/resourceGroups/([^/]+)') { $rg = $Matches[1] }

        try { $canonicalId = (ConvertTo-CanonicalEntityId -RawId $rawId -EntityType 'AzureResource').CanonicalId }
        catch { $canonicalId = $rawId.ToLowerInvariant() }

        $severity = if ($f.PSObject.Properties['Severity'] -and $f.Severity) {
            switch -Regex ([string]$f.Severity) {
                '^(?i)critical$' { 'Critical' }
                '^(?i)high$'     { 'High' }
                '^(?i)medium$'   { 'Medium' }
                '^(?i)low$'      { 'Low' }
                '^(?i)info$'     { 'Info' }
                default          { 'Medium' }
            }
        } else {
            if ($statusRaw -match '^(?i)FAIL$') { 'High' } else { 'Medium' }
        }

        $findingId = if ($f.PSObject.Properties['Id'] -and $f.Id) { [string]$f.Id } else { [guid]::NewGuid().ToString() }
        $title = if ($f.PSObject.Properties['Title'] -and $f.Title) { [string]$f.Title } else { 'kube-bench finding' }
        $detail = if ($f.PSObject.Properties['Detail']) { [string]$f.Detail } else { '' }
        $remediation = if ($f.PSObject.Properties['Remediation']) { [string]$f.Remediation } else { '' }
        $learnMore = if ($f.PSObject.Properties['LearnMoreUrl']) { [string]$f.LearnMoreUrl } else { '' }
        $controlId = if ($f.PSObject.Properties['ControlId'] -and $f.ControlId) { [string]$f.ControlId } else { '' }
        $statusUpper = if ($statusRaw) { $statusRaw.ToUpperInvariant() } else { '' }
        $ruleId = if (-not [string]::IsNullOrWhiteSpace($controlId)) { "kube-bench:$controlId" } else { '' }
        $pillar = if ($f.PSObject.Properties['Pillar'] -and $f.Pillar) { [string]$f.Pillar } else { 'Security' }
        $impact = if ($f.PSObject.Properties['Impact'] -and $f.Impact) { [string]$f.Impact } else { Resolve-KubeBenchImpactFromSeverity -Severity $severity }
        $frameworks = ConvertTo-KubeBenchFrameworks -RawFrameworks $(if ($f.PSObject.Properties['Frameworks']) { $f.Frameworks } else { @() }) -ControlId $controlId -ResourceId $rawId
        $baselineTags = ConvertTo-KubeBenchStringArray -Value @(
            $(if ($f.PSObject.Properties['BaselineTags']) { @($f.BaselineTags) } else { @() }),
            $controlId,
            $statusUpper
        )
        $deepLink = if ($f.PSObject.Properties['DeepLinkUrl'] -and $f.DeepLinkUrl) { [string]$f.DeepLinkUrl } else { $learnMore }
        $entityRefs = ConvertTo-KubeBenchStringArray -Value @(
            $(if ($f.PSObject.Properties['EntityRefs']) { @($f.EntityRefs) } else { @() }),
            $rawId,
            $(if ($f.PSObject.Properties['NodeRef']) { [string]$f.NodeRef } else { '' })
        )
        $toolVersion = if ($f.PSObject.Properties['ToolVersion'] -and $f.ToolVersion) { [string]$f.ToolVersion } else { '' }

        $remediationSnippets = @()
        if ($f.PSObject.Properties['RemediationSnippets'] -and @($f.RemediationSnippets).Count -gt 0) {
            $remediationSnippets = @($f.RemediationSnippets | ForEach-Object {
                    if ($null -eq $_) { return }
                    if ($_ -is [System.Collections.IDictionary]) {
                        @{
                            language = [string]$_['language']
                            content  = [string]$_['content']
                        }
                        return
                    }
                    @{
                        language = [string]$_.language
                        content  = [string]$_.content
                    }
                })
        } elseif (-not [string]::IsNullOrWhiteSpace($remediation)) {
            $language = Resolve-KubeBenchSnippetLanguage -Text $remediation
            if (-not [string]::IsNullOrWhiteSpace($language)) {
                $remediationSnippets = @(@{
                        language = $language
                        content  = $remediation
                    })
            }
        }

        $row = New-FindingRow -Id $findingId `
            -Source 'kube-bench' -EntityId $canonicalId -EntityType 'AzureResource' `
            -Title $title -RuleId $ruleId -Compliant $false -ProvenanceRunId $runId `
            -Platform 'Azure' -Category 'KubernetesNodeSecurity' -Severity $severity `
            -Detail $detail -Remediation $remediation `
            -LearnMoreUrl $learnMore -ResourceId $rawId `
            -SubscriptionId $subId -ResourceGroup $rg `
            -Pillar $pillar -Impact $impact `
            -Frameworks @($frameworks) `
            -Controls $(if ($controlId) { @($controlId) } else { @() }) `
            -DeepLinkUrl $deepLink `
            -RemediationSnippets @($remediationSnippets) `
            -BaselineTags @($baselineTags) `
            -EntityRefs @($entityRefs) `
            -ToolVersion $toolVersion

        if ($null -ne $row) { $normalized.Add($row) }
    }

    return @($normalized)
}
