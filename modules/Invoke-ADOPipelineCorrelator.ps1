#Requires -Version 7.4
<#
.SYNOPSIS
    Correlates ADO secret findings to pipeline runs.
.DESCRIPTION
    Reads secret findings produced by Invoke-ADORepoSecrets, matches finding commit SHAs
    with pipeline builds (sourceVersion), and enriches with run-log metadata.
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

    [string] $SecretsFindingsPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$sharedDir = Join-Path $PSScriptRoot 'shared'
. (Join-Path $sharedDir 'Retry.ps1')
. (Join-Path $sharedDir 'Sanitize.ps1')

. (Join-Path $sharedDir 'New-WrapperEnvelope.ps1')
if (-not (Get-Command New-WrapperEnvelope -ErrorAction SilentlyContinue)) { function New-WrapperEnvelope { param([string]$Source,[string]$Status='Failed',[string]$Message='',[object[]]$FindingErrors=@()) return [PSCustomObject]@{ Source=$Source; SchemaVersion='1.0'; Status=$Status; Message=$Message; Findings=@(); Errors=@($FindingErrors) } } }
function Resolve-AdoPat {
    param ([string]$Explicit)
    if ($Explicit) { return $Explicit }
    if ($env:ADO_PAT_TOKEN) { return $env:ADO_PAT_TOKEN }
    if ($env:AZURE_DEVOPS_EXT_PAT) { return $env:AZURE_DEVOPS_EXT_PAT }
    if ($env:AZ_DEVOPS_PAT) { return $env:AZ_DEVOPS_PAT }
    return $null
}

function Invoke-AdoApi {
    param (
        [Parameter(Mandatory)][string]$Uri,
        [Parameter(Mandatory)][hashtable]$Headers
    )

    Invoke-WithRetry -ScriptBlock {
        $webResponse = Invoke-WebRequest -Uri $Uri -Headers $Headers -Method Get -ContentType 'application/json'
        $bodyText = [string]$webResponse.Content
        if ([string]::IsNullOrWhiteSpace($bodyText)) { return [PSCustomObject]@{} }
        return ($bodyText | ConvertFrom-Json -Depth 100)
    }
}

function Get-HttpStatusCodeFromException {
    param ([System.Exception]$Exception)

    if (-not $Exception) { return $null }
    if ($Exception.PSObject.Properties['Response'] -and $Exception.Response -and $Exception.Response.PSObject.Properties['StatusCode']) {
        try { return [int]$Exception.Response.StatusCode } catch { }
    }
    if ($Exception.InnerException) {
        return Get-HttpStatusCodeFromException -Exception $Exception.InnerException
    }
    return $null
}

function Test-IsTimeoutException {
    param ([System.Exception]$Exception)

    if (-not $Exception) { return $false }
    if ($Exception -is [System.TimeoutException]) { return $true }
    $message = [string]$Exception.Message
    if ($message -match '(?i)timed out|timeout|operation canceled|operation timed out') { return $true }
    if ($Exception.InnerException) { return (Test-IsTimeoutException -Exception $Exception.InnerException) }
    return $false
}

function Get-AzDevOpsToolVersion {
    [CmdletBinding()]
    param ()

    try {
        $azCmd = Get-Command -Name 'az' -ErrorAction SilentlyContinue
        if (-not $azCmd) { return '' }

        $json = & $azCmd.Source version --output json 2>$null
        if (-not $json) { return '' }
        $version = $json | ConvertFrom-Json -Depth 10
        if ($version.PSObject.Properties['extensions'] -and $version.extensions) {
            if ($version.extensions.PSObject.Properties['azure-devops']) {
                return "azure-devops/$($version.extensions.'azure-devops')"
            }
        }
    } catch {
        return ''
    }

    return ''
}

function Get-CommitEvidenceUrl {
    [CmdletBinding()]
    param (
        [string]$RepositoryCanonicalId,
        [string]$CommitSha
    )

    if ([string]::IsNullOrWhiteSpace($RepositoryCanonicalId) -or [string]::IsNullOrWhiteSpace($CommitSha)) {
        return ''
    }

    if ($RepositoryCanonicalId -match '^ado://([^/]+)/([^/]+)/repository/(.+)$') {
        $org = $Matches[1]
        $project = $Matches[2]
        $repository = $Matches[3]
        return "https://dev.azure.com/$org/$project/_git/$repository/commit/$CommitSha"
    }

    return ''
}

function New-CorrelationTitle {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)][string]$BaseTitle,
        [string]$BuildId,
        [string]$SecretFindingId
    )

    $buildKey = if ($BuildId) { $BuildId } else { 'none' }
    $secretKey = if ($SecretFindingId) { $SecretFindingId } else { 'none' }
    return "$BaseTitle [build:$buildKey secret:$secretKey]"
}

function New-CorrelatorInfoFinding {
    param (
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][string]$Detail,
        [Parameter(Mandatory)][string]$ResourceId,
        [string]$Project = '',
        [string]$CorrelationStatus = 'correlated-fallback-project',
        [string]$ToolVersion = ''
    )

    $titleWithKeys = New-CorrelationTitle -BaseTitle $Title -BuildId '' -SecretFindingId ''
    [PSCustomObject]@{
        Id           = [guid]::NewGuid().ToString()
        Source       = 'ado-pipeline-correlator'
        Category     = 'Pipeline Run Correlation'
        Title        = (Remove-Credentials $titleWithKeys)
        Severity     = 'Info'
        Compliant    = $true
        Detail       = (Remove-Credentials $Detail)
        Remediation  = 'Ensure the PAT has Build (Read) and Project and Team (Read) scope for all target projects.'
        ResourceId   = (Remove-Credentials $ResourceId)
        LearnMoreUrl = 'https://learn.microsoft.com/en-us/azure/devops/pipelines/process/runs'
        SchemaVersion = '1.0'
        AdoOrg       = $AdoOrg
        AdoProject   = $Project
        CorrelationStatus = $CorrelationStatus
        ToolVersion = $ToolVersion
    }
}

function Get-AdoBuilds {
    param (
        [Parameter(Mandatory)][string]$Org,
        [Parameter(Mandatory)][string]$Project,
        [Parameter(Mandatory)][hashtable]$Headers
    )
    $orgEnc = [uri]::EscapeDataString($Org)
    $projectEnc = [uri]::EscapeDataString($Project)
    $uri = "https://dev.azure.com/$orgEnc/$projectEnc/_apis/build/builds?api-version=7.1&`$top=200"
    $body = Invoke-AdoApi -Uri $uri -Headers $Headers
    if ($body -and $body.PSObject.Properties['value']) { return @($body.value) }
    return @()
}

function Get-AdoBuildLogs {
    param (
        [Parameter(Mandatory)][string]$Org,
        [Parameter(Mandatory)][string]$Project,
        [Parameter(Mandatory)][string]$BuildId,
        [Parameter(Mandatory)][hashtable]$Headers
    )
    $orgEnc = [uri]::EscapeDataString($Org)
    $projectEnc = [uri]::EscapeDataString($Project)
    $uri = "https://dev.azure.com/$orgEnc/$projectEnc/_apis/build/builds/$BuildId/logs?api-version=7.1"
    $body = Invoke-AdoApi -Uri $uri -Headers $Headers
    if ($body -and $body.PSObject.Properties['value']) { return @($body.value) }
    return @()
}

if (-not $SecretsFindingsPath -or -not (Test-Path $SecretsFindingsPath)) {
    return [PSCustomObject]@{
        Source = 'ado-pipeline-correlator'
        Status = 'Skipped'
        Message = 'No secret findings file provided for pipeline correlation.'
        Findings = @()
        Errors   = @()
    }
}

$secrets = @()
try {
    $raw = Get-Content -Path $SecretsFindingsPath -Raw -ErrorAction Stop
    if (-not [string]::IsNullOrWhiteSpace($raw)) {
        $parsed = $raw | ConvertFrom-Json -Depth 100
        if ($parsed -is [System.Collections.IEnumerable] -and $parsed -isnot [string]) { $secrets = @($parsed) }
        elseif ($parsed) { $secrets = @($parsed) }
    }
} catch {
    return [PSCustomObject]@{
        Source = 'ado-pipeline-correlator'
        Status = 'Failed'
        Message = (Remove-Credentials "Failed to read secret findings: $($_.Exception.Message)")
        Findings = @()
        Errors   = @()
    }
}

if ($secrets.Count -eq 0) {
    return [PSCustomObject]@{
        Source = 'ado-pipeline-correlator'
        Status = 'Skipped'
        Message = 'No secret findings available for correlation.'
        Findings = @()
        Errors   = @()
    }
}

$pat = Resolve-AdoPat -Explicit $AdoPat
if (-not $pat) {
    return [PSCustomObject]@{
        Source = 'ado-pipeline-correlator'
        Status = 'Skipped'
        Message = 'No ADO PAT provided. Set -AdoPat/-AdoPatToken, ADO_PAT_TOKEN, AZURE_DEVOPS_EXT_PAT, or AZ_DEVOPS_PAT.'
        Findings = @()
        Errors   = @()
    }
}

$pair = ":$pat"
$bytes = [System.Text.Encoding]::UTF8.GetBytes($pair)
$base64 = [System.Convert]::ToBase64String($bytes)
$headers = @{ Authorization = "Basic $base64" }

$byProject = @{}
foreach ($secret in $secrets) {
    $project = if ($AdoProject) { $AdoProject } elseif ($secret.PSObject.Properties['AdoProject'] -and $secret.AdoProject) { [string]$secret.AdoProject } else { '' }
    if ([string]::IsNullOrWhiteSpace($project)) { continue }
    if (-not $byProject.ContainsKey($project)) {
        $byProject[$project] = [System.Collections.Generic.List[object]]::new()
    }
    $byProject[$project].Add($secret)
}

$findings = [System.Collections.Generic.List[PSCustomObject]]::new()
$logLookupFailures = [System.Collections.Generic.List[string]]::new()
$projectFailures = [System.Collections.Generic.List[string]]::new()
$toolVersion = Get-AzDevOpsToolVersion

foreach ($entry in $byProject.GetEnumerator()) {
    $project = [string]$entry.Key
    $projectSecrets = @($entry.Value)

    try {
        $builds = @(Get-AdoBuilds -Org $AdoOrg -Project $project -Headers $headers)
        foreach ($secret in $projectSecrets) {
            $commitSha = if ($secret.PSObject.Properties['CommitSha'] -and $secret.CommitSha) { [string]$secret.CommitSha } else { '' }
            if ([string]::IsNullOrWhiteSpace($commitSha)) { continue }
            $secretSeverity = if ($secret.PSObject.Properties['Severity'] -and $secret.Severity) { [string]$secret.Severity } else { 'High' }
            $secretFile = if ($secret.PSObject.Properties['FilePath'] -and $secret.FilePath) { [string]$secret.FilePath } else { 'unknown-file' }
            $secretType = if ($secret.PSObject.Properties['SecretType'] -and $secret.SecretType) { [string]$secret.SecretType } else { 'unknown-secret' }
            $secretFindingId = if ($secret.PSObject.Properties['Id'] -and $secret.Id) { [string]$secret.Id } else { '' }
            $repositoryCanonicalId = if ($secret.PSObject.Properties['RepositoryCanonicalId'] -and $secret.RepositoryCanonicalId) { [string]$secret.RepositoryCanonicalId } else { '' }
            $commitUrl = if ($secret.PSObject.Properties['CommitUrl'] -and $secret.CommitUrl) { [string]$secret.CommitUrl } else { (Get-CommitEvidenceUrl -RepositoryCanonicalId $repositoryCanonicalId -CommitSha $commitSha) }

            $matchedBuilds = @($builds | Where-Object {
                    $_.PSObject.Properties['sourceVersion'] -and $_.sourceVersion -and
                    ([string]$_.sourceVersion).ToLowerInvariant().StartsWith($commitSha.ToLowerInvariant())
                })

            foreach ($build in $matchedBuilds) {
                $buildId = if ($build.PSObject.Properties['id']) { [string]$build.id } else { '' }
                $definitionName = if ($build.PSObject.Properties['definition'] -and $build.definition -and $build.definition.PSObject.Properties['name']) {
                    [string]$build.definition.name
                } else { 'unknown-pipeline' }
                $definitionId = if ($build.PSObject.Properties['definition'] -and $build.definition -and $build.definition.PSObject.Properties['id']) {
                    [string]$build.definition.id
                } else { $definitionName }

                $pipelineResourceId = "ado://$($AdoOrg.ToLowerInvariant())/$($project.ToLowerInvariant())/pipeline/$($definitionId.ToLowerInvariant())"
                $buildUrl = if ($build.PSObject.Properties['_links'] -and $build._links -and $build._links.PSObject.Properties['web'] -and $build._links.web.href) {
                    [string]$build._links.web.href
                } else {
                    "https://dev.azure.com/$AdoOrg/$project/_build/results?buildId=$buildId"
                }

                $logCount = 0
                try {
                    $logs = @(Get-AdoBuildLogs -Org $AdoOrg -Project $project -BuildId $buildId -Headers $headers)
                    $logCount = $logs.Count
                } catch {
                    $logLookupFailures.Add("$project/$buildId")
                    $findings.Add((New-CorrelatorInfoFinding -Title 'ADO pipeline logs inaccessible - skipped' `
                            -Detail "Build logs for '$project/$buildId' could not be read and were skipped. $($_.Exception.Message)" `
                            -ResourceId "https://dev.azure.com/$AdoOrg/$project/_build/results?buildId=$buildId" `
                            -Project $project -ToolVersion $toolVersion))
                }

                $title = New-CorrelationTitle -BaseTitle "Secret-bearing commit $($commitSha.Substring(0, [Math]::Min(8, $commitSha.Length))) executed in pipeline '$definitionName'" -BuildId $buildId -SecretFindingId $secretFindingId
                $detail = "Secret type '$secretType' in file '$secretFile' was detected in commit '$commitSha'. BuildId=$buildId; Logs=$logCount."

                $findings.Add([PSCustomObject]@{
                        Id                = [guid]::NewGuid().ToString()
                        Source            = 'ado-pipeline-correlator'
                        Category          = 'Pipeline Run Correlation'
                        Title             = (Remove-Credentials $title)
                        Severity          = $secretSeverity
                        Compliant         = $false
                        Detail            = (Remove-Credentials $detail)
                        Remediation       = 'Review the pipeline run, revoke exposed credentials, and rotate impacted secrets before re-running deployments.'
                        ResourceId        = $pipelineResourceId
                        LearnMoreUrl      = 'https://learn.microsoft.com/en-us/azure/devops/pipelines/process/runs'
                        SchemaVersion     = '1.0'
                        AdoOrg            = $AdoOrg
                        AdoProject        = $project
                        PipelineResourceId = $pipelineResourceId
                        BuildId           = $buildId
                        BuildUrl          = $buildUrl
                        BuildTimestamp    = if ($build.PSObject.Properties['startTime']) { [string]$build.startTime } else { '' }
                        CommitSha         = $commitSha
                        SecretFindingId   = $secretFindingId
                        SecretType        = $secretType
                        RepositoryCanonicalId = $repositoryCanonicalId
                        CommitUrl         = $commitUrl
                        CorrelationStatus = 'correlated-direct'
                        ToolVersion       = $toolVersion
                    })
            }

            if ($matchedBuilds.Count -eq 0) {
                $correlationStatus = if ($builds.Count -eq 0) { 'build-not-found' } else { 'uncorrelated' }
                $title = New-CorrelationTitle -BaseTitle "Secret-bearing commit $($commitSha.Substring(0, [Math]::Min(8, $commitSha.Length))) was not matched to a pipeline run" -BuildId '' -SecretFindingId $secretFindingId
                $detail = "Secret type '$secretType' in file '$secretFile' was detected in commit '$commitSha', but no matching build run was found in project '$project'."

                $findings.Add([PSCustomObject]@{
                        Id                  = [guid]::NewGuid().ToString()
                        Source              = 'ado-pipeline-correlator'
                        Category            = 'Pipeline Run Correlation'
                        Title               = (Remove-Credentials $title)
                        Severity            = $secretSeverity
                        Compliant           = $false
                        Detail              = (Remove-Credentials $detail)
                        Remediation         = 'Review pipeline triggers, verify commit-to-build lineage, rotate exposed secrets, and validate downstream artifacts.'
                        ResourceId          = "ado://$($AdoOrg.ToLowerInvariant())/$($project.ToLowerInvariant())/pipeline/unknown"
                        LearnMoreUrl        = 'https://learn.microsoft.com/en-us/azure/devops/pipelines/process/runs'
                        SchemaVersion       = '1.0'
                        AdoOrg              = $AdoOrg
                        AdoProject          = $project
                        PipelineResourceId  = "ado://$($AdoOrg.ToLowerInvariant())/$($project.ToLowerInvariant())/pipeline/unknown"
                        BuildId             = ''
                        BuildUrl            = "https://dev.azure.com/$AdoOrg/$project/_build"
                        BuildTimestamp      = ''
                        CommitSha           = $commitSha
                        SecretFindingId     = $secretFindingId
                        SecretType          = $secretType
                        RepositoryCanonicalId = $repositoryCanonicalId
                        CommitUrl           = $commitUrl
                        CorrelationStatus   = $correlationStatus
                        ToolVersion         = $toolVersion
                    })
            }
        }
    } catch {
        $projectFailures.Add($project)
        $statusCode = Get-HttpStatusCodeFromException -Exception $_.Exception
        $projectUri = "https://dev.azure.com/$AdoOrg/$project/_apis/build/builds"
        if ($statusCode -in @(401, 403)) {
            $findings.Add((New-CorrelatorInfoFinding -Title 'ADO project inaccessible for pipeline correlation - skipped' `
                    -Detail "Project '$project' returned HTTP $statusCode and was skipped for correlation. $($_.Exception.Message)" `
                    -ResourceId $projectUri -Project $project -ToolVersion $toolVersion))
        } elseif ($statusCode -eq 404) {
            $findings.Add((New-CorrelatorInfoFinding -Title 'ADO project not found for pipeline correlation - skipped' `
                    -Detail "Project '$project' returned HTTP 404 and was skipped for correlation. $($_.Exception.Message)" `
                    -ResourceId $projectUri -Project $project -ToolVersion $toolVersion))
        } elseif (Test-IsTimeoutException -Exception $_.Exception) {
            $findings.Add((New-CorrelatorInfoFinding -Title 'ADO project correlation timed out - skipped' `
                    -Detail "Project '$project' timed out during build lookup and was skipped. $($_.Exception.Message)" `
                    -ResourceId $projectUri -Project $project -ToolVersion $toolVersion))
        } else {
            $findings.Add((New-CorrelatorInfoFinding -Title 'ADO project correlation failed - skipped' `
                    -Detail "Project '$project' failed correlation and was skipped. $($_.Exception.Message)" `
                    -ResourceId $projectUri -Project $project -ToolVersion $toolVersion))
        }
        Write-Warning (Remove-Credentials "Failed to correlate builds for project '$project': $($_.Exception.Message)")
    }
}

$status = 'Success'

$message = "Correlated $($findings.Count) pipeline run finding(s) from $($secrets.Count) secret finding(s)."
if ($projectFailures.Count -gt 0) { $message += " Failed projects: $($projectFailures -join ', ')." }
if ($logLookupFailures.Count -gt 0) { $message += " Missing log lookups: $($logLookupFailures -join ', ')." }

return [PSCustomObject]@{
    Source = 'ado-pipeline-correlator'
    Status = $status
    Message = $message
    Findings = @($findings)
    Errors   = @()
}
