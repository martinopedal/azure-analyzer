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

function Get-AdoBuilds {
    param ([string]$Org, [string]$Project, [hashtable]$Headers)
    $orgEnc = [uri]::EscapeDataString($Org)
    $projectEnc = [uri]::EscapeDataString($Project)
    $uri = "https://dev.azure.com/$orgEnc/$projectEnc/_apis/build/builds?api-version=7.1&`$top=200"
    $body = Invoke-AdoApi -Uri $uri -Headers $Headers
    if ($body -and $body.PSObject.Properties['value']) { return @($body.value) }
    return @()
}

function Get-AdoBuildLogs {
    param ([string]$Org, [string]$Project, [string]$BuildId, [hashtable]$Headers)
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
    }
}

if ($secrets.Count -eq 0) {
    return [PSCustomObject]@{
        Source = 'ado-pipeline-correlator'
        Status = 'Skipped'
        Message = 'No secret findings available for correlation.'
        Findings = @()
    }
}

$pat = Resolve-AdoPat -Explicit $AdoPat
if (-not $pat) {
    return [PSCustomObject]@{
        Source = 'ado-pipeline-correlator'
        Status = 'Skipped'
        Message = 'No ADO PAT provided. Set -AdoPat/-AdoPatToken, ADO_PAT_TOKEN, AZURE_DEVOPS_EXT_PAT, or AZ_DEVOPS_PAT.'
        Findings = @()
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
                }

                $title = "Secret-bearing commit $($commitSha.Substring(0, [Math]::Min(8, $commitSha.Length))) executed in pipeline '$definitionName'"
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
                        SecretFindingId   = if ($secret.PSObject.Properties['Id']) { [string]$secret.Id } else { '' }
                    })
            }
        }
    } catch {
        $projectFailures.Add($project)
        Write-Warning (Remove-Credentials "Failed to correlate builds for project '$project': $($_.Exception.Message)")
    }
}

$status = 'Success'
if ($projectFailures.Count -gt 0 -or $logLookupFailures.Count -gt 0) {
    if ($findings.Count -gt 0) { $status = 'PartialSuccess' }
    else { $status = 'Failed' }
}

$message = "Correlated $($findings.Count) pipeline run finding(s) from $($secrets.Count) secret finding(s)."
if ($projectFailures.Count -gt 0) { $message += " Failed projects: $($projectFailures -join ', ')." }
if ($logLookupFailures.Count -gt 0) { $message += " Missing log lookups: $($logLookupFailures -join ', ')." }

return [PSCustomObject]@{
    Source = 'ado-pipeline-correlator'
    Status = $status
    Message = $message
    Findings = @($findings)
}
