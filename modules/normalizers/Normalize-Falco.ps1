#Requires -Version 7.4
<#
.SYNOPSIS
    Normalizer for Falco wrapper output.
.DESCRIPTION
    Converts v1 Falco findings to v2 FindingRows on AKS AzureResource entities.
    Falco priority mapping:
      - Critical -> Critical
      - Error    -> High
      - Warning  -> Medium
      - Notice   -> Low
#>
[CmdletBinding()]
param ()

. "$PSScriptRoot\..\shared\Schema.ps1"
. "$PSScriptRoot\..\shared\Canonicalize.ps1"

function Normalize-Falco {
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

    function New-FalcoRuleId {
        param([string]$RuleName)
        if ([string]::IsNullOrWhiteSpace($RuleName)) { return 'falco:runtime-alert' }
        $slug = ($RuleName.ToLowerInvariant() -replace '[^a-z0-9]+', '-').Trim('-')
        if ([string]::IsNullOrWhiteSpace($slug)) { $slug = 'runtime-alert' }
        return "falco:$slug"
    }

    function Get-FalcoMitre {
        param(
            [string]$RuleName,
            [string]$Priority,
            [string]$Detail
        )
        $text = "$RuleName $Detail".ToLowerInvariant()
        if ($text -match 'shell|exec') {
            return @{ Tactics = @('Execution'); Techniques = @('T1059') }
        }
        if ($text -match 'capabilit|privilege|root|escalat') {
            return @{ Tactics = @('PrivilegeEscalation'); Techniques = @('T1068') }
        }
        if ($text -match 'write|modify|executable|binary|filesystem') {
            return @{ Tactics = @('DefenseEvasion'); Techniques = @('T1070') }
        }
        $p = ($Priority ?? '').ToLowerInvariant()
        if ($p -eq 'critical' -or $p -eq 'error') {
            return @{ Tactics = @('Execution'); Techniques = @('T1059') }
        }
        return @{ Tactics = @(); Techniques = @() }
    }

    function Get-FalcoFrameworks {
        param(
            [object]$RawFrameworks,
            [string]$RuleId
        )
        if ($RawFrameworks) { return @($RawFrameworks) }
        return @(
            @{
                Name      = 'CIS Kubernetes Benchmark'
                ControlId = $RuleId
                Controls  = @($RuleId)
            }
        )
    }

    function Get-FalcoImpact {
        param([string]$Severity)
        switch ($Severity) {
            'Critical' { return 'High' }
            'High'     { return 'High' }
            'Medium'   { return 'Medium' }
            'Low'      { return 'Low' }
            default    { return 'Low' }
        }
    }

    function Get-FalcoEffort {
        param([string]$Severity)
        switch ($Severity) {
            'Critical' { return 'Medium' }
            'High'     { return 'Medium' }
            'Medium'   { return 'Low' }
            'Low'      { return 'Low' }
            default    { return 'Low' }
        }
    }

    foreach ($f in $ToolResult.Findings) {
        $rawId = if ($f.PSObject.Properties['ResourceId'] -and $f.ResourceId) { [string]$f.ResourceId } else { '' }
        if (-not $rawId) { continue }

        $subId = ''
        $rg    = ''
        if ($rawId -match '/subscriptions/([^/]+)') { $subId = $Matches[1] }
        if ($rawId -match '/resourceGroups/([^/]+)') { $rg    = $Matches[1] }

        try   { $canonicalId = (ConvertTo-CanonicalEntityId -RawId $rawId -EntityType 'AzureResource').CanonicalId }
        catch { $canonicalId = $rawId.ToLowerInvariant() }

        $priority = if ($f.PSObject.Properties['Priority'] -and $f.Priority) { [string]$f.Priority } else { '' }
        $sev = switch -Regex ($priority) {
            '^(?i)critical$' { 'Critical' }
            '^(?i)error$'    { 'High' }
            '^(?i)warning$'  { 'Medium' }
            '^(?i)notice$'   { 'Low' }
            default {
                if ($f.PSObject.Properties['Severity'] -and $f.Severity) { [string]$f.Severity } else { 'Info' }
            }
        }

        $findingId = if ($f.PSObject.Properties['Id'] -and $f.Id) { [string]$f.Id } else { [guid]::NewGuid().ToString() }
        $remediation = if ($f.PSObject.Properties['Remediation']) { [string]$f.Remediation } else { '' }
        $ruleName = if ($f.PSObject.Properties['RuleName'] -and $f.RuleName) { [string]$f.RuleName } else { '' }
        $ruleId = if ($f.PSObject.Properties['RuleId'] -and $f.RuleId) { [string]$f.RuleId } else { New-FalcoRuleId -RuleName $ruleName }
        $mitre = if (
            $f.PSObject.Properties['MitreTactics'] -and
            $f.PSObject.Properties['MitreTechniques'] -and
            $f.MitreTactics -and
            $f.MitreTechniques
        ) {
            @{
                Tactics    = @([string[]]$f.MitreTactics)
                Techniques = @([string[]]$f.MitreTechniques)
            }
        } else {
            Get-FalcoMitre -RuleName $ruleName -Priority $priority -Detail ([string]$f.Detail)
        }
        $frameworks = Get-FalcoFrameworks -RawFrameworks $(if ($f.PSObject.Properties['Frameworks']) { $f.Frameworks } else { $null }) -RuleId $ruleId
        $pillar = if ($f.PSObject.Properties['Pillar'] -and $f.Pillar) { [string]$f.Pillar } else { 'Security' }
        $impact = if ($f.PSObject.Properties['Impact'] -and $f.Impact) { [string]$f.Impact } else { Get-FalcoImpact -Severity $sev }
        $effort = if ($f.PSObject.Properties['Effort'] -and $f.Effort) { [string]$f.Effort } else { Get-FalcoEffort -Severity $sev }
        $learnMore = if ($f.PSObject.Properties['LearnMoreUrl']) { [string]$f.LearnMoreUrl } else { '' }
        $deepLinkUrl = if ($f.PSObject.Properties['DeepLinkUrl'] -and $f.DeepLinkUrl) {
            [string]$f.DeepLinkUrl
        } elseif (-not [string]::IsNullOrWhiteSpace($learnMore)) {
            $learnMore
        } else {
            ''
        }
        $remediationSnippets = if ($f.PSObject.Properties['RemediationSnippets'] -and $f.RemediationSnippets) {
            @($f.RemediationSnippets | ForEach-Object {
                    if ($_ -is [hashtable]) { return $_ }
                    @{
                        language = [string]$_.language
                        code     = [string]$_.code
                    }
                })
        } elseif (-not [string]::IsNullOrWhiteSpace($remediation)) {
            @(@{
                    language = 'text'
                    code     = $remediation
                })
        } else {
            @()
        }
        $evidenceUris = if ($f.PSObject.Properties['EvidenceUris'] -and $f.EvidenceUris) {
            @($f.EvidenceUris | ForEach-Object { [string]$_ })
        } else {
            @()
        }
        if (@($evidenceUris).Count -eq 0 -and -not [string]::IsNullOrWhiteSpace($learnMore)) {
            $evidenceUris = @($learnMore)
        }
        if (@($evidenceUris).Count -eq 0) {
            $evidenceUris = @($rawId)
        }
        $baselineTags = if ($f.PSObject.Properties['BaselineTags'] -and $f.BaselineTags) {
            @($f.BaselineTags | ForEach-Object { [string]$_ })
        } else {
            @('falco', 'aks-runtime-threat', $ruleId)
        }
        $entityRefs = if ($f.PSObject.Properties['EntityRefs'] -and $f.EntityRefs) {
            @($f.EntityRefs | ForEach-Object { [string]$_ })
        } else {
            @([string]$canonicalId)
        }
        $toolVersion = if ($f.PSObject.Properties['ToolVersion'] -and $f.ToolVersion) { [string]$f.ToolVersion } else { 'falco-alert-pipeline' }
        $scoreDelta = if ($f.PSObject.Properties['ScoreDelta']) {
            [Nullable[double]]$f.ScoreDelta
        } else {
            $null
        }

        $row = New-FindingRow -Id $findingId `
            -Source 'falco' -EntityId $canonicalId -EntityType 'AzureResource' `
            -Title ([string]$f.Title) -RuleId $ruleId -Compliant $false -ProvenanceRunId $runId `
            -Platform 'Azure' -Category 'KubernetesRuntimeThreatDetection' -Severity $sev `
            -Detail ([string]$f.Detail) -Remediation $remediation `
            -LearnMoreUrl ([string]$f.LearnMoreUrl) -ResourceId $rawId `
            -SubscriptionId $subId -ResourceGroup $rg `
            -Frameworks @($frameworks) -Pillar $pillar -Impact $impact -Effort $effort `
            -DeepLinkUrl $deepLinkUrl -RemediationSnippets @($remediationSnippets) `
            -EvidenceUris @($evidenceUris) -BaselineTags @($baselineTags) `
            -ScoreDelta $scoreDelta -MitreTactics @($mitre.Tactics) `
            -MitreTechniques @($mitre.Techniques) -EntityRefs @($entityRefs) `
            -ToolVersion $toolVersion

        foreach ($extra in 'RuleName', 'Pod', 'Process', 'Priority') {
            if ($f.PSObject.Properties[$extra] -and $f.$extra) {
                $row | Add-Member -NotePropertyName $extra -NotePropertyValue ([string]$f.$extra) -Force
            }
        }

        # Skip null rows (validation failed)

        if ($null -ne $row) {

            $normalized.Add($row)

        }
    }

    return @($normalized)
}
