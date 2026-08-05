#Requires -Version 7.0
<#
.SYNOPSIS
    Wrapper for the Well-Architected Reliability Assessment (WARA) collector.
.DESCRIPTION
    Installs/imports the WARA module if needed, runs Start-WARACollector for the
    given subscription, parses the output JSON, and returns findings as PSObjects.
    Gracefully degrades if WARA is not available or collector fails.
.PARAMETER SubscriptionId
    Azure subscription ID (without /subscriptions/ prefix).
.PARAMETER TenantId
    Azure tenant ID. Defaults to current Az context tenant if not specified.
.PARAMETER OutputPath
    Directory to write WARA collector JSON. Defaults to .\output\wara.
.EXAMPLE
    .\Invoke-WARA.ps1 -SubscriptionId "00000000-0000-0000-0000-000000000000"
#>
[CmdletBinding()]
param (
    [Parameter(Mandatory)]
    [string] $SubscriptionId,
    [string] $TenantId,
    [string] $OutputPath = (Join-Path $PSScriptRoot '..\output\wara')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$sanitizePath = Join-Path $PSScriptRoot 'shared' 'Sanitize.ps1'
if (Test-Path $sanitizePath) { . $sanitizePath }
$missingToolPath = Join-Path $PSScriptRoot 'shared' 'MissingTool.ps1'
if (Test-Path $missingToolPath) { . $missingToolPath }
$envelopePath = Join-Path $PSScriptRoot 'shared' 'New-WrapperEnvelope.ps1'
if (Test-Path $envelopePath) { . $envelopePath }
$errorsPath = Join-Path $PSScriptRoot 'shared' 'Errors.ps1'
if (Test-Path $errorsPath) { . $errorsPath }
$retryPath = Join-Path $PSScriptRoot 'shared' 'Retry.ps1'
if (Test-Path $retryPath) { . $retryPath }
if (-not (Get-Command New-FindingError -ErrorAction SilentlyContinue)) {
    function New-FindingError { param([string]$Source,[string]$Category,[string]$Reason,[string]$Remediation,[string]$Details) return [pscustomobject]@{ Source=$Source; Category=$Category; Reason=$Reason; Remediation=$Remediation; Details=$Details } }
}
if (-not (Get-Command Format-FindingErrorMessage -ErrorAction SilentlyContinue)) {
    function Format-FindingErrorMessage { param([Parameter(Mandatory)]$FindingError) $line = "[{0}] {1}: {2}" -f $FindingError.Source, $FindingError.Category, $FindingError.Reason; if ($FindingError.Remediation) { $line += " Action: $($FindingError.Remediation)" }; return $line }
}
if (-not (Get-Command Invoke-WithRetry -ErrorAction SilentlyContinue)) {
    function Invoke-WithRetry { param([Parameter(Mandatory)][scriptblock]$ScriptBlock,[int]$MaxAttempts=1,[int]$InitialDelaySeconds=0,[string[]]$TransientMessagePatterns=@()) return & $ScriptBlock }
}
$aprlCatalogPath = Join-Path $PSScriptRoot 'shared' 'AprlCatalog.ps1'
if (Test-Path $aprlCatalogPath) { . $aprlCatalogPath }
if (-not (Get-Command New-WrapperEnvelope -ErrorAction SilentlyContinue)) { function New-WrapperEnvelope { param([string]$Source,[string]$Status='Failed',[string]$Message='',[object[]]$FindingErrors=@()) return [PSCustomObject]@{ Source=$Source; SchemaVersion='1.0'; Status=$Status; Message=$Message; Findings=@(); Errors=@($FindingErrors) } } }
if (-not (Get-Command Write-MissingToolNotice -ErrorAction SilentlyContinue)) {
    function Write-MissingToolNotice { param([string]$Tool, [string]$Message) Write-Warning $Message }
}
if (-not (Get-Command Remove-Credentials -ErrorAction SilentlyContinue)) {
    function Remove-Credentials { param([string]$Text) return $Text }
}

function Get-WaraPropertyValue {
    param(
        [Parameter(Mandatory)][object] $Object,
        [Parameter(Mandatory)][string[]] $Names
    )
    foreach ($name in $Names) {
        if ($Object -and $Object.PSObject.Properties[$name]) {
            $value = $Object.$name
            if ($null -ne $value -and -not [string]::IsNullOrWhiteSpace([string]$value)) {
                return $value
            }
        }
    }
    return $null
}

function Normalize-WaraPillar {
    param([string] $Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return '' }
    $normalized = $Value.Trim().ToLowerInvariant()
    if ($normalized -match 'reliab') { return 'Reliability' }
    if ($normalized -match 'secur') { return 'Security' }
    if ($normalized -match 'cost') { return 'Cost' }
    if ($normalized -match 'perform') { return 'Performance' }
    if ($normalized -match 'operat') { return 'Operational' }
    return ''
}

function New-WaraKey {
    param([object] $Value)
    if ($null -eq $Value) { return '' }
    $key = [string]$Value
    if ([string]::IsNullOrWhiteSpace($key)) { return '' }
    return $key.Trim().ToLowerInvariant()
}

function Get-WaraFreshArtifact {
    <#
    .SYNOPSIS
        Return the newest file matching Filter that was produced by the current run.
    .DESCRIPTION
        output/ is never cleaned between runs, so an artifact left behind by an earlier
        successful scan is otherwise indistinguishable from one the collector just wrote.
        Known holds the FullName -> LastWriteTimeUtc of every file that existed before the
        run started; an artifact counts as fresh when it is absent from that snapshot or
        its timestamp has moved, which also covers the collector overwriting the same
        filename when it runs twice within the same minute.
    #>
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [string] $Filter,
        [Parameter(Mandatory)] [hashtable] $Known
    )
    return Get-ChildItem -Path $Path -Filter $Filter -File -ErrorAction SilentlyContinue |
        Where-Object { -not $Known.ContainsKey($_.FullName) -or $Known[$_.FullName] -ne $_.LastWriteTimeUtc } |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1
}

function Get-WaraWorkbookMetadata {
    param([string] $WorkbookPath)
    $metadata = @{}
    if ([string]::IsNullOrWhiteSpace($WorkbookPath)) { return $metadata }
    if (-not (Test-Path $WorkbookPath)) { return $metadata }
    if (-not (Get-Command Import-Excel -ErrorAction SilentlyContinue)) { return $metadata }

    try {
        $sheets = @('Action Plan', 'ActionPlan', 'Recommendations')
        foreach ($sheet in $sheets) {
            try {
                $rows = @(Import-Excel -Path $WorkbookPath -WorksheetName $sheet -ErrorAction Stop)
            } catch {
                continue
            }
            foreach ($row in $rows) {
                $recId = Get-WaraPropertyValue -Object $row -Names @('Recommendation Id', 'RecommendationId', 'GUID', 'Recommendation GUID')
                $title = Get-WaraPropertyValue -Object $row -Names @('Recommendation', 'Title')
                $pillar = Normalize-WaraPillar ([string](Get-WaraPropertyValue -Object $row -Names @('Pillar', 'Recommendation Control', 'RecommendationControl')))
                $entry = [PSCustomObject]@{
                    Pillar           = $pillar
                    PotentialBenefit = [string](Get-WaraPropertyValue -Object $row -Names @('Potential Benefit', 'PotentialBenefit'))
                    Status           = [string](Get-WaraPropertyValue -Object $row -Names @('Status', 'Recommendation Status'))
                    Impact           = [string](Get-WaraPropertyValue -Object $row -Names @('Impact'))
                    Effort           = [string](Get-WaraPropertyValue -Object $row -Names @('Effort'))
                    ServiceCategory  = [string](Get-WaraPropertyValue -Object $row -Names @('Service Category', 'ServiceCategory', 'Service'))
                    DeepLinkUrl      = [string](Get-WaraPropertyValue -Object $row -Names @('Learn More', 'LearnMoreLink', 'DeepLinkUrl', 'Link'))
                    RemediationSteps = @((Get-WaraPropertyValue -Object $row -Names @('Remediation Steps', 'Remediation', 'Action Plan')) -split "(`r`n|`n|;)" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
                }
                foreach ($key in @((New-WaraKey $recId), (New-WaraKey $title))) {
                    if (-not [string]::IsNullOrWhiteSpace($key) -and -not $metadata.ContainsKey($key)) {
                        $metadata[$key] = $entry
                    }
                }
            }
        }
    } catch {
        Write-Warning "Failed to parse WARA workbook metadata: $(Remove-Credentials -Text ([string]$_))"
    }
    return $metadata
}

# Check WARA module is available (centralized Install-Prerequisites handles installation)
$waraModule = @(Get-Module -ListAvailable -Name WARA | Sort-Object Version -Descending | Select-Object -First 1)
if (-not $waraModule) {
    Write-MissingToolNotice -Tool 'wara' -Message "WARA module not found. Install with: Install-Module WARA -Scope CurrentUser"
    return [PSCustomObject]@{ SchemaVersion = '1.0'; Source = 'wara'; Status = 'Skipped'; Message = 'WARA module not installed. Run: Install-Module WARA -Scope CurrentUser'; Findings = @(); Errors = @() }
}
$toolVersion = [string]$waraModule[0].Version

Import-Module WARA -ErrorAction SilentlyContinue
if (-not (Get-Command Start-WARACollector -ErrorAction SilentlyContinue)) {
    Write-MissingToolNotice -Tool 'wara' -Message "WARA module loaded but Start-WARACollector not found. Returning empty result."
    return [PSCustomObject]@{ SchemaVersion = '1.0'; Source = 'wara'; Status = 'Skipped'; Message = 'Could not install WARA module'; Findings = @(); Errors = @() }
}

# Resolve tenant
if (-not $TenantId) {
    # Probe Az context (SilentlyContinue: probing for sign-in state, handled by null check below)
    $ctx = Get-AzContext -ErrorAction SilentlyContinue
    $TenantId = if ($null -ne $ctx -and $null -ne $ctx.Tenant) { $ctx.Tenant.Id } else { $null }
    if (-not $TenantId) {
        Write-Warning "No TenantId provided and no Az context found. Returning empty result."
        return [PSCustomObject]@{ SchemaVersion = '1.0'; Source = 'wara'; Status = 'Failed'; Message = 'No TenantId and no Az context'; Findings = @(); Errors = @() }
    }
}

# Ensure output dir
if (-not (Test-Path $OutputPath)) {
    $null = New-Item -ItemType Directory -Path $OutputPath -Force
}

# Run collector
$subArg = "/subscriptions/$SubscriptionId"

# Snapshot what is already on disk before the collector runs. See Get-WaraFreshArtifact:
# without this, a stale WARA-File-*.json from an earlier scan makes a total collector
# failure look like a success and last run's findings get re-reported as current.
$knownArtifacts = @{}
foreach ($existing in @(Get-ChildItem -Path $OutputPath -File -ErrorAction SilentlyContinue)) {
    $knownArtifacts[$existing.FullName] = $existing.LastWriteTimeUtc
}

# Azure Advisor occasionally returns a transient GatewayTimeout, which surfaces inside the
# WARA module as "Cannot bind argument to parameter 'AdvisorMetadata' because it is null".
# That string matches none of the shared transient patterns, so the retry conditions are
# passed explicitly. A collector run that produces no file is also retried: the collector
# writes its JSON even when a subscription has no impacted resources, so a missing file
# means the run failed rather than that there was nothing to report.
$collectorError = $null
$collectorJson = $null
try {
    $collectorJson = Invoke-WithRetry -MaxAttempts 3 -InitialDelaySeconds 15 -TransientMessagePatterns @(
        'AdvisorMetadata', 'produced no collector output',
        '\b429\b', '\b503\b', '\b504\b', '\b408\b',
        'throttl', 'rate limit', 'timed out', 'timeout',
        'service unavailable', 'temporarily unavailable', 'connection reset'
    ) -ScriptBlock {
        Push-Location $OutputPath
        try {
            # Tolerate per-resource "No recommendation found" errors so a single unmapped
            # resource type does not abort collection for the whole subscription.
            Start-WARACollector -TenantID $TenantId -SubscriptionIds $subArg -ErrorAction Continue
        }
        finally {
            Pop-Location
        }
        $fresh = Get-WaraFreshArtifact -Path $OutputPath -Filter 'WARA*File*.json' -Known $knownArtifacts
        if (-not $fresh) {
            throw (Format-FindingErrorMessage (New-FindingError `
                -Source 'wrapper:wara' `
                -Category 'TransientFailure' `
                -Reason "Start-WARACollector produced no collector output for subscription '$SubscriptionId'." `
                -Remediation 'Re-run the scan. If it keeps failing, run Start-WARACollector directly to see the underlying Azure Advisor or Resource Graph error.'))
        }
        return $fresh
    }
}
catch {
    $collectorError = $_
}

if (-not $collectorJson) {
    $message = if ($collectorError) { Remove-Credentials -Text ([string]$collectorError) } else { 'No output JSON produced' }
    Write-Warning "WARA collector failed: $message. Returning empty result."
    return [PSCustomObject]@{ SchemaVersion = '1.0'; Source = 'wara'; Status = 'Failed'; Message = $message; Findings = @(); Errors = @() }
}

# Analyzer (v1.x) takes -JSONFile (the collector output), not -TenantID/-SubscriptionIds.
if (Get-Command Start-WARAAnalyzer -ErrorAction SilentlyContinue) {
    try {
        Push-Location $OutputPath
        try {
            Start-WARAAnalyzer -JSONFile $collectorJson.FullName -ErrorAction Stop
        }
        finally {
            Pop-Location
        }
    } catch {
        Write-Warning "WARA analyzer step failed (collector data retained): $(Remove-Credentials -Text ([string]$_))"
    }
}

$jsonFile = $collectorJson

# Parse findings
try {
    $raw = Get-Content $jsonFile.FullName -Raw | ConvertFrom-Json -ErrorAction Stop
} catch {
    Write-Warning "Could not parse WARA JSON: $(Remove-Credentials -Text ([string]$_))"
    return [PSCustomObject]@{ SchemaVersion = '1.0'; Source = 'wara'; Status = 'Failed'; Message = (Remove-Credentials -Text "JSON parse error: $([string]$_)"); Findings = @(); Errors = @() }
}

$xlsxFile = Get-WaraFreshArtifact -Path $OutputPath -Filter 'Expert-Analysis-*.xlsx' -Known $knownArtifacts
$workbookMetadata = if ($xlsxFile) { Get-WaraWorkbookMetadata -WorkbookPath $xlsxFile.FullName } else { @{} }

$findings = [System.Collections.Generic.List[PSCustomObject]]::new()

$recommendations = if ($raw.PSObject.Properties['Recommendations'] -and $raw.Recommendations) {
    $raw.Recommendations
} else {
    # WARA collector v2.x exposes reliability findings across two arrays:
    #   - 'impactedResources' : APRL query results (per-resource; no impact level in JSON)
    #   - 'advisory'          : Azure Advisor results (per-resource; carries Impact + Description)
    # Merge both so the assessment includes Advisor's real severities and descriptions.
    $combined = [System.Collections.Generic.List[object]]::new()
    if ($raw.PSObject.Properties['impactedResources'] -and $raw.impactedResources) {
        foreach ($r in @($raw.impactedResources)) { $combined.Add($r) }
    }
    if ($raw.PSObject.Properties['advisory'] -and $raw.advisory) {
        foreach ($r in @($raw.advisory)) { $combined.Add($r) }
    }
    if ($combined.Count -eq 0) {
        # Generic fallback: first non-empty array property. Iterate the Properties collection
        # directly. Piping $raw.PSObject.Properties.Value unrolls nested arrays so a
        # Where-Object { $_ -is [array] } filter never matches the array as a whole.
        foreach ($p in $raw.PSObject.Properties) {
            if ($p.Value -is [System.Array] -and @($p.Value).Count -gt 0) {
                foreach ($r in @($p.Value)) { $combined.Add($r) }
                break
            }
        }
    }
    $combined
}
foreach ($rec in $recommendations) {
    $recommendationId = [string](Get-WaraPropertyValue -Object $rec -Names @('RecommendationId', 'GUID', 'Id'))
    if ([string]::IsNullOrWhiteSpace($recommendationId)) { $recommendationId = [guid]::NewGuid().ToString() }
    $title = [string](Get-WaraPropertyValue -Object $rec -Names @('Recommendation', 'Title', 'Description'))
    if ([string]::IsNullOrWhiteSpace($title)) { $title = 'Unknown' }

    $metadata = $null
    foreach ($key in @((New-WaraKey $recommendationId), (New-WaraKey $title))) {
        if (-not [string]::IsNullOrWhiteSpace($key) -and $workbookMetadata.ContainsKey($key)) {
            $metadata = $workbookMetadata[$key]
            break
        }
    }

    $impactedResources = if ($rec.PSObject.Properties['ImpactedResources'] -and $rec.ImpactedResources) {
        @($rec.ImpactedResources)
    } else {
        @()
    }
    if (-not $impactedResources -or $impactedResources.Count -eq 0) {
        $fallbackResourceId = [string](Get-WaraPropertyValue -Object $rec -Names @('ResourceId', 'Id'))
        if (-not [string]::IsNullOrWhiteSpace($fallbackResourceId)) {
            $impactedResources = @([PSCustomObject]@{ ResourceId = $fallbackResourceId })
        } else {
            $impactedResources = @([PSCustomObject]@{ ResourceId = '' })
        }
    }

    $entityRefs = [System.Collections.Generic.List[string]]::new()
    foreach ($resource in $impactedResources) {
        $candidate = if ($resource -is [string]) {
            $resource
        } else {
            [string](Get-WaraPropertyValue -Object $resource -Names @('ResourceId', 'Id'))
        }
        if (-not [string]::IsNullOrWhiteSpace($candidate)) {
            $entityRefs.Add($candidate)
        }
    }
    $entityRefArray = @($entityRefs | Select-Object -Unique)

    $pillar = Normalize-WaraPillar ([string](Get-WaraPropertyValue -Object $rec -Names @('Pillar', 'RecommendationControl', 'Category')))
    if ([string]::IsNullOrWhiteSpace($pillar) -and $metadata) { $pillar = Normalize-WaraPillar ([string]$metadata.Pillar) }

    $impact = [string](Get-WaraPropertyValue -Object $rec -Names @('Impact', 'RecommendationImpact'))
    if ([string]::IsNullOrWhiteSpace($impact) -and $metadata) { $impact = [string]$metadata.Impact }
    $effort = [string](Get-WaraPropertyValue -Object $rec -Names @('Effort'))
    if ([string]::IsNullOrWhiteSpace($effort) -and $metadata) { $effort = [string]$metadata.Effort }

    $serviceCategory = [string](Get-WaraPropertyValue -Object $rec -Names @('ServiceCategory', 'Service'))
    if ([string]::IsNullOrWhiteSpace($serviceCategory) -and $metadata) { $serviceCategory = [string]$metadata.ServiceCategory }
    $baselineTags = @()
    if (-not [string]::IsNullOrWhiteSpace($serviceCategory)) { $baselineTags += "service-category:$serviceCategory" }

    $deepLink = if ($metadata) { [string]$metadata.DeepLinkUrl } else { '' }
    if ([string]::IsNullOrWhiteSpace($deepLink)) {
        $deepLink = [string](Get-WaraPropertyValue -Object $rec -Names @('LearnMoreLink', 'Link', 'DeepLinkUrl'))
    }

    $remediation = [string](Get-WaraPropertyValue -Object $rec -Names @('Remediation', 'RecommendationAction'))
    $remediationSteps = @()
    if ($rec.PSObject.Properties['Description'] -and $rec.Description -and $rec.Description.PSObject.Properties['Steps']) {
        $remediationSteps = @($rec.Description.Steps | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    }
    if (($remediationSteps.Count -eq 0) -and $metadata) {
        $remediationSteps = @($metadata.RemediationSteps | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    }
    if ([string]::IsNullOrWhiteSpace($remediation) -and $remediationSteps.Count -gt 0) {
        $remediation = ($remediationSteps -join ' ')
    }

    $status = [string](Get-WaraPropertyValue -Object $rec -Names @('Status'))
    if ([string]::IsNullOrWhiteSpace($status) -and $metadata) { $status = [string]$metadata.Status }
    $potentialBenefit = [string](Get-WaraPropertyValue -Object $rec -Names @('PotentialBenefit', 'Potential Benefit'))
    if ([string]::IsNullOrWhiteSpace($potentialBenefit) -and $metadata) { $potentialBenefit = [string]$metadata.PotentialBenefit }
    $frameworks = @(@{
            Name     = 'WAF'
            Pillars  = if ($pillar) { @($pillar) } else { @() }
            Controls = @($recommendationId)
        })
    $category = [string](Get-WaraPropertyValue -Object $rec -Names @('Category', 'Service', 'RecommendationControl'))
    if ([string]::IsNullOrWhiteSpace($category)) { $category = 'Reliability' }
    $severity = [string](Get-WaraPropertyValue -Object $rec -Names @('Severity', 'Impact'))
    if ([string]::IsNullOrWhiteSpace($severity)) { $severity = 'Medium' }
    $detail = [string](Get-WaraPropertyValue -Object $rec -Names @('LongDescription', 'Description'))
    if ([string]::IsNullOrWhiteSpace($detail) -and $remediationSteps.Count -gt 0) {
        $detail = $remediationSteps -join ' '
    }
    if ([string]::IsNullOrWhiteSpace($detail)) { $detail = '' }

    foreach ($resource in $impactedResources) {
        $resourceId = if ($resource -is [string]) {
            $resource
        } else {
            [string](Get-WaraPropertyValue -Object $resource -Names @('ResourceId', 'Id'))
        }
        $resourceId = if ($resourceId) { $resourceId } else { '' }
        $findingId = "$recommendationId::$resourceId"
        if ([string]::IsNullOrWhiteSpace($resourceId)) { $findingId = $recommendationId }

        $findings.Add([PSCustomObject]@{
            Id               = $findingId
            RecommendationId = $recommendationId
            Category         = $category
            Pillar           = $pillar
            Title            = $title
            Severity         = $severity
            Impact           = $impact
            Effort           = $effort
            Compliant        = $false
            Detail           = $detail
            Remediation      = $remediation
            RemediationSteps = @($remediationSteps)
            ResourceId       = [string]$resourceId
            LearnMoreUrl     = $deepLink
            DeepLinkUrl      = $deepLink
            Frameworks       = @($frameworks)
            BaselineTags     = @($baselineTags)
            ServiceCategory  = $serviceCategory
            EntityRefs       = @($entityRefArray)
            Status           = $status
            PotentialBenefit = $potentialBenefit
            ToolVersion      = $toolVersion
        })
    }
}

# Best-effort APRL catalog enrichment: recover Title/Severity/Detail/LearnMore
# for findings the workbook-metadata join left as 'Unknown', and stamp the APRL
# recommendation control as the report Category on every matched finding.
# Non-fatal and offline-safe: a missing catalog leaves findings unchanged.
# The catalog is consulted whenever there are findings (not only when a Title is
# missing) because category enrichment applies to well-formed findings too;
# Get-WaraAprlCatalog is cache-backed, so this does not add a fetch per run.
if ($findings.Count -gt 0 -and (Get-Command Merge-WaraAprlMetadata -ErrorAction SilentlyContinue)) {
    try {
        $catalogCache = if (Get-Command Get-AprlDefaultCachePath -ErrorAction SilentlyContinue) { Get-AprlDefaultCachePath } else { Join-Path ([System.IO.Path]::GetTempPath()) 'wara-aprl-catalog.json' }
        $aprlCatalog = Get-WaraAprlCatalog -Path $catalogCache
        if ($aprlCatalog) {
            $null = Merge-WaraAprlMetadata -Findings $findings -Catalog $aprlCatalog
        }
    } catch {
        Write-Verbose "APRL catalog enrichment skipped: $([string]$_)"
    }
}

return [PSCustomObject]@{ SchemaVersion = '1.0'; Source = 'wara'; ToolVersion = $toolVersion; Status = 'Success'; Message = ''; Findings = @($findings); Errors = @() }
