#Requires -Version 7.4
[CmdletBinding()]
param ()

. "$PSScriptRoot\..\shared\Schema.ps1"
. "$PSScriptRoot\..\shared\Canonicalize.ps1"

function Normalize-ADOPipelineCorrelator {
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
        $org = if ($finding.PSObject.Properties['AdoOrg'] -and $finding.AdoOrg) { [string]$finding.AdoOrg } else { 'unknown' }
        $project = if ($finding.PSObject.Properties['AdoProject'] -and $finding.AdoProject) { [string]$finding.AdoProject } else { 'unknown' }
        $buildId = if ($finding.PSObject.Properties['BuildId'] -and $finding.BuildId) { [string]$finding.BuildId } else { '' }
        $secretFindingId = if ($finding.PSObject.Properties['SecretFindingId'] -and $finding.SecretFindingId) { [string]$finding.SecretFindingId } else { '' }
        $commitSha = if ($finding.PSObject.Properties['CommitSha'] -and $finding.CommitSha) { [string]$finding.CommitSha } else { '' }
        $repositoryCanonicalId = if ($finding.PSObject.Properties['RepositoryCanonicalId'] -and $finding.RepositoryCanonicalId) { [string]$finding.RepositoryCanonicalId } else { '' }
        $commitUrl = if ($finding.PSObject.Properties['CommitUrl'] -and $finding.CommitUrl) { [string]$finding.CommitUrl } else { '' }
        $secretCategory = if ($finding.PSObject.Properties['SecretType'] -and $finding.SecretType) { [string]$finding.SecretType } else { '' }
        $correlationStatus = if ($finding.PSObject.Properties['CorrelationStatus'] -and $finding.CorrelationStatus) { [string]$finding.CorrelationStatus } else { 'uncorrelated' }

        $pipelineIdRaw = if ($finding.PSObject.Properties['PipelineResourceId'] -and $finding.PipelineResourceId) {
            [string]$finding.PipelineResourceId
        } else {
            "ado://$($org.ToLowerInvariant())/$($project.ToLowerInvariant())/pipeline/unknown"
        }

        $entityId = ''
        try {
            $entityId = (ConvertTo-CanonicalEntityId -RawId $pipelineIdRaw -EntityType 'Pipeline').CanonicalId
        } catch {
            $entityId = $pipelineIdRaw.ToLowerInvariant()
        }

        $severity = switch -Regex ([string]$finding.Severity) {
            '^(?i)critical$' { 'Critical' }
            '^(?i)high$'     { 'High' }
            '^(?i)medium$'   { 'Medium' }
            '^(?i)low$'      { 'Low' }
            '^(?i)info$'     { 'Info' }
            default          { 'Info' }
        }

        $impact = switch -Regex ($correlationStatus) {
            '^(?i)correlated-direct$' { 'High' }
            '^(?i)correlated-fallback-project$' { 'Medium' }
            default { 'Low' }
        }

        $buildResultUrl = if ($buildId) {
            "https://dev.azure.com/$org/$project/_build/results?buildId=$buildId&view=results"
        } else {
            ''
        }
        $buildLogsUrl = if ($buildId) {
            "https://dev.azure.com/$org/$project/_build/results?buildId=$buildId&view=logs"
        } else {
            ''
        }
        $buildUrl = if ($finding.PSObject.Properties['BuildUrl'] -and $finding.BuildUrl) { [string]$finding.BuildUrl } else { '' }
        $evidenceUris = @($buildUrl, $buildLogsUrl, $commitUrl | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)

        $baselineTags = [System.Collections.Generic.List[string]]::new()
        if (-not [string]::IsNullOrWhiteSpace($correlationStatus)) { $baselineTags.Add($correlationStatus.ToLowerInvariant()) }
        if (-not [string]::IsNullOrWhiteSpace($secretCategory)) {
            $safeSecretCategory = ($secretCategory.ToLowerInvariant() -replace '[^a-z0-9\-_]+', '-').Trim('-')
            if ($safeSecretCategory) { $baselineTags.Add("secret-category:$safeSecretCategory") }
        }

        $pipelineSegments = @($entityId -split '/')
        $pipelineIdentifier = if ($pipelineSegments.Count -ge 4) { $pipelineSegments[$pipelineSegments.Count - 1] } else { 'unknown' }
        $entityRefs = @(
            $(if ($secretFindingId) { "finding:$secretFindingId" } else { $null }),
            "pipeline:$entityId",
            $(if ($buildId) { "build:$buildId" } else { $null }),
            $(if ($repositoryCanonicalId) { "repository:$repositoryCanonicalId" } else { $null }),
            $(if ($commitSha) { "commit:$commitSha" } else { $null }),
            "AzureDevOps|Pipeline|$($org.ToLowerInvariant())/$($project.ToLowerInvariant())/Pipeline/$pipelineIdentifier"
        ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique

        $buildKey = if ($buildId) { $buildId } else { 'none' }
        $secretKey = if ($secretFindingId) { $secretFindingId } else { 'none' }
        $baseTitle = if ($finding.PSObject.Properties['Title'] -and $finding.Title) { [string]$finding.Title } else { 'ADO pipeline secret correlation' }
        $title = if ($baseTitle -match '\[build:[^\]]+ secret:[^\]]+\]') {
            $baseTitle
        } else {
            "$baseTitle [build:$buildKey secret:$secretKey]"
        }

        $toolVersion = if ($finding.PSObject.Properties['ToolVersion'] -and $finding.ToolVersion) {
            [string]$finding.ToolVersion
        } elseif ($ToolResult.PSObject.Properties['ToolVersion'] -and $ToolResult.ToolVersion) {
            [string]$ToolResult.ToolVersion
        } else {
            ''
        }

        $remediationSnippet = [ordered]@{
            language = 'text'
            code = 'Audit pipeline variable groups, verify service connections used by this build, and review downstream artifact consumers before rotating and revoking exposed credentials.'
        }

        $row = New-FindingRow -Id ([string]$finding.Id) `
            -Source 'ado-pipeline-correlator' -EntityId $entityId -EntityType 'Pipeline' `
            -Title $title -Compliant ([bool]$finding.Compliant) -ProvenanceRunId $runId `
            -Platform 'ADO' -Category 'Pipeline Run Correlation' -Severity $severity `
            -Detail ([string]$finding.Detail) -Remediation ([string]$finding.Remediation) `
            -LearnMoreUrl ([string]$finding.LearnMoreUrl) -ResourceId ([string]$finding.ResourceId) `
            -Pillar 'Security' -Impact $impact -Effort 'Medium' `
            -DeepLinkUrl $buildResultUrl -RemediationSnippets @($remediationSnippet) `
            -EvidenceUris @($evidenceUris) -BaselineTags @($baselineTags.ToArray()) `
            -EntityRefs @($entityRefs) -ToolVersion $toolVersion

        if ($null -ne $row) {
            $normalized.Add($row)
        }
    }

    return @($normalized)
}
