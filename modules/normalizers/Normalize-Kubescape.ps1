#Requires -Version 7.4
<#
.SYNOPSIS
    Normalizer for kubescape wrapper output.
.DESCRIPTION
    Converts v1 kubescape wrapper output to v2 FindingRows.
    Each non-passing control becomes a FindingRow on the AKS cluster's canonical ARM ID
    (EntityType=AzureResource, Platform=Azure) so kubescape findings fold onto the same
    entity as azqr/PSRule/Defender recommendations for that cluster.
    ControlId (e.g. C-0001, CIS-5.1.3) surfaces on Controls[] for framework mapping.
#>
[CmdletBinding()]
param ()

. "$PSScriptRoot\..\shared\Schema.ps1"
. "$PSScriptRoot\..\shared\Canonicalize.ps1"

function Normalize-Kubescape {
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
        if ($rawId -match '/subscriptions/([^/]+)') { $subId = $Matches[1] }
        if ($rawId -match '/resourceGroups/([^/]+)') { $rg    = $Matches[1] }

        try   { $canonicalId = (ConvertTo-CanonicalEntityId -RawId $rawId -EntityType 'AzureResource').CanonicalId }
        catch { $canonicalId = $rawId.ToLowerInvariant() }

        $sevRaw = if ($f.PSObject.Properties['Severity'] -and $f.Severity) { [string]$f.Severity } else { 'Medium' }
        $sev = switch -Regex ($sevRaw) {
            '^(?i)critical$' { 'Critical' }
            '^(?i)high$'     { 'High' }
            '^(?i)medium$'   { 'Medium' }
            '^(?i)low$'      { 'Low' }
            '^(?i)info'      { 'Info' }
            default          { 'Medium' }
        }

        $findingId = if ($f.PSObject.Properties['Id'] -and $f.Id) { [string]$f.Id } else { [guid]::NewGuid().ToString() }
        $remediation = if ($f.PSObject.Properties['Remediation']) { [string]$f.Remediation } else { '' }
        $controlId = if ($f.PSObject.Properties['ControlId'] -and $f.ControlId) { [string]$f.ControlId } else { '' }
        $ruleId = if (-not [string]::IsNullOrWhiteSpace($controlId)) { "kubescape:$controlId" } else { '' }
        $frameworks = @()
        if ($f.PSObject.Properties['Frameworks'] -and $f.Frameworks) {
            $frameworks = @($f.Frameworks | ForEach-Object {
                    if ($null -eq $_) { return }
                    $name = [string]$_.Name
                    if ([string]::IsNullOrWhiteSpace($name)) { return }
                    $controls = @($_.Controls)
                    if (-not $controls -or @($controls).Count -eq 0) {
                        if (-not [string]::IsNullOrWhiteSpace($controlId)) { $controls = @($controlId) } else { $controls = @() }
                    }
                    @{
                        Name      = $name
                        ControlId = if (-not [string]::IsNullOrWhiteSpace($controlId)) { $controlId } else { [string]$_.ControlId }
                        Controls  = @($controls)
                    }
                })
        }
        $baselineTags = if ($f.PSObject.Properties['BaselineTags']) { @([string[]]$f.BaselineTags) } else { @() }
        $mitreTactics = if ($f.PSObject.Properties['MitreTactics']) { @([string[]]$f.MitreTactics) } else { @() }
        $mitreTechniques = if ($f.PSObject.Properties['MitreTechniques']) { @([string[]]$f.MitreTechniques) } else { @() }
        $evidenceUris = if ($f.PSObject.Properties['EvidenceUris']) { @([string[]]$f.EvidenceUris) } else { @() }
        $learnMoreUrl = if ($f.PSObject.Properties['LearnMoreUrl']) { [string]$f.LearnMoreUrl } else { '' }
        if (@($evidenceUris).Count -eq 0 -and -not [string]::IsNullOrWhiteSpace($learnMoreUrl)) {
            $evidenceUris = @($learnMoreUrl)
        }
        if (@($evidenceUris).Count -eq 0 -and -not [string]::IsNullOrWhiteSpace($controlId)) {
            $evidenceUris = @("https://hub.armosec.io/docs/$($controlId.ToLowerInvariant())")
        }
        $toolVersion = if ($f.PSObject.Properties['ToolVersion']) { [string]$f.ToolVersion } else { '' }
        $pillar = if ($f.PSObject.Properties['Pillar'] -and $f.Pillar) { [string]$f.Pillar } else { 'Security' }
        $controls = if (-not [string]::IsNullOrWhiteSpace($controlId)) { @($controlId) } else { @() }

        # Track D enrichment (#432b): derive Impact/Effort, surface DeepLinkUrl,
        # build RemediationSnippets from the prose Remediation, pass through ScoreDelta,
        # and attach subscription EntityRef for cross-source folding.
        $impact = if ($f.PSObject.Properties['Impact'] -and $f.Impact) { [string]$f.Impact } else {
            switch ($sev) { 'Critical' { 'High' } 'High' { 'High' } 'Medium' { 'Medium' } default { 'Low' } }
        }
        $effort = if ($f.PSObject.Properties['Effort'] -and $f.Effort) { [string]$f.Effort } else {
            switch ($sev) { 'Critical' { 'High' } 'High' { 'Medium' } 'Medium' { 'Medium' } default { 'Low' } }
        }
        $deepLinkUrl = if ($f.PSObject.Properties['DeepLinkUrl'] -and $f.DeepLinkUrl) {
            [string]$f.DeepLinkUrl
        } elseif (-not [string]::IsNullOrWhiteSpace($controlId)) {
            "https://hub.armosec.io/docs/$($controlId.ToLowerInvariant())"
        } else {
            ''
        }
        $remediationSnippets = @()
        if ($f.PSObject.Properties['RemediationSnippets'] -and $f.RemediationSnippets) {
            $remediationSnippets = @($f.RemediationSnippets | ForEach-Object {
                    if ($null -eq $_) { return }
                    if ($_ -is [hashtable]) { return $_ }
                    $h = @{}
                    foreach ($p in $_.PSObject.Properties) { $h[$p.Name] = $p.Value }
                    return $h
                })
        }
        if (@($remediationSnippets).Count -eq 0 -and -not [string]::IsNullOrWhiteSpace($remediation)) {
            $remediationSnippets = @(@{ language = 'text'; code = $remediation.Trim() })
        }
        $scoreDelta = $null
        if ($f.PSObject.Properties['ScoreDelta'] -and $null -ne $f.ScoreDelta) {
            try { $scoreDelta = [double]$f.ScoreDelta } catch { $scoreDelta = $null }
        }
        $entityRefs = [System.Collections.Generic.List[string]]::new()
        if ($f.PSObject.Properties['EntityRefs'] -and $f.EntityRefs) {
            foreach ($r in @($f.EntityRefs)) { if (-not [string]::IsNullOrWhiteSpace([string]$r)) { $entityRefs.Add([string]$r) | Out-Null } }
        }
        if ($subId) {
            try {
                $subRef = (ConvertTo-CanonicalEntityId -RawId $subId -EntityType 'Subscription').CanonicalId
                if ($subRef -and $entityRefs -notcontains $subRef) { $entityRefs.Add($subRef) | Out-Null }
            } catch { }
        }

        $row = New-FindingRow -Id $findingId `
            -Source 'kubescape' -EntityId $canonicalId -EntityType 'AzureResource' `
            -Title ([string]$f.Title) -RuleId $ruleId -Compliant $false -ProvenanceRunId $runId `
            -Platform 'Azure' -Category 'KubernetesPosture' -Severity $sev `
            -Detail ([string]$f.Detail) -Remediation $remediation `
            -LearnMoreUrl ([string]$f.LearnMoreUrl) -ResourceId $rawId `
            -SubscriptionId $subId -ResourceGroup $rg `
            -Pillar $pillar -Frameworks @($frameworks) -Controls @($controls) `
            -MitreTactics @($mitreTactics) -MitreTechniques @($mitreTechniques) `
            -EvidenceUris @($evidenceUris) -BaselineTags @($baselineTags) `
            -Impact $impact -Effort $effort -DeepLinkUrl $deepLinkUrl `
            -RemediationSnippets @($remediationSnippets) -ScoreDelta $scoreDelta `
            -EntityRefs @($entityRefs) `
            -ToolVersion $toolVersion

        # Skip null rows (validation failed)

        if ($null -ne $row) {

            $normalized.Add($row)

        }
    }

    return @($normalized)
}
