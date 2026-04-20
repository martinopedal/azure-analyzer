#Requires -Version 7.4
<#
.SYNOPSIS
    Azure DevOps repository secret scanner.
.DESCRIPTION
    Enumerates ADO projects and repos, clones each repo through RemoteClone,
    runs gitleaks with redaction, and emits v1 findings containing commit SHA,
    file path, and secret type metadata.
.PARAMETER AdoOrg
    Azure DevOps organization name.
.PARAMETER AdoProject
    Optional project filter. When omitted, all projects in the org are scanned.
.PARAMETER AdoPat
    Optional PAT. Falls back to ADO_PAT_TOKEN, AZURE_DEVOPS_EXT_PAT, AZ_DEVOPS_PAT.
.PARAMETER AdoOrganizationUrl
    Optional Azure DevOps organization URL. Supports cloud
    (https://dev.azure.com/{org} / https://{org}.visualstudio.com) and on-prem collection URLs.
.PARAMETER AdoServerUrl
    Optional Azure DevOps Server collection URL (for example,
    https://ado.contoso.local/tfs/DefaultCollection). When set, on-prem mode is forced.
.PARAMETER OutputPath
    Optional path to persist raw findings for downstream correlators.
.PARAMETER GitleaksConfigPath
    Optional local path to a gitleaks TOML config file for allowlist and rule overrides.
    Use this for repo-level or org-level pattern tuning after review.
#>
[CmdletBinding()]
param (
    [Parameter(Mandatory)]
    [Alias('AdoOrganization')]
    [ValidateNotNullOrEmpty()]
    [string] $AdoOrg,

    [string] $AdoProject,

    [Alias('AdoPatToken')]
    [string] $AdoPat,

<<<<<<< HEAD
    [string] $OutputPath,

    [string] $GitleaksConfigPath
=======
    [string] $AdoOrganizationUrl,

    [string] $AdoServerUrl,

    [string] $OutputPath
>>>>>>> dd07808 (feat(ado): ADO Server/on-prem support for repo secret scanning (#197))
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$sharedDir = Join-Path $PSScriptRoot 'shared'
. (Join-Path $sharedDir 'Retry.ps1')
. (Join-Path $sharedDir 'Sanitize.ps1')
. (Join-Path $sharedDir 'RemoteClone.ps1')
$installerPath = Join-Path $sharedDir 'Installer.ps1'
if (-not (Get-Command Invoke-WithTimeout -ErrorAction SilentlyContinue) -and (Test-Path $installerPath)) {
    . $installerPath
}

function Resolve-AdoPat {
    param ([string]$Explicit)
    if ($Explicit) { return $Explicit }
    if ($env:ADO_PAT_TOKEN) { return $env:ADO_PAT_TOKEN }
    if ($env:AZURE_DEVOPS_EXT_PAT) { return $env:AZURE_DEVOPS_EXT_PAT }
    if ($env:AZ_DEVOPS_PAT) { return $env:AZ_DEVOPS_PAT }
    return $null
}

function Resolve-AdoEndpoint {
    param (
        [Parameter(Mandatory)][string]$Org,
        [string]$OrganizationUrl,
        [string]$ServerUrl
    )

    function Get-ValidatedHttpsUri {
        param ([Parameter(Mandatory)][string]$Value, [Parameter(Mandatory)][string]$ParameterName)
        try { $uri = [uri]$Value } catch { throw "$ParameterName is not a valid URI." }
        if (-not $uri.IsAbsoluteUri -or $uri.Scheme -ne 'https') {
            throw "$ParameterName must be an absolute HTTPS URL."
        }
        return $uri
    }

    if ($ServerUrl) {
        $serverUri = Get-ValidatedHttpsUri -Value $ServerUrl -ParameterName 'AdoServerUrl'
        $baseUrl = $serverUri.GetLeftPart([System.UriPartial]::Path).TrimEnd('/')
        return [PSCustomObject]@{
            Deployment = 'OnPrem'
            BaseUrl = $baseUrl
            ApiVersion = '6.0'
            Organization = $Org
        }
    }

    if ($OrganizationUrl) {
        $orgUri = Get-ValidatedHttpsUri -Value $OrganizationUrl -ParameterName 'AdoOrganizationUrl'
        $uriHost = $orgUri.Host.ToLowerInvariant()

        if ($uriHost -eq 'dev.azure.com') {
            $segments = @($orgUri.AbsolutePath.Trim('/').Split('/', [System.StringSplitOptions]::RemoveEmptyEntries))
            $orgFromUrl = if ($segments.Count -gt 0) { $segments[0] } else { $Org }
            if (-not $orgFromUrl) { throw 'AdoOrganizationUrl is missing organization segment.' }
            return [PSCustomObject]@{
                Deployment = 'Cloud'
                BaseUrl = "https://dev.azure.com/$([uri]::EscapeDataString($orgFromUrl))"
                ApiVersion = '7.1'
                Organization = $orgFromUrl
            }
        }

        if ($uriHost.EndsWith('.visualstudio.com')) {
            $orgFromHost = $uriHost.Substring(0, $uriHost.Length - '.visualstudio.com'.Length)
            if (-not $orgFromHost) { $orgFromHost = $Org }
            return [PSCustomObject]@{
                Deployment = 'Cloud'
                BaseUrl = ("https://{0}" -f $uriHost)
                ApiVersion = '7.1'
                Organization = $orgFromHost
            }
        }

        $basePath = $orgUri.GetLeftPart([System.UriPartial]::Path).TrimEnd('/')
        if ($orgUri.AbsolutePath -eq '/' -or [string]::IsNullOrWhiteSpace($orgUri.AbsolutePath.Trim('/'))) {
            throw 'AdoOrganizationUrl for Azure DevOps Server must include a collection path (for example /tfs/DefaultCollection).'
        }
        return [PSCustomObject]@{
            Deployment = 'OnPrem'
            BaseUrl = $basePath
            ApiVersion = '6.0'
            Organization = $Org
        }
    }

    return [PSCustomObject]@{
        Deployment = 'Cloud'
        BaseUrl = "https://dev.azure.com/$([uri]::EscapeDataString($Org))"
        ApiVersion = '7.1'
        Organization = $Org
    }
}

function Get-AdoRepoCloneUrl {
    param (
        [Parameter(Mandatory)][psobject]$Repo,
        [Parameter(Mandatory)][string]$BaseUrl,
        [Parameter(Mandatory)][string]$ProjectName,
        [Parameter(Mandatory)][string]$RepoName
    )

    if ($Repo.PSObject.Properties['remoteUrl'] -and $Repo.remoteUrl) {
        return [string]$Repo.remoteUrl
    }

    return "$BaseUrl/$([uri]::EscapeDataString($ProjectName))/_git/$([uri]::EscapeDataString($RepoName))"
}

function Invoke-AdoApi {
    param (
        [Parameter(Mandatory)][string]$Uri,
        [Parameter(Mandatory)][hashtable]$Headers
    )

    Invoke-WithRetry -ScriptBlock {
        $webResponse = Invoke-WebRequest -Uri $Uri -Headers $Headers -Method Get -ContentType 'application/json'
        $bodyText = [string]$webResponse.Content
        $body = if ([string]::IsNullOrWhiteSpace($bodyText)) {
            [PSCustomObject]@{}
        } else {
            $bodyText | ConvertFrom-Json -Depth 100
        }

        $continuationToken = $null
        if ($webResponse.Headers -and $webResponse.Headers.ContainsKey('x-ms-continuationtoken')) {
            $tokenValue = $webResponse.Headers['x-ms-continuationtoken']
            if ($tokenValue -is [array]) { $continuationToken = $tokenValue[0] }
            else { $continuationToken = $tokenValue }
        }

        [PSCustomObject]@{
            Body = $body
            ContinuationToken = $continuationToken
        }
    }
}

function Get-AdoPagedValues {
    param (
        [Parameter(Mandatory)][string]$Uri,
        [Parameter(Mandatory)][hashtable]$Headers
    )

    $items = [System.Collections.Generic.List[object]]::new()
    $continuationToken = $null
    do {
        $pagedUri = $Uri
        if ($continuationToken) {
            $separator = if ($pagedUri -like '*?*') { '&' } else { '?' }
            $pagedUri += "$separator" + 'continuationToken=' + [uri]::EscapeDataString([string]$continuationToken)
        }
        $response = Invoke-AdoApi -Uri $pagedUri -Headers $Headers
        $body = if ($response) { $response.Body } else { $null }
        if ($body -and $body.PSObject.Properties['value']) {
            foreach ($item in @($body.value)) { $items.Add($item) }
        }
        $continuationToken = if ($response) { $response.ContinuationToken } else { $null }
    } while ($continuationToken)

    return @($items)
}

function Get-AdoProjects {
    param (
        [Parameter(Mandatory)][string]$BaseUrl,
        [Parameter(Mandatory)][string]$ApiVersion,
        [Parameter(Mandatory)][hashtable]$Headers
    )
    $uri = "$BaseUrl/_apis/projects?api-version=$ApiVersion&`$top=200"
    return @(Get-AdoPagedValues -Uri $uri -Headers $Headers)
}

function Get-AdoRepositories {
    param (
        [Parameter(Mandatory)][string]$BaseUrl,
        [Parameter(Mandatory)][string]$Project,
        [Parameter(Mandatory)][string]$ApiVersion,
        [Parameter(Mandatory)][hashtable]$Headers
    )
    $projectEnc = [uri]::EscapeDataString($Project)
    $uri = "$BaseUrl/$projectEnc/_apis/git/repositories?api-version=$ApiVersion&`$top=200"
    return @(Get-AdoPagedValues -Uri $uri -Headers $Headers)
}

function Get-HeadCommit {
    param ([string]$RepoPath)

    try {
        $args = @('-C', $RepoPath, 'rev-parse', 'HEAD')
        if (Get-Command Invoke-WithTimeout -ErrorAction SilentlyContinue) {
            $result = Invoke-WithTimeout -Command 'git' -Arguments $args -TimeoutSec 300
            if ($result.ExitCode -eq 0 -and $result.Output) { return [string]$result.Output.Trim() }
            return ''
        }

        $head = (& git @args 2>$null)
        if ($LASTEXITCODE -eq 0 -and $head) { return [string]$head.Trim() }
        return ''
    } catch {
        return ''
    }
}

function Resolve-SecretSeverity {
    param (
        [string]$RuleId,
        [string]$Description,
        [string[]]$Tags,
        [string]$Commit,
        [string]$HeadCommit
    )

    $rule = if ($RuleId) { $RuleId.ToLowerInvariant() } else { '' }
    $desc = if ($Description) { $Description.ToLowerInvariant() } else { '' }
    $tagsText = if ($Tags) { ($Tags -join ' ').ToLowerInvariant() } else { '' }

    if ($rule -match '(generic|example|sample|placeholder|dummy|test)' -or
        $desc -match '(generic|example|sample|placeholder|dummy|test)' -or
        $tagsText -match '(keyword|generic)') {
        return 'Medium'
    }

    if ($HeadCommit -and $Commit -and ($Commit.ToLowerInvariant() -eq $HeadCommit.ToLowerInvariant())) {
        return 'Critical'
    }

    return 'High'
}

function Test-GitleaksConfigDisablesDefaults {
    param (
        [Parameter(Mandatory)]
        [string] $ConfigPath
    )

    $content = Get-Content -Path $ConfigPath -Raw -ErrorAction Stop
    $extendMatch = [regex]::Match($content, '(?ms)^\s*\[extend\]\s*(?<body>.*?)(?=^\s*\[[^\[]|\z)')
    if (-not $extendMatch.Success) {
        return $false
    }

    $extendBody = [string]$extendMatch.Groups['body'].Value
    $usesNoDefaults = $extendBody -match '(?im)^\s*useDefault\s*=\s*false\s*$'
    if (-not $usesNoDefaults) {
        return $false
    }

    $hasCustomRules = $content -match '(?m)^\s*\[\[rules\]\]\s*$'
    return (-not $hasCustomRules)
}

function Resolve-GitleaksConfig {
    param (
        [string] $ConfigPath
    )

    if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
        return $null
    }

    if ($ConfigPath -match '^[a-zA-Z][a-zA-Z0-9+.-]*://') {
        throw "Gitleaks config path must be a local file path. URLs are not allowed: '$ConfigPath'"
    }

    if ([System.IO.Path]::GetExtension($ConfigPath).ToLowerInvariant() -ne '.toml') {
        throw "Gitleaks config path must point to a .toml file: '$ConfigPath'"
    }

    if (-not (Test-Path -Path $ConfigPath -PathType Leaf)) {
        throw "Gitleaks config file not found: '$ConfigPath'"
    }

    $resolvedConfigPath = Resolve-Path -Path $ConfigPath -ErrorAction Stop | Select-Object -ExpandProperty Path
    return [PSCustomObject]@{
        Path                               = $resolvedConfigPath
        DisablesDefaultsWithoutCustomRules = (Test-GitleaksConfigDisablesDefaults -ConfigPath $resolvedConfigPath)
    }
}

function Invoke-GitleaksForRepo {
    param (
        [Parameter(Mandatory)][string]$RepoPath,
        [Parameter(Mandatory)][string]$RepoCanonicalId,
        [Parameter(Mandatory)][string]$AdoOrg,
        [Parameter(Mandatory)][string]$AdoProject,
        [Parameter(Mandatory)][string]$RepoName,
        [Parameter(Mandatory)][string]$RepoId,
        [PSCustomObject] $GitleaksConfig
    )

    $reportFile = Join-Path ([System.IO.Path]::GetTempPath()) "ado-gitleaks-$([guid]::NewGuid().ToString('N')).json"
    $headCommit = Get-HeadCommit -RepoPath $RepoPath

    try {
        $args = @('detect', '--source', $RepoPath, '--report-format', 'json', '--report-path', $reportFile, '--no-banner', '--redact', '--exit-code', '0')
        if ($GitleaksConfig) {
            $args += @('--config', $GitleaksConfig.Path)
        }

        $exitCode = 0
        if (Get-Command Invoke-WithTimeout -ErrorAction SilentlyContinue) {
            $exec = Invoke-WithTimeout -Command 'gitleaks' -Arguments $args -TimeoutSec 300
            $exitCode = [int]$exec.ExitCode
        } else {
            & gitleaks @args | Out-Null
            $exitCode = $LASTEXITCODE
        }

        if ($exitCode -ne 0 -and -not (Test-Path $reportFile)) {
            throw "gitleaks exited with code $exitCode and produced no report"
        }

        $records = @()
        if (Test-Path $reportFile) {
            $jsonText = Get-Content $reportFile -Raw -ErrorAction SilentlyContinue
            if (-not [string]::IsNullOrWhiteSpace($jsonText)) {
                $records = @($jsonText | ConvertFrom-Json -Depth 100)
            }
        }

        $findings = [System.Collections.Generic.List[PSCustomObject]]::new()
        foreach ($item in $records) {
            $ruleId = if ($item.PSObject.Properties['RuleID'] -and $item.RuleID) { [string]$item.RuleID } else { 'unknown-rule' }
            $description = if ($item.PSObject.Properties['Description'] -and $item.Description) { [string]$item.Description } else { "Secret detected: $ruleId" }
            $filePath = if ($item.PSObject.Properties['File'] -and $item.File) { [string]$item.File } else { 'unknown-file' }
            $commit = if ($item.PSObject.Properties['Commit'] -and $item.Commit) { [string]$item.Commit } else { '' }
            $line = if ($item.PSObject.Properties['StartLine'] -and $item.StartLine) { [int]$item.StartLine } else { 0 }
            $fingerprint = if ($item.PSObject.Properties['Fingerprint'] -and $item.Fingerprint) { [string]$item.Fingerprint } else { [guid]::NewGuid().ToString() }
            $tags = if ($item.PSObject.Properties['Tags'] -and $item.Tags) { @($item.Tags | ForEach-Object { [string]$_ }) } else { @() }

            $severity = Resolve-SecretSeverity -RuleId $ruleId -Description $description -Tags $tags -Commit $commit -HeadCommit $headCommit
            $confidence = if ($severity -eq 'Medium') { 'Likely' } else { 'Confirmed' }

            $detail = "Rule '$ruleId' matched file '$filePath' at line $line. Commit: $commit."

            $findings.Add([PSCustomObject]@{
                    Id                    = $fingerprint
                    Source                = 'ado-repos-secrets'
                    Category              = 'Secret Detection'
                    Title                 = (Remove-Credentials "$description in $RepoName/$filePath")
                    Severity              = $severity
                    Compliant             = $false
                    Detail                = (Remove-Credentials $detail)
                    Remediation           = 'Rotate the exposed credential, revoke associated access, and remove the secret from git history.'
                    ResourceId            = (Remove-Credentials "$RepoCanonicalId/$($filePath -replace '\\', '/')")
                    LearnMoreUrl          = 'https://github.com/gitleaks/gitleaks'
                    SchemaVersion         = '1.0'
                    AdoOrg                = $AdoOrg
                    AdoProject            = $AdoProject
                    RepositoryName        = $RepoName
                    RepositoryId          = $RepoId
                    RepositoryCanonicalId = $RepoCanonicalId
                    CommitSha             = $commit
                    FilePath              = ($filePath -replace '\\', '/')
                    SecretType            = $ruleId
                    Confidence            = $confidence
                })
        }

        return @($findings)
    } finally {
        Remove-Item $reportFile -Force -ErrorAction SilentlyContinue
    }
}

$pat = Resolve-AdoPat -Explicit $AdoPat
if (-not $pat) {
    return [PSCustomObject]@{
        Source = 'ado-repos-secrets'
        Status = 'Skipped'
        Message = 'No ADO PAT provided. Set -AdoPat/-AdoPatToken, ADO_PAT_TOKEN, AZURE_DEVOPS_EXT_PAT, or AZ_DEVOPS_PAT.'
        Findings = @()
    }
}

$resolvedGitleaksConfig = Resolve-GitleaksConfig -ConfigPath $GitleaksConfigPath

if (-not (Get-Command gitleaks -ErrorAction SilentlyContinue)) {
    return [PSCustomObject]@{
        Source = 'ado-repos-secrets'
        Status = 'Skipped'
        Message = 'gitleaks CLI not installed. Install from https://github.com/gitleaks/gitleaks/releases'
        Findings = @()
    }
}

$pair = ":$pat"
$bytes = [System.Text.Encoding]::UTF8.GetBytes($pair)
$base64 = [System.Convert]::ToBase64String($bytes)
$headers = @{ Authorization = "Basic $base64" }

$findings = [System.Collections.Generic.List[PSCustomObject]]::new()
$failedRepos = [System.Collections.Generic.List[string]]::new()
$failedProjects = [System.Collections.Generic.List[string]]::new()
$skippedRepos = [System.Collections.Generic.List[string]]::new()
$endpoint = Resolve-AdoEndpoint -Org $AdoOrg -OrganizationUrl $AdoOrganizationUrl -ServerUrl $AdoServerUrl
$resolvedAdoOrg = [string]$endpoint.Organization

try {
    if ($resolvedGitleaksConfig) {
        $sanitizedConfigPath = Remove-Credentials ([string]$resolvedGitleaksConfig.Path)

        if ($resolvedGitleaksConfig.DisablesDefaultsWithoutCustomRules) {
            $findings.Add([PSCustomObject]@{
                    Id                    = [guid]::NewGuid().ToString()
                    Source                = 'ado-repos-secrets'
                    Category              = 'Configuration'
                    Title                 = 'Gitleaks pattern override disables all built-in rules'
                    Severity              = 'High'
                    Compliant             = $false
                    Detail                = (Remove-Credentials "Custom gitleaks config '$sanitizedConfigPath' sets [extend] useDefault = false without custom [[rules]]. This creates a high risk of missed secrets.")
                    Remediation           = 'Set useDefault = true or add at least one vetted custom [[rules]] entry before ADO scanning.'
                    ResourceId            = $sanitizedConfigPath
                    LearnMoreUrl          = 'https://github.com/gitleaks/gitleaks'
                    SchemaVersion         = '1.0'
                    AdoOrg                = $AdoOrg
                    AdoProject            = if ($AdoProject) { $AdoProject } else { '' }
                    RepositoryName        = ''
                    RepositoryId          = ''
                    RepositoryCanonicalId = ''
                    CommitSha             = ''
                    FilePath              = ''
                    SecretType            = 'config-risk'
                    Confidence            = 'Confirmed'
                })
        }

        $findings.Add([PSCustomObject]@{
                Id                    = [guid]::NewGuid().ToString()
                Source                = 'ado-repos-secrets'
                Category              = 'Configuration'
                Title                 = 'Custom gitleaks config applied'
                Severity              = 'Info'
                Compliant             = $true
                Detail                = (Remove-Credentials "Applied custom gitleaks config for ADO scanning: '$sanitizedConfigPath'.")
                Remediation           = 'Review allowlist and custom rules regularly to keep secret detection coverage strong.'
                ResourceId            = $sanitizedConfigPath
                LearnMoreUrl          = 'https://github.com/gitleaks/gitleaks'
                SchemaVersion         = '1.0'
                AdoOrg                = $AdoOrg
                AdoProject            = if ($AdoProject) { $AdoProject } else { '' }
                RepositoryName        = ''
                RepositoryId          = ''
                RepositoryCanonicalId = ''
                CommitSha             = ''
                FilePath              = ''
                SecretType            = 'config-applied'
                Confidence            = 'Confirmed'
            })
    }

    $projects = @()
    if ($AdoProject) {
        $projects = @([PSCustomObject]@{ name = $AdoProject; id = $AdoProject })
    } else {
        $projects = @(Get-AdoProjects -BaseUrl $endpoint.BaseUrl -ApiVersion $endpoint.ApiVersion -Headers $headers)
    }

    foreach ($project in $projects) {
        $projectName = if ($project.PSObject.Properties['name'] -and $project.name) { [string]$project.name } else { [string]$project }
        $projectId = if ($project.PSObject.Properties['id'] -and $project.id) { [string]$project.id } else { $projectName }

        try {
            $repos = @(Get-AdoRepositories -BaseUrl $endpoint.BaseUrl -Project $projectName -ApiVersion $endpoint.ApiVersion -Headers $headers)
            foreach ($repo in $repos) {
                $repoName = if ($repo.PSObject.Properties['name'] -and $repo.name) { [string]$repo.name } else { 'unknown-repo' }
                $repoId = if ($repo.PSObject.Properties['id'] -and $repo.id) { [string]$repo.id } else { $repoName }
                $repoCanonicalId = "ado://$($resolvedAdoOrg.ToLowerInvariant())/$($projectName.ToLowerInvariant())/repository/$($repoName.ToLowerInvariant())"
                $cloneUrl = Get-AdoRepoCloneUrl -Repo $repo -BaseUrl $endpoint.BaseUrl -ProjectName $projectName -RepoName $repoName

                if (-not (Test-RemoteRepoUrl -Url $cloneUrl)) {
                    $repoHost = ''
                    try { $repoHost = ([uri]$cloneUrl).Host } catch { $repoHost = 'unknown-host' }
                    $skipDetail = "Skipped repo '$projectName/$repoName': remote host '$repoHost' is not in RemoteClone allow-list (github.com, dev.azure.com, *.visualstudio.com, *.ghe.com)."
                    $findings.Add([PSCustomObject]@{
                            Id                    = [guid]::NewGuid().ToString()
                            Source                = 'ado-repos-secrets'
                            Category              = 'Secret Detection'
                            Title                 = (Remove-Credentials "Repository scan skipped for unsupported Azure DevOps Server host: $projectName/$repoName")
                            Severity              = 'Info'
                            Compliant             = $false
                            Detail                = (Remove-Credentials $skipDetail)
                            Remediation           = 'Use an allow-listed HTTPS host (for example dev.azure.com or *.visualstudio.com) or run the scan from an environment where the repository host is explicitly approved by policy.'
                            ResourceId            = (Remove-Credentials $repoCanonicalId)
                            LearnMoreUrl          = 'https://github.com/martinopedal/azure-analyzer/blob/main/PERMISSIONS.md'
                            SchemaVersion         = '1.0'
                            AdoOrg                = $resolvedAdoOrg
                            AdoProject            = $projectName
                            RepositoryName        = $repoName
                            RepositoryId          = $repoId
                            RepositoryCanonicalId = $repoCanonicalId
                            CommitSha             = ''
                            FilePath              = ''
                            SecretType            = 'scan-skipped-host-not-allow-listed'
                            Confidence            = 'Unknown'
                        })
                    $skippedRepos.Add("$projectName/$repoName")
                    continue
                }

                $cloneInfo = $null
                try {
                    $cloneInfo = Invoke-RemoteRepoClone -RepoUrl $cloneUrl -Token $pat
                    if (-not $cloneInfo) {
                        $failedRepos.Add("$projectName/$repoName")
                        continue
                    }

<<<<<<< HEAD
                    $repoFindings = Invoke-GitleaksForRepo -RepoPath $cloneInfo.Path -RepoCanonicalId $repoCanonicalId -AdoOrg $AdoOrg -AdoProject $projectName -RepoName $repoName -RepoId $repoId -GitleaksConfig $resolvedGitleaksConfig
=======
                    $repoFindings = Invoke-GitleaksForRepo -RepoPath $cloneInfo.Path -RepoCanonicalId $repoCanonicalId -AdoOrg $resolvedAdoOrg -AdoProject $projectName -RepoName $repoName -RepoId $repoId
>>>>>>> dd07808 (feat(ado): ADO Server/on-prem support for repo secret scanning (#197))
                    foreach ($finding in $repoFindings) {
                        $finding | Add-Member -NotePropertyName ProjectCanonicalId -NotePropertyValue "ado://$($resolvedAdoOrg.ToLowerInvariant())/$($projectName.ToLowerInvariant())/project/$($projectId.ToLowerInvariant())" -Force
                        $finding | Add-Member -NotePropertyName RepositoryObjectCanonicalId -NotePropertyValue "ado://$($resolvedAdoOrg.ToLowerInvariant())/$($projectName.ToLowerInvariant())/repository/$($repoId.ToLowerInvariant())" -Force
                        $findings.Add($finding)
                    }
                } catch {
                    Write-Warning (Remove-Credentials "Failed scanning repo '$projectName/$repoName': $($_.Exception.Message)")
                    $failedRepos.Add("$projectName/$repoName")
                } finally {
                    if ($cloneInfo -and $cloneInfo.Cleanup) {
                        try { & $cloneInfo.Cleanup } catch { }
                    }
                }
            }
        } catch {
            Write-Warning (Remove-Credentials "Failed enumerating repos for project '$projectName': $($_.Exception.Message)")
            $failedProjects.Add($projectName)
        }
    }

    if ($OutputPath) {
        $outDir = Split-Path -Path $OutputPath -Parent
        if ($outDir -and -not (Test-Path $outDir)) { $null = New-Item -ItemType Directory -Path $outDir -Force }
        $payload = Remove-Credentials ((@($findings) | ConvertTo-Json -Depth 30))
        Set-Content -Path $OutputPath -Value $payload -Encoding UTF8
    }

    $status = if ($failedProjects.Count -gt 0 -or $failedRepos.Count -gt 0 -or $skippedRepos.Count -gt 0) {
        if ($findings.Count -gt 0) { 'PartialSuccess' } else { 'Failed' }
    } else {
        'Success'
    }

    $message = "Scanned $($projects.Count) project(s); detected $($findings.Count) secret finding(s)."
    if ($failedProjects.Count -gt 0) { $message += " Failed projects: $($failedProjects -join ', ')." }
    if ($failedRepos.Count -gt 0) { $message += " Failed repos: $($failedRepos -join ', ')." }
    if ($skippedRepos.Count -gt 0) { $message += " Skipped repos (host allow-list): $($skippedRepos -join ', ')." }

    return [PSCustomObject]@{
        Source = 'ado-repos-secrets'
        Status = $status
        Message = $message
        Findings = @($findings)
    }
} catch {
    $errMsg = Remove-Credentials "$($_.Exception.Message)"
    return [PSCustomObject]@{
        Source = 'ado-repos-secrets'
        Status = 'Failed'
        Message = $errMsg
        Findings = @()
    }
}
