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
try {
    Push-Location $OutputPath
    Start-WARACollector -TenantID $TenantId -SubscriptionIds $subArg -ErrorAction Stop
    if (Get-Command Start-WARAAnalyzer -ErrorAction SilentlyContinue) {
        Start-WARAAnalyzer -TenantID $TenantId -SubscriptionIds $subArg -ErrorAction Stop
    }
    Pop-Location
} catch {
    Pop-Location
    Write-Warning "WARA collector failed: $(Remove-Credentials -Text ([string]$_)). Returning empty result."
    return [PSCustomObject]@{ SchemaVersion = '1.0'; Source = 'wara'; Status = 'Failed'; Message = (Remove-Credentials -Text ([string]$_)); Findings = @(); Errors = @() }
}

# Find the newest JSON output file
$jsonFile = Get-ChildItem -Path $OutputPath -Filter "WARA_File_*.json" |
    Sort-Object LastWriteTime -Descending |
    Select-Object -First 1

if (-not $jsonFile) {
    Write-Warning "WARA collector ran but no output JSON found in $OutputPath."
    return [PSCustomObject]@{ SchemaVersion = '1.0'; Source = 'wara'; Status = 'Failed'; Message = 'No output JSON produced'; Findings = @(); Errors = @() }
}

# Parse findings
try {
    $raw = Get-Content $jsonFile.FullName -Raw | ConvertFrom-Json -ErrorAction Stop
} catch {
    Write-Warning "Could not parse WARA JSON: $(Remove-Credentials -Text ([string]$_))"
    return [PSCustomObject]@{ SchemaVersion = '1.0'; Source = 'wara'; Status = 'Failed'; Message = (Remove-Credentials -Text "JSON parse error: $([string]$_)"); Findings = @(); Errors = @() }
}

$xlsxFile = Get-ChildItem -Path $OutputPath -Filter "Expert-Analysis-*.xlsx" |
    Sort-Object LastWriteTime -Descending |
    Select-Object -First 1
$workbookMetadata = if ($xlsxFile) { Get-WaraWorkbookMetadata -WorkbookPath $xlsxFile.FullName } else { @{} }

$findings = [System.Collections.Generic.List[PSCustomObject]]::new()

$recommendations = $raw.Recommendations ?? ($raw.PSObject.Properties.Value | Where-Object { $_ -is [array] } | Select-Object -First 1)
foreach ($rec in $recommendations) {
    $recommendationId = [string](Get-WaraPropertyValue -Object $rec -Names @('RecommendationId', 'GUID', 'Id'))
    if ([string]::IsNullOrWhiteSpace($recommendationId)) { $recommendationId = [guid]::NewGuid().ToString() }
    $title = [string](Get-WaraPropertyValue -Object $rec -Names @('Recommendation', 'Title'))
    if ([string]::IsNullOrWhiteSpace($title)) { $title = 'Unknown' }

    $metadata = $null
    foreach ($key in @((New-WaraKey $recommendationId), (New-WaraKey $title))) {
        if (-not [string]::IsNullOrWhiteSpace($key) -and $workbookMetadata.ContainsKey($key)) {
            $metadata = $workbookMetadata[$key]
            break
        }
    }

    $impactedResources = @($rec.ImpactedResources)
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

return [PSCustomObject]@{ SchemaVersion = '1.0'; Source = 'wara'; ToolVersion = $toolVersion; Status = 'Success'; Message = ''; Findings = @($findings); Errors = @() }
