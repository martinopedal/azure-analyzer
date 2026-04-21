#Requires -Version 7.4
<#
.SYNOPSIS
    Normalizer for ADO service connection findings.
.DESCRIPTION
    Converts raw ADO service connection wrapper output to v3 FindingRow objects.
    Platform=ADO, EntityType=ServiceConnection.
    CanonicalId = ado://{org}/{project}/serviceconnection/{connectionId} (lowercased).
#>
[CmdletBinding()]
param ()

. "$PSScriptRoot\..\shared\Schema.ps1"
. "$PSScriptRoot\..\shared\Canonicalize.ps1"

function Normalize-ADOConnections {
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

    foreach ($finding in $ToolResult.Findings) {
        # Extract org/project/name for canonical ID
        $org = if ($finding.PSObject.Properties['AdoOrg'] -and $finding.AdoOrg) {
            $finding.AdoOrg
        } else { 'unknown' }

        $project = if ($finding.PSObject.Properties['AdoProject'] -and $finding.AdoProject) {
            $finding.AdoProject
        } else { 'unknown' }

        $connType = if ($finding.PSObject.Properties['ConnectionType'] -and $finding.ConnectionType) {
            $finding.ConnectionType
        } else { 'Unknown' }

        $authScheme = if ($finding.PSObject.Properties['AuthScheme'] -and $finding.AuthScheme) {
            $finding.AuthScheme
        } else { 'Unknown' }

        $authMechanism = if ($finding.PSObject.Properties['AuthMechanism'] -and $finding.AuthMechanism) {
            $finding.AuthMechanism
        } else { 'Unknown' }

        $isShared = if ($finding.PSObject.Properties['IsShared']) {
            [bool]$finding.IsShared
        } else { $false }

        # Build canonical ID keyed by org/project/connectionId for entity dedupe stability.
        $rawResourceId = if ($finding.PSObject.Properties['ResourceId'] -and $finding.ResourceId) {
            [string]$finding.ResourceId
        } else { '' }
        $connectionId = if ($finding.PSObject.Properties['ConnectionId'] -and $finding.ConnectionId) {
            [string]$finding.ConnectionId
        } else { '' }

        $canonicalId = ''
        if ($connectionId) {
            $canonicalId = "ado://$($org.ToLowerInvariant())/$($project.ToLowerInvariant())/serviceconnection/$($connectionId.ToLowerInvariant())"
        } elseif ($rawResourceId) {
            try {
                $canonicalId = ConvertTo-CanonicalAdoId -AdoId $rawResourceId
            } catch {
                $canonicalId = $rawResourceId.ToLowerInvariant()
            }
        }
        if (-not $canonicalId) {
            # Fallback: construct from parts
            $canonicalId = "ado://$($org.ToLowerInvariant())/$($project.ToLowerInvariant())/serviceconnection/unknown"
        }

        $findingId = if ($finding.PSObject.Properties['Id'] -and $finding.Id) {
            [string]$finding.Id
        } else {
            [guid]::NewGuid().ToString()
        }

        $title = if ($finding.PSObject.Properties['Title'] -and $finding.Title) {
            $finding.Title
        } else { 'Unknown service connection' }

        $category = 'Service Connection'
        $severity = 'Info'
        $compliant = $true

        $detail = if ($finding.PSObject.Properties['Detail'] -and $finding.Detail) {
            $finding.Detail
        } else {
            "Type=$connType; AuthScheme=$authScheme; AuthMechanism=$authMechanism; IsShared=$isShared"
        }

        $remediation = if ($finding.PSObject.Properties['Remediation'] -and $finding.Remediation) {
            $finding.Remediation
        } else { '' }

        $learnMore = if ($finding.PSObject.Properties['LearnMoreUrl'] -and $finding.LearnMoreUrl) {
            $finding.LearnMoreUrl
        } else { '' }

        $ruleId = if ($finding.PSObject.Properties['ConnectionType'] -and $finding.ConnectionType) {
            "ado.connection.$($finding.ConnectionType)"
        } else {
            'ado.connection'
        }
        $pillar = if ($finding.PSObject.Properties['Pillar'] -and $finding.Pillar) { [string]$finding.Pillar } else { 'Security' }
        $impact = if ($finding.PSObject.Properties['Impact'] -and $finding.Impact) { [string]$finding.Impact } else { '' }
        $effort = if ($finding.PSObject.Properties['Effort'] -and $finding.Effort) { [string]$finding.Effort } else { '' }
        $deepLinkUrl = if ($finding.PSObject.Properties['DeepLinkUrl'] -and $finding.DeepLinkUrl) { [string]$finding.DeepLinkUrl } else { '' }
        $remediationSnippets = @()
        if ($finding.PSObject.Properties['RemediationSnippets'] -and $finding.RemediationSnippets) {
            $snippetList = [System.Collections.Generic.List[hashtable]]::new()
            foreach ($snippet in @($finding.RemediationSnippets)) {
                if ($null -eq $snippet) { continue }
                $language = ''
                $content = ''
                if ($snippet -is [hashtable]) {
                    $language = [string]($snippet.language ?? $snippet.Language ?? '')
                    $content = [string]($snippet.content ?? $snippet.code ?? '')
                } else {
                    if ($snippet.PSObject.Properties['language']) { $language = [string]$snippet.language }
                    elseif ($snippet.PSObject.Properties['Language']) { $language = [string]$snippet.Language }
                    if ($snippet.PSObject.Properties['content']) { $content = [string]$snippet.content }
                    elseif ($snippet.PSObject.Properties['code']) { $content = [string]$snippet.code }
                }
                if ([string]::IsNullOrWhiteSpace($language)) { $language = 'text' }
                if ([string]::IsNullOrWhiteSpace($content)) { continue }
                $snippetList.Add(@{
                        language = $language
                        content  = $content
                    }) | Out-Null
            }
            $remediationSnippets = @($snippetList)
        }
        $evidenceUris = if ($finding.PSObject.Properties['EvidenceUris'] -and $finding.EvidenceUris) { @($finding.EvidenceUris) } else { @() }
        $baselineTags = if ($finding.PSObject.Properties['BaselineTags'] -and $finding.BaselineTags) { @($finding.BaselineTags) } else { @() }
        $entityRefs = if ($finding.PSObject.Properties['EntityRefs'] -and $finding.EntityRefs) { @($finding.EntityRefs) } else { @() }
        $toolVersion = if ($finding.PSObject.Properties['ToolVersion'] -and $finding.ToolVersion) { [string]$finding.ToolVersion } else { '' }

        $row = New-FindingRow -Id $findingId `
            -Source 'ado-connections' -EntityId $canonicalId -EntityType 'ServiceConnection' `
            -Title $title -RuleId $ruleId -Compliant ([bool]$compliant) -ProvenanceRunId $runId `
            -Platform 'ADO' -Category $category -Severity $severity `
            -Detail $detail -Remediation $remediation `
            -LearnMoreUrl $learnMore -ResourceId ($rawResourceId) `
            -Pillar $pillar -Impact $impact -Effort $effort -DeepLinkUrl $deepLinkUrl `
            -RemediationSnippets $remediationSnippets -EvidenceUris $evidenceUris `
            -BaselineTags $baselineTags -EntityRefs $entityRefs -ToolVersion $toolVersion
        # Skip null rows (validation failed)
        if ($null -ne $row) {
            $normalized.Add($row)
        }
    }

    return @($normalized)
}
