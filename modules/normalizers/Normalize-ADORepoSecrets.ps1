#Requires -Version 7.4
[CmdletBinding()]
param ()

. "$PSScriptRoot\..\shared\Schema.ps1"
. "$PSScriptRoot\..\shared\Canonicalize.ps1"

function Normalize-ADORepoSecrets {
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

    function Convert-ConfidenceValue {
        param ([string] $Value)
        switch -Regex (($Value ?? '').Trim()) {
            '^(?i)confirmed$'   { return 'Confirmed' }
            '^(?i)likely$'      { return 'Likely' }
            '^(?i)unconfirmed$' { return 'Unconfirmed' }
            '^(?i)unknown|n/a$' { return 'Unknown' }
            default             { return 'Unknown' }
        }
    }

    function Get-ConfidenceTierTag {
        param ([string] $ConfidenceValue)
        switch ($ConfidenceValue) {
            'Confirmed' { return 'high' }
            'Likely' { return 'medium' }
            default { return 'low' }
        }
    }

    function Get-ProviderRotationLink {
        param ([string] $SecretType)
        $rule = ($SecretType ?? '').ToLowerInvariant()
        if ($rule -match 'aws') {
            return 'https://docs.aws.amazon.com/IAM/latest/UserGuide/id_credentials_access-keys.html#Using_RotateAccessKey'
        }
        if ($rule -match 'azure.*storage') {
            return 'https://learn.microsoft.com/azure/storage/common/storage-account-keys-manage'
        }
        if ($rule -match 'github.*pat|pat') {
            return 'https://github.com/settings/personal-access-tokens'
        }
        return 'https://learn.microsoft.com/azure/devops/repos/security/secret-scanning?view=azure-devops'
    }

    function Get-ImpactValue {
        param (
            [string] $SecretType,
            [string] $ConfidenceValue,
            [bool] $Compliant
        )
        if ($Compliant) { return 'Low' }
        $rule = ($SecretType ?? '').ToLowerInvariant()
        $isCloudCredential = $rule -match 'aws-access-key|azure-storage-key|azure-client-secret|github-pat|private-key'
        $isGeneric = $rule -match 'generic'
        if ($ConfidenceValue -eq 'Confirmed' -and $isCloudCredential) { return 'Critical' }
        if ($ConfidenceValue -eq 'Confirmed') { return 'High' }
        if ($isGeneric) { return 'Medium' }
        if ($ConfidenceValue -eq 'Likely' -and $isCloudCredential) { return 'High' }
        return 'Medium'
    }

    function Get-EffortValue {
        param (
            [string] $SecretType,
            [string] $ConfidenceValue
        )
        $rule = ($SecretType ?? '').ToLowerInvariant()
        if ($ConfidenceValue -eq 'Confirmed' -and $rule -match 'aws-access-key|azure-storage-key|github-pat|private-key') {
            return 'High'
        }
        return 'Medium'
    }

    function Build-AdoRepoBlobLink {
        param (
            [string] $Org,
            [string] $Project,
            [string] $Repo,
            [string] $FilePath,
            [string] $CommitSha,
            [int] $LineNumber
        )
        if ([string]::IsNullOrWhiteSpace($Org) -or [string]::IsNullOrWhiteSpace($Project) -or [string]::IsNullOrWhiteSpace($Repo) -or [string]::IsNullOrWhiteSpace($FilePath) -or [string]::IsNullOrWhiteSpace($CommitSha)) {
            return ''
        }

        $normalizedPath = if ($FilePath.StartsWith('/')) { $FilePath } else { "/$FilePath" }
        $link = "https://dev.azure.com/$([uri]::EscapeDataString($Org))/$([uri]::EscapeDataString($Project))/_git/$([uri]::EscapeDataString($Repo))?path=$([uri]::EscapeDataString($normalizedPath))&version=GC$([uri]::EscapeDataString($CommitSha))"
        if ($LineNumber -gt 0) {
            $link += "&line=$LineNumber"
        }
        return $link
    }

    foreach ($finding in $ToolResult.Findings) {
        $repoIdRaw = if ($finding.PSObject.Properties['RepositoryCanonicalId'] -and $finding.RepositoryCanonicalId) {
            [string]$finding.RepositoryCanonicalId
        } else {
            'ado://unknown/unknown/repository/unknown'
        }

        $entityId = ''
        try {
            $entityId = (ConvertTo-CanonicalEntityId -RawId $repoIdRaw -EntityType 'Repository').CanonicalId
        } catch {
            $entityId = $repoIdRaw.ToLowerInvariant()
        }

        $severity = switch -Regex ([string]$finding.Severity) {
            '^(?i)critical$' { 'Critical' }
            '^(?i)high$'     { 'High' }
            '^(?i)medium$'   { 'Medium' }
            '^(?i)low$'      { 'Low' }
            '^(?i)info$'     { 'Info' }
            default          { 'Info' }
        }

        $resourceId = ''
        if ($finding.PSObject.Properties['FilePath'] -and $finding.FilePath) {
            $resourceId = ([string]$finding.FilePath).Trim().ToLowerInvariant() -replace '\\', '/'
        }

        $rawConfidence = if ($finding.PSObject.Properties['Confidence'] -and $finding.Confidence) { [string]$finding.Confidence } else { 'Unknown' }
        $confidence = Convert-ConfidenceValue -Value $rawConfidence
        $confidenceTier = Get-ConfidenceTierTag -ConfidenceValue $confidence
        $secretType = if ($finding.PSObject.Properties['SecretType'] -and $finding.SecretType) { [string]$finding.SecretType } elseif ($finding.PSObject.Properties['RuleId'] -and $finding.RuleId) { [string]$finding.RuleId } else { 'unknown-rule' }
        $ruleId = $secretType
        $commitSha = if ($finding.PSObject.Properties['CommitSha'] -and $finding.CommitSha) { [string]$finding.CommitSha } else { '' }
        $lineNumber = if ($finding.PSObject.Properties['LineNumber'] -and $finding.LineNumber) { [int]$finding.LineNumber } elseif ($finding.PSObject.Properties['StartLine'] -and $finding.StartLine) { [int]$finding.StartLine } else { 0 }
        if ($lineNumber -le 0 -and $finding.PSObject.Properties['Detail'] -and $finding.Detail -match '(?i)\bline\s+(\d+)\b') { $lineNumber = [int]$Matches[1] }
        $adoOrg = if ($finding.PSObject.Properties['AdoOrg'] -and $finding.AdoOrg) { [string]$finding.AdoOrg } else { '' }
        $adoProject = if ($finding.PSObject.Properties['AdoProject'] -and $finding.AdoProject) { [string]$finding.AdoProject } else { '' }
        $repoName = if ($finding.PSObject.Properties['RepositoryName'] -and $finding.RepositoryName) { [string]$finding.RepositoryName } else { '' }

        $commitUrl = if ($finding.PSObject.Properties['CommitUrl'] -and $finding.CommitUrl) {
            [string]$finding.CommitUrl
        } elseif ($adoOrg -and $adoProject -and $repoName -and $commitSha) {
            "https://dev.azure.com/$([uri]::EscapeDataString($adoOrg))/$([uri]::EscapeDataString($adoProject))/_git/$([uri]::EscapeDataString($repoName))/commit/$([uri]::EscapeDataString($commitSha))"
        } else {
            ''
        }
        $blobUrl = if ($finding.PSObject.Properties['BlobUrl'] -and $finding.BlobUrl) {
            [string]$finding.BlobUrl
        } else {
            Build-AdoRepoBlobLink -Org $adoOrg -Project $adoProject -Repo $repoName -FilePath $resourceId -CommitSha $commitSha -LineNumber 0
        }
        $deepLinkUrl = if ($finding.PSObject.Properties['DeepLinkUrl'] -and $finding.DeepLinkUrl) {
            [string]$finding.DeepLinkUrl
        } else {
            Build-AdoRepoBlobLink -Org $adoOrg -Project $adoProject -Repo $repoName -FilePath $resourceId -CommitSha $commitSha -LineNumber $lineNumber
        }
        $scannerArtifactPath = if ($finding.PSObject.Properties['ScannerArtifactPath'] -and $finding.ScannerArtifactPath) { [string]$finding.ScannerArtifactPath } else { '' }
        $evidenceUris = [System.Collections.Generic.List[string]]::new()
        foreach ($candidate in @($commitUrl, $blobUrl, $scannerArtifactPath)) {
            if (-not [string]::IsNullOrWhiteSpace($candidate) -and -not $evidenceUris.Contains($candidate)) {
                $evidenceUris.Add($candidate) | Out-Null
            }
        }

        $impact = Get-ImpactValue -SecretType $secretType -ConfidenceValue $confidence -Compliant ([bool]$finding.Compliant)
        $effort = Get-EffortValue -SecretType $secretType -ConfidenceValue $confidence
        $providerRotationLink = Get-ProviderRotationLink -SecretType $secretType
        $remediationGuidance = @(
            'Revoke the exposed secret at the provider immediately.'
            'Rotate the credential and redeploy consumers with the new value.'
            'Rewrite git history to remove the secret (for example git filter-repo), then force-push cleaned history.'
            "Provider rotation reference: $providerRotationLink"
        ) -join "`n"
        $remediationSnippets = @(
            @{
                language = 'text'
                code     = $remediationGuidance
            }
        )
        $toolVersion = if ($finding.PSObject.Properties['ToolVersion'] -and $finding.ToolVersion) { [string]$finding.ToolVersion } else { '' }
        $title = if ($resourceId -and $lineNumber -gt 0) {
            "$secretType in ${resourceId}:$lineNumber"
        } elseif ($resourceId) {
            "$secretType in $resourceId"
        } else {
            [string]$finding.Title
        }
        $baselineTags = @($secretType, $confidenceTier, "ruleId:$ruleId")
        $entityRefs = [System.Collections.Generic.List[string]]::new()
        $entityRefs.Add($entityId) | Out-Null
        if (-not [string]::IsNullOrWhiteSpace($commitSha)) {
            $entityRefs.Add("commit:$commitSha") | Out-Null
        }

        $row = New-FindingRow -Id ([string]$finding.Id) `
            -Source 'ado-repos-secrets' -EntityId $entityId -EntityType 'Repository' `
            -Title $title -RuleId $ruleId -Compliant ([bool]$finding.Compliant) -ProvenanceRunId $runId `
            -Platform 'ADO' -Category 'Secret Detection' -Severity $severity `
            -Detail ([string]$finding.Detail) -Remediation ([string]$finding.Remediation) `
            -LearnMoreUrl ([string]$finding.LearnMoreUrl) -ResourceId $resourceId `
            -Confidence $confidence -Pillar 'Security' -Impact $impact -Effort $effort `
            -DeepLinkUrl $deepLinkUrl -RemediationSnippets $remediationSnippets `
            -EvidenceUris @($evidenceUris) -BaselineTags $baselineTags `
            -EntityRefs @($entityRefs) -ToolVersion $toolVersion

        if ($null -ne $row) {
            $normalized.Add($row)
        }
    }

    return @($normalized)
}
