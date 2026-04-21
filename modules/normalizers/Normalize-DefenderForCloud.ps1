#Requires -Version 7.4
<#
.SYNOPSIS
    Normalizer for Microsoft Defender for Cloud wrapper output.
.DESCRIPTION
    Converts v1 defender-for-cloud wrapper output to v2 FindingRows.
    - Secure Score roll-up -> EntityType=Subscription, Severity=Info, Compliant=true,
      with ScoreCurrent / ScoreMax / ScorePercent attached via Add-Member.
    - Each non-healthy assessment -> EntityType=AzureResource, Severity mapped from
      Defender's metadata.severity (High/Medium/Low -> High/Medium/Low), Compliant=false.
      The normalizer emits an entity-scoped finding on the canonical ARM ID so EntityStore
      folds it next to existing azqr/PSRule findings on the same resource.
#>
[CmdletBinding()]
param ()

. "$PSScriptRoot\..\shared\Schema.ps1"
. "$PSScriptRoot\..\shared\Canonicalize.ps1"

function Normalize-DefenderForCloud {
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
        $rg    = ''
        if ($rawId -match '^[0-9a-fA-F-]{36}$') { $subId = $rawId }
        elseif ($rawId -match '/subscriptions/([^/]+)') { $subId = $Matches[1] }
        if ($rawId -match '/resourceGroups/([^/]+)') { $rg = $Matches[1] }

        $isSubscription = ($rawId -match '^[0-9a-fA-F-]{36}$') -or `
                          ($rawId -match '^/subscriptions/[^/]+/?$') -or `
                          ($f.PSObject.Properties['ResourceType'] -and $f.ResourceType -eq 'Microsoft.Resources/subscriptions')

        if ($isSubscription) {
            $entityType  = 'Subscription'
            $canonicalId = $subId
        } else {
            $entityType = 'AzureResource'
            try   { $canonicalId = (ConvertTo-CanonicalEntityId -RawId $rawId -EntityType 'AzureResource').CanonicalId }
            catch { $canonicalId = $rawId.ToLowerInvariant() }
        }

        # Map Defender severity casing -> schema casing (Critical/High/Medium/Low/Info).
        $sevRaw = if ($f.PSObject.Properties['Severity'] -and $f.Severity) { [string]$f.Severity } else { 'Medium' }
        $sev = switch -Regex ($sevRaw) {
            '^(?i)critical$' { 'Critical' }
            '^(?i)high$'     { 'High' }
            '^(?i)medium$'   { 'Medium' }
            '^(?i)low$'      { 'Low' }
            '^(?i)info.*'    { 'Info' }
            default          { 'Medium' }
        }

        $compliant = $false
        if ($f.PSObject.Properties['Compliant']) { $compliant = [bool]$f.Compliant }

        $findingId = if ($f.PSObject.Properties['Id'] -and $f.Id) { [string]$f.Id } else { [guid]::NewGuid().ToString() }

        $remediation = if ($f.PSObject.Properties['Remediation']) { [string]$f.Remediation } else { '' }
        $ruleId = ''
        if ($f.PSObject.Properties['RuleId'] -and $f.RuleId) {
            $ruleId = [string]$f.RuleId
        } elseif ($f.PSObject.Properties['AssessmentId'] -and $f.AssessmentId) {
            $ruleId = [string]$f.AssessmentId
        } elseif ($f.PSObject.Properties['AlertId'] -and $f.AlertId) {
            $ruleId = [string]$f.AlertId
        }

        $frameworks = @()
        if ($f.PSObject.Properties['Frameworks'] -and $f.Frameworks) {
            $frameworks = @($f.Frameworks)
        }

        $pillar = if ($f.PSObject.Properties['Pillar']) { [string]$f.Pillar } else { '' }
        $impact = if ($f.PSObject.Properties['Impact']) { [string]$f.Impact } else { '' }
        $effort = if ($f.PSObject.Properties['Effort']) { [string]$f.Effort } else { '' }
        $deepLinkUrl = if ($f.PSObject.Properties['DeepLinkUrl']) { [string]$f.DeepLinkUrl } else { '' }
        $toolVersion = if ($f.PSObject.Properties['ToolVersion']) { [string]$f.ToolVersion } else { '' }

        $scoreDelta = $null
        if ($f.PSObject.Properties['ScoreDelta'] -and $null -ne $f.ScoreDelta) {
            try { $scoreDelta = [double]$f.ScoreDelta } catch {}
        }

        $evidenceUris = @()
        if ($f.PSObject.Properties['EvidenceUris'] -and $f.EvidenceUris) {
            $evidenceUris = @($f.EvidenceUris | ForEach-Object { [string]$_ } | Where-Object { $_ })
        }

        $mitreTactics = @()
        if ($f.PSObject.Properties['MitreTactics'] -and $f.MitreTactics) {
            $mitreTactics = @($f.MitreTactics | ForEach-Object { [string]$_ } | Where-Object { $_ })
        }

        $mitreTechniques = @()
        if ($f.PSObject.Properties['MitreTechniques'] -and $f.MitreTechniques) {
            $mitreTechniques = @($f.MitreTechniques | ForEach-Object { [string]$_ } | Where-Object { $_ })
        }

        $category = if ($f.PSObject.Properties['Category'] -and $f.Category) { [string]$f.Category } else { 'SecurityPosture' }

        $row = New-FindingRow -Id $findingId `
            -Source 'defender-for-cloud' -EntityId $canonicalId -EntityType $entityType `
            -Title ([string]$f.Title) -RuleId $ruleId -Compliant $compliant -ProvenanceRunId $runId `
            -Platform 'Azure' -Category $category -Severity $sev `
            -Detail ([string]$f.Detail) `
            -Remediation $remediation `
            -LearnMoreUrl ([string]$f.LearnMoreUrl) -ResourceId $rawId `
            -SubscriptionId $subId -ResourceGroup $rg `
            -Frameworks $frameworks `
            -Pillar $pillar `
            -Impact $impact `
            -Effort $effort `
            -DeepLinkUrl $deepLinkUrl `
            -EvidenceUris $evidenceUris `
            -ScoreDelta $scoreDelta `
            -MitreTactics $mitreTactics `
            -MitreTechniques $mitreTechniques `
            -ToolVersion $toolVersion

        if ($null -ne $row) {
            $normalized.Add($row)
        }
    }

    return @($normalized)
}
