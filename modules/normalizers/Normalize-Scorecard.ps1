#Requires -Version 7.4
<#
.SYNOPSIS
    Normalizer for OpenSSF Scorecard findings.
.DESCRIPTION
    Converts raw Scorecard wrapper output to v3 FindingRow objects.
    Platform=GitHub, EntityType=Repository.
#>
[CmdletBinding()]
param ()

. "$PSScriptRoot\..\shared\Schema.ps1"
. "$PSScriptRoot\..\shared\Canonicalize.ps1"

function ConvertTo-StringArray {
    param ([object] $InputObject)

    if ($null -eq $InputObject) { return @() }
    if ($InputObject -is [string]) { return @([string]$InputObject) }

    $output = [System.Collections.Generic.List[string]]::new()
    foreach ($item in @($InputObject)) {
        if ($null -eq $item) { continue }
        $text = [string]$item
        if (-not [string]::IsNullOrWhiteSpace($text)) {
            $output.Add($text.Trim())
        }
    }

    return $output.ToArray()
}

function Get-ScorecardSeverityFromScore {
    param ([Nullable[int]] $Score)

    if ($null -eq $Score) { return $null }
    if ($Score -eq -1) { return 'Info' }
    $scoreValue = [int]$Score
    if ($scoreValue -le 2) { return 'Critical' }
    if ($scoreValue -le 5) { return 'High' }
    if ($scoreValue -le 7) { return 'Medium' }
    if ($scoreValue -le 9) { return 'Low' }
    return 'Info'
}

function Get-ScorecardRepoWebBaseUrl {
    param ([string] $ResourceId)

    if ([string]::IsNullOrWhiteSpace($ResourceId)) { return $null }

    $clean = $ResourceId.Trim() -replace '^https?://', ''
    if ($clean -notmatch '^([^/]+)/([^/]+)/([^/]+)$') { return $null }

    $repoHost = $matches[1]
    $owner = $matches[2]
    $repo = $matches[3]
    return "https://$repoHost/$owner/$repo"
}

function Get-ScorecardEvidenceUris {
    param (
        [object] $CheckDetails,
        [string] $ResourceId
    )

    $details = ConvertTo-StringArray -InputObject $CheckDetails
    if (@($details).Count -eq 0) { return @() }

    $repoBaseUrl = Get-ScorecardRepoWebBaseUrl -ResourceId $ResourceId
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $uris = [System.Collections.Generic.List[string]]::new()

    foreach ($detail in $details) {
        foreach ($urlMatch in [System.Text.RegularExpressions.Regex]::Matches($detail, 'https?://[^\s\)\]]+')) {
            $value = [string]$urlMatch.Value
            if ($seen.Add($value)) { $uris.Add($value) }
        }

        if ($repoBaseUrl) {
            foreach ($shaMatch in [System.Text.RegularExpressions.Regex]::Matches($detail, '(?<![0-9a-fA-F])([0-9a-fA-F]{7,40})(?![0-9a-fA-F])')) {
                $sha = [string]$shaMatch.Groups[1].Value
                $commitUrl = "$repoBaseUrl/commit/$sha"
                if ($seen.Add($commitUrl)) { $uris.Add($commitUrl) }
            }

            foreach ($pathMatch in [System.Text.RegularExpressions.Regex]::Matches($detail, '(?<![A-Za-z0-9_\-./])(\.?[A-Za-z0-9_\-]+(?:/[A-Za-z0-9_\-\.]+)+\.[A-Za-z0-9_\-]+)(?![A-Za-z0-9_\-./])')) {
                $path = ([string]$pathMatch.Groups[1].Value).TrimStart('/')
                if ([string]::IsNullOrWhiteSpace($path)) { continue }
                $fileUrl = "$repoBaseUrl/blob/HEAD/$($path -replace ' ', '%20')"
                if ($seen.Add($fileUrl)) { $uris.Add($fileUrl) }
            }
        }
    }

    return $uris.ToArray()
}

function ConvertTo-HashtableArray {
    param ([object] $InputObject)

    if ($null -eq $InputObject) { return @() }

    $result = [System.Collections.Generic.List[hashtable]]::new()
    foreach ($item in @($InputObject)) {
        if ($null -eq $item) { continue }
        if ($item -is [hashtable]) {
            $result.Add($item)
            continue
        }

        $hash = @{}
        foreach ($property in $item.PSObject.Properties) {
            $hash[$property.Name] = $property.Value
        }
        $result.Add($hash)
    }

    return $result.ToArray()
}

function Normalize-Scorecard {
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

    foreach ($finding in $ToolResult.Findings) {
        $rawId = ''
        if ($finding.PSObject.Properties['ResourceId'] -and $finding.ResourceId) {
            $rawId = [string]$finding.ResourceId
        }

        # Try to canonicalize as a GitHub repo ID
        $canonicalId = ''
        if ($rawId) {
            try {
                $canonicalId = ConvertTo-CanonicalRepoId -RepoId $rawId
            } catch {
                # If it doesn't parse as a repo, derive host from URL or default to github.com
                $repoHost = 'github.com'
                $cleaned = $rawId -replace '^https?://', ''
                if ($cleaned -match '^([^/]+)/') {
                    $candidateHost = $matches[1].ToLowerInvariant()
                    if ($candidateHost -ne 'github.com' -and $candidateHost -match '\.') {
                        $repoHost = $candidateHost
                    }
                }
                $canonicalId = "$repoHost/$($rawId.TrimStart('/').ToLowerInvariant())"
            }
        }

        $findingId = if ($finding.PSObject.Properties['Id'] -and $finding.Id) {
            [string]$finding.Id
        } else {
            [guid]::NewGuid().ToString()
        }
        if (-not $canonicalId) {
            $canonicalId = "scorecard/$findingId"
        }

        $title = if ($finding.PSObject.Properties['Title'] -and $finding.Title) { $finding.Title } else { 'Unknown' }
        $category = if ($finding.PSObject.Properties['Category'] -and $finding.Category) { $finding.Category } else { 'Supply Chain' }

        $score = $null
        if ($finding.PSObject.Properties['Score'] -and $null -ne $finding.Score) {
            $parsedScore = 0
            if ([int]::TryParse([string]$finding.Score, [ref]$parsedScore)) {
                $score = $parsedScore
            }
        } elseif ($finding.PSObject.Properties['Detail'] -and $finding.Detail -and ([string]$finding.Detail -match 'Score\s+(-?\d+)\/10')) {
            $parsedScore = 0
            if ([int]::TryParse($matches[1], [ref]$parsedScore)) {
                $score = $parsedScore
            }
        }

        $severity = Get-ScorecardSeverityFromScore -Score $score
        if (-not $severity) {
            $rawSev = if ($finding.PSObject.Properties['Severity'] -and $finding.Severity) { $finding.Severity } else { 'Medium' }
            $severity = switch -Regex ($rawSev.ToString().ToLowerInvariant()) {
                'critical'         { 'Critical' }
                'high'             { 'High' }
                'medium|moderate'  { 'Medium' }
                'low'              { 'Low' }
                'info'             { 'Info' }
                default            { 'Medium' }
            }
        }

        $compliant = if ($finding.PSObject.Properties['Compliant']) { [bool]$finding.Compliant } else { $true }
        $detail = if ($finding.PSObject.Properties['Detail'] -and $finding.Detail) { $finding.Detail } else { '' }
        $remediation = if ($finding.PSObject.Properties['Remediation'] -and $finding.Remediation) { $finding.Remediation } else { '' }
        $learnMore = if ($finding.PSObject.Properties['LearnMoreUrl'] -and $finding.LearnMoreUrl) { $finding.LearnMoreUrl } else { '' }
        $frameworks = if ($finding.PSObject.Properties['Frameworks'] -and $finding.Frameworks) { @($finding.Frameworks) } else { @() }
        $pillar = if ($finding.PSObject.Properties['Pillar'] -and $finding.Pillar) { [string]$finding.Pillar } else { 'Security' }
        $deepLinkUrl = if ($finding.PSObject.Properties['DeepLinkUrl'] -and $finding.DeepLinkUrl) { [string]$finding.DeepLinkUrl } else { '' }
        $remediationSnippets = if ($finding.PSObject.Properties['RemediationSnippets'] -and $finding.RemediationSnippets) {
            ConvertTo-HashtableArray -InputObject $finding.RemediationSnippets
        } else {
            @()
        }
        $baselineTags = if ($finding.PSObject.Properties['BaselineTags'] -and $finding.BaselineTags) { ConvertTo-StringArray -InputObject $finding.BaselineTags } else { @() }
        $toolVersion = if ($finding.PSObject.Properties['ToolVersion'] -and $finding.ToolVersion) { [string]$finding.ToolVersion } else { '' }
        $checkDetails = if ($finding.PSObject.Properties['CheckDetails']) { $finding.CheckDetails } else { $null }
        $evidenceUris = Get-ScorecardEvidenceUris -CheckDetails $checkDetails -ResourceId $rawId

        # Track D enrichment (#432b): derive Impact/Effort, surface ScoreDelta from
        # the OpenSSF score (10 - score), pass through MITRE, and seed EntityRefs
        # with the parent organisation derived from the canonical repo id.
        $impact = if ($finding.PSObject.Properties['Impact'] -and $finding.Impact) { [string]$finding.Impact } else {
            switch ($severity) { 'Critical' { 'High' } 'High' { 'High' } 'Medium' { 'Medium' } default { 'Low' } }
        }
        $effort = if ($finding.PSObject.Properties['Effort'] -and $finding.Effort) { [string]$finding.Effort } else {
            switch ($severity) { 'Critical' { 'Medium' } 'High' { 'Medium' } 'Medium' { 'Medium' } default { 'Low' } }
        }
        $scoreDelta = $null
        if ($finding.PSObject.Properties['ScoreDelta'] -and $null -ne $finding.ScoreDelta) {
            try { $scoreDelta = [double]$finding.ScoreDelta } catch { $scoreDelta = $null }
        } elseif ($null -ne $score -and $score -ge 0) {
            $scoreDelta = [double](10 - [int]$score)
        }
        $mitreTactics = if ($finding.PSObject.Properties['MitreTactics'] -and $finding.MitreTactics) { @([string[]]$finding.MitreTactics) } else { @() }
        $mitreTechniques = if ($finding.PSObject.Properties['MitreTechniques'] -and $finding.MitreTechniques) { @([string[]]$finding.MitreTechniques) } else { @() }
        $entityRefs = [System.Collections.Generic.List[string]]::new()
        if ($finding.PSObject.Properties['EntityRefs'] -and $finding.EntityRefs) {
            foreach ($r in @($finding.EntityRefs)) { if (-not [string]::IsNullOrWhiteSpace([string]$r)) { $entityRefs.Add([string]$r) | Out-Null } }
        }
        if ($canonicalId -match '^([^/]+)/([^/]+)/[^/]+$') {
            $orgRef = "$($Matches[1])/$($Matches[2])".ToLowerInvariant()
            if ($entityRefs -notcontains $orgRef) { $entityRefs.Add($orgRef) | Out-Null }
        }

        $row = New-FindingRow -Id $findingId `
            -Source 'scorecard' -EntityId $canonicalId -EntityType 'Repository' `
            -Title $title -Compliant ([bool]$compliant) -ProvenanceRunId $runId `
            -Platform 'GitHub' -Category $category -Severity $severity `
            -Detail $detail -Remediation $remediation `
            -LearnMoreUrl $learnMore -ResourceId ($rawId ?? '') `
            -Frameworks $frameworks -Pillar $pillar -DeepLinkUrl $deepLinkUrl `
            -RemediationSnippets $remediationSnippets -EvidenceUris $evidenceUris `
            -BaselineTags $baselineTags `
            -Impact $impact -Effort $effort -ScoreDelta $scoreDelta `
            -MitreTactics @($mitreTactics) -MitreTechniques @($mitreTechniques) `
            -EntityRefs @($entityRefs) `
            -ToolVersion $toolVersion
        # Skip null rows (validation failed)
        if ($null -ne $row) {
            $normalized.Add($row)
        }
    }

    return @($normalized)
}
