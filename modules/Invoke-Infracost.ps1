#Requires -Version 7.4
<#
.SYNOPSIS
    Wrapper for Infracost CLI pre-deploy IaC cost estimation.
.DESCRIPTION
    Runs `infracost breakdown` against Terraform/Bicep source and emits a v1
    wrapper envelope with one finding per resource estimate.

    Cloud-first behavior:
    - `-Repository` clones a remote repo through RemoteClone.ps1 (HTTPS-only,
      host allow-list, token-safe cleanup).
    - `-Path` scans a local directory (fallback mode).

    Resilience and security:
    - Infracost CLI invocation is wrapped with Invoke-WithRetry.
    - CLI process is executed through Invoke-WithTimeout with 300s timeout.
    - Any surfaced message is passed through Remove-Credentials.

    Never throws -- designed for graceful degradation in the orchestrator.
.PARAMETER Path
    Local directory containing Terraform/Bicep files. Defaults to current dir.
.PARAMETER Repository
    Remote HTTPS repository URL to clone and scan.
#>
[CmdletBinding()]
param (
    [Alias('RepoPath')]
    [string] $Path = '.',
    [Alias('RemoteUrl')]
    [string] $Repository
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$sharedDir = Join-Path (Split-Path $PSScriptRoot -Parent) 'modules' 'shared'
if (-not $sharedDir -or -not (Test-Path $sharedDir)) {
    $sharedDir = Join-Path $PSScriptRoot 'shared'
}

$sanitizePath = Join-Path $sharedDir 'Sanitize.ps1'
if (Test-Path $sanitizePath) { . $sanitizePath }
$retryPath = Join-Path $sharedDir 'Retry.ps1'
if (Test-Path $retryPath) { . $retryPath }
$remoteClonePath = Join-Path $sharedDir 'RemoteClone.ps1'
if (Test-Path $remoteClonePath) { . $remoteClonePath }
$installerPath = Join-Path $sharedDir 'Installer.ps1'
if (-not (Get-Command Invoke-WithTimeout -ErrorAction SilentlyContinue) -and (Test-Path $installerPath)) {
    . $installerPath
}

if (-not (Get-Command Remove-Credentials -ErrorAction SilentlyContinue)) {
    function Remove-Credentials { param ([string]$Text) return $Text }
}
if (-not (Get-Command Invoke-WithRetry -ErrorAction SilentlyContinue)) {
    function Invoke-WithRetry { param([scriptblock]$ScriptBlock, [int]$MaxAttempts = 3) & $ScriptBlock }
}
if (-not (Get-Command Invoke-WithTimeout -ErrorAction SilentlyContinue)) {
    function Invoke-WithTimeout {
        param (
            [Parameter(Mandatory)][string]$Command,
            [Parameter(Mandatory)][string[]]$Arguments,
            [int]$TimeoutSec = 300
        )
        $output = & $Command @Arguments 2>&1 | Out-String
        [PSCustomObject]@{
            ExitCode = $LASTEXITCODE
            Output   = Remove-Credentials $output
        }
    }
}

function Test-InfracostInstalled {
    return $null -ne (Get-Command infracost -ErrorAction SilentlyContinue)
}

function Get-FirstJsonObjectText {
    param([AllowNull()][string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    $start = $Text.IndexOf('{')
    $end = $Text.LastIndexOf('}')
    if ($start -lt 0 -or $end -lt $start) { return $null }
    return $Text.Substring($start, ($end - $start) + 1)
}

function ConvertTo-InfracostDouble {
    param(
        [AllowNull()][object]$Value,
        [double]$Default = 0.0
    )
    if ($null -eq $Value) { return $Default }
    $parsed = 0.0
    if ([double]::TryParse([string]$Value, [System.Globalization.NumberStyles]::Any, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$parsed)) {
        return $parsed
    }
    return $Default
}

function Get-InfracostToolVersion {
    $versionExec = Invoke-WithRetry -MaxAttempts 2 -InitialDelaySeconds 1 -MaxDelaySeconds 5 -ScriptBlock {
        Invoke-WithTimeout -Command 'infracost' -Arguments @('--version') -TimeoutSec 60
    }
    if (-not $versionExec -or $versionExec.ExitCode -ne 0) { return '' }
    $raw = Remove-Credentials ([string]$versionExec.Output)
    if ([string]::IsNullOrWhiteSpace($raw)) { return '' }
    return ($raw -split "(\r?\n)" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -First 1).Trim()
}

function Resolve-InfracostEffort {
    param([string]$ResourceType)
    $normalized = if ($ResourceType) { $ResourceType.ToLowerInvariant() } else { '' }
    if ($normalized -match 'resource_group|tag|diagnostic') { return 'Low' }
    if ($normalized -match 'storage|app_service_plan|public_ip|disk|redis|servicebus') { return 'Low' }
    if ($normalized -match 'kubernetes|aks|sql|postgres|cosmos|firewall|application_gateway|frontdoor') { return 'Medium' }
    return 'Low'
}

function Get-InfracostPropertyValue {
    param(
        [AllowNull()][object]$Object,
        [string]$PropertyName
    )
    if (-not $Object -or [string]::IsNullOrWhiteSpace($PropertyName)) { return $null }
    $property = $Object.PSObject.Properties[$PropertyName]
    if ($property) { return $property.Value }
    return $null
}

function Get-InfracostCloudUrl {
    param(
        [AllowNull()]$Project,
        [AllowNull()]$Resource
    )
    $resourceMetadata = Get-InfracostPropertyValue -Object $Resource -PropertyName 'metadata'
    $projectMetadata = Get-InfracostPropertyValue -Object $Project -PropertyName 'metadata'
    foreach ($candidate in @(
            (Get-InfracostPropertyValue -Object $Resource -PropertyName 'cloudUrl'),
            (Get-InfracostPropertyValue -Object $Resource -PropertyName 'CloudUrl'),
            (Get-InfracostPropertyValue -Object $Resource -PropertyName 'url'),
            (Get-InfracostPropertyValue -Object $Resource -PropertyName 'Url'),
            (Get-InfracostPropertyValue -Object $resourceMetadata -PropertyName 'url'),
            (Get-InfracostPropertyValue -Object $resourceMetadata -PropertyName 'cloudUrl'),
            (Get-InfracostPropertyValue -Object $Project -PropertyName 'cloudUrl'),
            (Get-InfracostPropertyValue -Object $Project -PropertyName 'CloudUrl'),
            (Get-InfracostPropertyValue -Object $Project -PropertyName 'url'),
            (Get-InfracostPropertyValue -Object $Project -PropertyName 'Url'),
            (Get-InfracostPropertyValue -Object $projectMetadata -PropertyName 'url'),
            (Get-InfracostPropertyValue -Object $projectMetadata -PropertyName 'cloudUrl')
        )) {
        if (-not [string]::IsNullOrWhiteSpace([string]$candidate)) { return [string]$candidate }
    }
    return ''
}

function Get-InfracostRemediationSnippets {
    param(
        [string]$ResourceType,
        [double]$MonthlyCost
    )
    if ($MonthlyCost -le 0) { return @() }
    $normalized = if ($ResourceType) { $ResourceType.ToLowerInvariant() } else { '' }
    if ($normalized -match 'kubernetes|aks') {
        return @(
            @{
                language = 'hcl'
                title    = 'AKS SKU right-size'
                code     = "sku_tier = `"Standard`"`n# consider downgrading node VM size for non-prod"
            }
        )
    }
    if ($normalized -match 'storage_account') {
        return @(
            @{
                language = 'hcl'
                title    = 'Storage redundancy right-size'
                code     = "account_tier             = `"Standard`"`naccount_replication_type = `"LRS`""
            }
        )
    }
    return @()
}

if (-not (Test-InfracostInstalled)) {
    Write-Warning "infracost CLI is not installed. Skipping Infracost scan."
    return [PSCustomObject]@{
        Source        = 'infracost'
        SchemaVersion = '1.0'
        Status        = 'Skipped'
        Message       = 'infracost CLI not installed. Install from https://www.infracost.io/docs/'
        Findings      = @()
    }
}

$cloneInfo = $null
$cleanupClone = $null
try {
    if ($Repository) {
        if (-not (Get-Command Invoke-RemoteRepoClone -ErrorAction SilentlyContinue)) {
            Write-Warning "RemoteClone helper not loaded; cannot scan remote repository."
            return [PSCustomObject]@{
                Source        = 'infracost'
                SchemaVersion = '1.0'
                Status        = 'Failed'
                Message       = 'RemoteClone helper unavailable'
                Findings      = @()
            }
        }
        $cloneInfo = Invoke-RemoteRepoClone -RepoUrl $Repository -TimeoutSec 300
        if (-not $cloneInfo) {
            return [PSCustomObject]@{
                Source        = 'infracost'
                SchemaVersion = '1.0'
                Status        = 'Failed'
                Message       = "Remote clone failed or host not on allow-list: $Repository"
                Findings      = @()
            }
        }
        $cleanupClone = $cloneInfo.Cleanup
        $Path = $cloneInfo.Path
    }

    if (-not (Test-Path -LiteralPath $Path)) {
        return [PSCustomObject]@{
            Source        = 'infracost'
            SchemaVersion = '1.0'
            Status        = 'Failed'
            Message       = "Path not found: $Path"
            Findings      = @()
        }
    }

    $iacFiles = @(Get-ChildItem -Path $Path -Recurse -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Extension -in @('.tf', '.bicep') })
    if ($iacFiles.Count -eq 0) {
        return [PSCustomObject]@{
            Source        = 'infracost'
            SchemaVersion = '1.0'
            Status        = 'Skipped'
            Message       = 'No Terraform or Bicep files found under scan path.'
            Findings      = @()
        }
    }

    $args = @('breakdown', '--path', $Path, '--format', 'json', '--no-color')
    $exec = Invoke-WithRetry -MaxAttempts 3 -InitialDelaySeconds 2 -MaxDelaySeconds 30 -ScriptBlock {
        Invoke-WithTimeout -Command 'infracost' -Arguments $args -TimeoutSec 300
    }

    if (-not $exec -or $exec.ExitCode -ne 0) {
        $safeOutput = if ($exec) { Remove-Credentials ([string]$exec.Output) } else { '' }
        return [PSCustomObject]@{
            Source        = 'infracost'
            SchemaVersion = '1.0'
            Status        = 'Failed'
            Message       = "infracost breakdown failed (exit code $($exec.ExitCode)): $safeOutput"
            Findings      = @()
        }
    }

    $jsonText = Get-FirstJsonObjectText -Text ([string]$exec.Output)
    if (-not $jsonText) {
        return [PSCustomObject]@{
            Source        = 'infracost'
            SchemaVersion = '1.0'
            Status        = 'Failed'
            Message       = 'infracost output did not contain a JSON object.'
            Findings      = @()
        }
    }

    $parsed = $null
    try {
        $parsed = $jsonText | ConvertFrom-Json -Depth 100 -ErrorAction Stop
    } catch {
        return [PSCustomObject]@{
            Source        = 'infracost'
            SchemaVersion = '1.0'
            Status        = 'Failed'
            Message       = Remove-Credentials "Failed to parse infracost JSON: $($_.Exception.Message)"
            Findings      = @()
        }
    }

    $toolVersion = ''
    try {
        $toolVersion = Get-InfracostToolVersion
    } catch {
        $toolVersion = ''
    }

    $breakdownPath = Join-Path $Path 'infracost-breakdown.json'
    $breakdownUri = ''
    try {
        Set-Content -LiteralPath $breakdownPath -Value $jsonText -Encoding utf8NoBOM -Force
        $resolvedBreakdownPath = (Resolve-Path -LiteralPath $breakdownPath -ErrorAction Stop).Path
        $breakdownUri = "file:///$($resolvedBreakdownPath -replace '\\','/')"
    } catch {
        $breakdownUri = ''
    }

    $findings = [System.Collections.Generic.List[PSCustomObject]]::new()
    $aggregateTotalMonthlyCost = 0.0
    $aggregateBaselineMonthlyCost = 0.0
    $aggregateTotalHourlyCost = 0.0
    $summaryCurrency = ''
    $summaryProjectNames = [System.Collections.Generic.List[string]]::new()
    foreach ($project in @($parsed.projects)) {
        if (-not $project) { continue }
        $projectName = if ($project.PSObject.Properties['name'] -and $project.name) { [string]$project.name } else { 'project' }
        $projectPath = if ($project.PSObject.Properties['path'] -and $project.path) { [string]$project.path } else { [string]$Path }
        if (-not [string]::IsNullOrWhiteSpace($projectName)) {
            $summaryProjectNames.Add($projectName) | Out-Null
        }
        $resources = @()
        if ($project.PSObject.Properties['breakdown'] -and $project.breakdown -and
            $project.breakdown.PSObject.Properties['resources']) {
            $resources = @($project.breakdown.resources)
        }

        $projectTotalMonthlyCost = if ($project.PSObject.Properties['breakdown'] -and $project.breakdown) {
            ConvertTo-InfracostDouble -Value $project.breakdown.totalMonthlyCost
        } else {
            0.0
        }
        if ($projectTotalMonthlyCost -le 0 -and $resources.Count -gt 0) {
            $projectTotalMonthlyCost = (@($resources | ForEach-Object { ConvertTo-InfracostDouble -Value $_.monthlyCost }) | Measure-Object -Sum).Sum
        }
        $projectBaselineMonthlyCost = if ($project.PSObject.Properties['pastBreakdown'] -and $project.pastBreakdown) {
            ConvertTo-InfracostDouble -Value $project.pastBreakdown.totalMonthlyCost
        } else {
            0.0
        }
        $projectDiffMonthlyCost = if ($project.PSObject.Properties['diff'] -and $project.diff) {
            ConvertTo-InfracostDouble -Value $project.diff.totalMonthlyCost -Default ($projectTotalMonthlyCost - $projectBaselineMonthlyCost)
        } else {
            $projectTotalMonthlyCost - $projectBaselineMonthlyCost
        }
        $projectTotalHourlyCost = if ($project.PSObject.Properties['breakdown'] -and $project.breakdown) {
            ConvertTo-InfracostDouble -Value $project.breakdown.totalHourlyCost -Default ($projectTotalMonthlyCost / 730.0)
        } else {
            $projectTotalMonthlyCost / 730.0
        }

        $aggregateTotalMonthlyCost += $projectTotalMonthlyCost
        $aggregateBaselineMonthlyCost += $projectBaselineMonthlyCost
        $aggregateTotalHourlyCost += $projectTotalHourlyCost

        foreach ($resource in $resources) {
            if (-not $resource) { continue }
            $resourceName = if ($resource.PSObject.Properties['name'] -and $resource.name) { [string]$resource.name } else { 'resource' }
            $resourceType = if ($resource.PSObject.Properties['resourceType'] -and $resource.resourceType) { [string]$resource.resourceType } else { 'unknown' }
            $monthlyRaw = if ($resource.PSObject.Properties['monthlyCost']) { [string]$resource.monthlyCost } else { '0' }
            $monthlyCost = 0.0
            [void][double]::TryParse($monthlyRaw, [System.Globalization.NumberStyles]::Any, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$monthlyCost)
            $currency = if ($resource.PSObject.Properties['currency'] -and $resource.currency) { [string]$resource.currency } else { 'USD' }
            if ([string]::IsNullOrWhiteSpace($summaryCurrency) -and -not [string]::IsNullOrWhiteSpace($currency)) {
                $summaryCurrency = $currency
            }
            $deepLinkUrl = Get-InfracostCloudUrl -Project $project -Resource $resource
            $entityRefs = @($projectPath)
            $remediationSnippets = Get-InfracostRemediationSnippets -ResourceType $resourceType -MonthlyCost $monthlyCost

            $findings.Add([PSCustomObject]@{
                    Id            = [guid]::NewGuid().ToString()
                    Category      = 'Cost'
                    Title         = "Estimated monthly cost: $([string]::Format([System.Globalization.CultureInfo]::InvariantCulture, '{0:0.00}', $monthlyCost)) for $resourceType"
                    Severity      = 'Info'
                    Compliant     = $false
                    Detail        = "Infracost estimate for $resourceName in project $projectName."
                    Remediation   = 'Review right-sizing, SKU choice, and environment count before deployment.'
                    ResourceId    = $projectPath
                    LearnMoreUrl  = 'https://www.infracost.io/docs/'
                    ResourceType  = $resourceType
                    ResourceName  = $resourceName
                    ProjectName   = $projectName
                    ProjectPath   = $projectPath
                    MonthlyCost   = [math]::Round($monthlyCost, 2)
                    Currency      = $currency
                    Pillar        = 'Cost'
                    Impact        = ''
                    Effort        = Resolve-InfracostEffort -ResourceType $resourceType
                    DeepLinkUrl   = $deepLinkUrl
                    RemediationSnippets = @($remediationSnippets)
                    EvidenceUris  = if ($breakdownUri) { @($breakdownUri) } else { @() }
                    EntityRefs    = $entityRefs
                    ToolVersion   = $toolVersion
                    ProjectTotalMonthlyCost = [math]::Round($projectTotalMonthlyCost, 2)
                    BaselineMonthlyCost = [math]::Round($projectBaselineMonthlyCost, 2)
                    DiffMonthlyCost = [math]::Round($projectDiffMonthlyCost, 2)
                })
        }
    }

    $summaryProjectName = if ($summaryProjectNames.Count -eq 1) {
        $summaryProjectNames[0]
    } elseif ($summaryProjectNames.Count -gt 1) {
        'multiple'
    } else {
        ''
    }
    $summaryDiffMonthlyCost = $aggregateTotalMonthlyCost - $aggregateBaselineMonthlyCost

    return [PSCustomObject]@{
        Source        = 'infracost'
        SchemaVersion = '1.0'
        Status        = 'Success'
        Message       = "Parsed $($findings.Count) resource cost estimate(s)."
        ToolVersion   = $toolVersion
        ToolSummary   = [PSCustomObject]@{
            Currency            = if ([string]::IsNullOrWhiteSpace($summaryCurrency)) { 'USD' } else { $summaryCurrency }
            TotalMonthlyCost    = [math]::Round($aggregateTotalMonthlyCost, 2)
            TotalHourlyCost     = [math]::Round($aggregateTotalHourlyCost, 4)
            ProjectName         = $summaryProjectName
            BaselineMonthlyCost = [math]::Round($aggregateBaselineMonthlyCost, 2)
            DiffMonthlyCost     = [math]::Round($summaryDiffMonthlyCost, 2)
        }
        Findings      = @($findings)
    }
} catch {
    Write-Warning "Infracost scan failed: $(Remove-Credentials -Text ([string]$_.Exception.Message))"
    return [PSCustomObject]@{
        Source        = 'infracost'
        SchemaVersion = '1.0'
        Status        = 'Failed'
        Message       = Remove-Credentials -Text ([string]$_.Exception.Message)
        Findings      = @()
    }
} finally {
    if ($cleanupClone) {
        try { & $cleanupClone } catch {
            Write-Verbose "Infracost clone cleanup failed: $(Remove-Credentials -Text ([string]$_.Exception.Message))"
        }
    }
}
