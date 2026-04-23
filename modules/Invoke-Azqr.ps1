#Requires -Version 7.0
<#
.SYNOPSIS
    Wrapper for Azure Quick Review (azqr) CLI.
.DESCRIPTION
    Scans an Azure subscription with azqr and returns findings as a PSObject.
    If azqr is not installed, writes a warning and returns an empty result.
    Never throws — designed for graceful degradation in the orchestrator.
.PARAMETER SubscriptionId
    The Azure subscription ID to scan.
.PARAMETER OutputPath
    Directory where azqr writes its output. Defaults to .\output\azqr.
#>
[CmdletBinding()]
param (
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string] $SubscriptionId,

    [string] $OutputPath = (Join-Path (Get-Location) 'output' 'azqr')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$sanitizePath = Join-Path $PSScriptRoot 'shared' 'Sanitize.ps1'
if (Test-Path $sanitizePath) { . $sanitizePath }
$missingToolPath = Join-Path $PSScriptRoot 'shared' 'MissingTool.ps1'
if (Test-Path $missingToolPath) { . $missingToolPath }
if (-not (Get-Command Remove-Credentials -ErrorAction SilentlyContinue)) {
    function Remove-Credentials { param([string]$Text) return $Text }
}

function Test-AzqrInstalled {
    $null -ne (Get-Command azqr -ErrorAction SilentlyContinue)
}

function Get-AzqrToolVersion {
    try {
        $rawVersion = azqr --version 2>&1
        if ($LASTEXITCODE -ne 0) { return '' }
        $versionText = if ($rawVersion -is [array]) { ($rawVersion -join ' ') } else { [string]$rawVersion }
        $match = [regex]::Match($versionText, '(\d+\.\d+\.\d+(?:[-+][A-Za-z0-9\.-]+)?)')
        if ($match.Success) { return $match.Groups[1].Value }
        return $versionText.Trim()
    } catch {
        return ''
    }
}

function Get-PropertyValue {
    param ([object]$Obj, [string]$Name, [object]$Default = $null)
    if ($null -eq $Obj) { return $Default }
    $p = $Obj.PSObject.Properties[$Name]
    if ($null -eq $p -or $null -eq $p.Value) { return $Default }
    return $p.Value
}

function Convert-ToStringArray {
    param ([object]$Value)
    if ($null -eq $Value) { return @() }
    $items = [System.Collections.Generic.List[string]]::new()
    if ($Value -is [string]) {
        if (-not [string]::IsNullOrWhiteSpace($Value)) { $items.Add($Value.Trim()) }
    } else {
        foreach ($item in @($Value)) {
            if ($null -eq $item) { continue }
            $text = [string]$item
            if (-not [string]::IsNullOrWhiteSpace($text)) { $items.Add($text.Trim()) }
        }
    }
    return @($items)
}

function Resolve-AzqrPillar {
    param ([object]$Finding)
    $rawPillar = [string](Get-PropertyValue $Finding 'Pillar' (Get-PropertyValue $Finding 'WafPillar' (Get-PropertyValue $Finding 'WellArchitectedPillar' '')))
    if (-not [string]::IsNullOrWhiteSpace($rawPillar)) {
        switch -Regex ($rawPillar.Trim().ToLowerInvariant()) {
            '^security$' { return 'Security' }
            '^reliability$' { return 'Reliability' }
            '^cost|costoptimization|cost optimization$' { return 'CostOptimization' }
            '^performance|performanceefficiency|performance efficiency$' { return 'PerformanceEfficiency' }
            '^operational|operationalexcellence|operational excellence|operations$' { return 'OperationalExcellence' }
            default { return $rawPillar.Trim() }
        }
    }

    $category = [string](Get-PropertyValue $Finding 'Category' (Get-PropertyValue $Finding 'ServiceCategory' ''))
    switch -Regex ($category.Trim().ToLowerInvariant()) {
        'security|identity|networking|encryption' { return 'Security' }
        'reliability|highavailability|high availability|businesscontinuity' { return 'Reliability' }
        'cost|finops' { return 'CostOptimization' }
        'performance' { return 'PerformanceEfficiency' }
        'monitoring|monitoringandalerting|operational|operations|operationalexcellence' { return 'OperationalExcellence' }
        default { return '' }
    }
}

function Resolve-AzqrFrameworks {
    param (
        [object]$Finding,
        [string]$Pillar
    )

    $frameworks = [System.Collections.Generic.List[hashtable]]::new()
    foreach ($entry in @(Get-PropertyValue $Finding 'Frameworks' @())) {
        if ($entry -is [System.Collections.IDictionary]) {
            $kind = [string]($entry['kind'] ?? $entry['Kind'])
            $controlId = [string]($entry['controlId'] ?? $entry['ControlId'])
            if (-not [string]::IsNullOrWhiteSpace($kind) -and -not [string]::IsNullOrWhiteSpace($controlId)) {
                $frameworks.Add(@{ kind = $kind; controlId = $controlId }) | Out-Null
            }
        } elseif ($entry) {
            $text = [string]$entry
            if (-not [string]::IsNullOrWhiteSpace($text)) {
                $frameworks.Add(@{ kind = 'WAF'; controlId = $text.Trim() }) | Out-Null
            }
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($Pillar)) {
        $frameworks.Add(@{ kind = 'WAF'; controlId = $Pillar }) | Out-Null
    }
    return @($frameworks)
}

if (-not (Test-AzqrInstalled)) {
    Write-MissingToolNotice -Tool 'azqr' -Message "azqr is not installed. Skipping Azqr scan. Install from https://azure.github.io/azqr"
    return [PSCustomObject]@{
        Source   = 'azqr'
        SchemaVersion = '1.0'
        Status   = 'Skipped'
        Message  = 'azqr not installed'
        Findings = @()
    }    Errors   = @()
$3
}

if (-not (Test-Path $OutputPath)) {
    $null = New-Item -ItemType Directory -Path $OutputPath -Force
}

try {
    Write-Verbose "Running azqr scan for subscription $SubscriptionId"
    $toolVersion = Get-AzqrToolVersion
    $null = azqr scan --subscription-id $SubscriptionId --output-dir $OutputPath 2>&1

    $jsonFiles = Get-ChildItem -Path $OutputPath -Filter '*.json' -ErrorAction SilentlyContinue
    $findings = @()

    foreach ($file in $jsonFiles) {
        try {
            $data = Get-Content -Raw $file.FullName | ConvertFrom-Json -ErrorAction Stop
            $records = if ($data -is [array]) { @($data) } elseif ($null -ne $data) { @($data) } else { @() }
            foreach ($record in $records) {
                $pillar = Resolve-AzqrPillar -Finding $record
                $frameworks = Resolve-AzqrFrameworks -Finding $record -Pillar $pillar
                $recordVersion = [string](Get-PropertyValue $record 'ToolVersion' $toolVersion)
                $mitreTactics = Convert-ToStringArray (Get-PropertyValue $record 'MitreTactics' (Get-PropertyValue $record 'Tactics' @()))
                $mitreTechniques = Convert-ToStringArray (Get-PropertyValue $record 'MitreTechniques' (Get-PropertyValue $record 'Techniques' @()))

                $findings += [PSCustomObject]@{
                    Source               = [string](Get-PropertyValue $record 'Source' 'azqr')
                    Id                   = [string](Get-PropertyValue $record 'Id' '')
                    ResourceId           = [string](Get-PropertyValue $record 'ResourceId' (Get-PropertyValue $record 'Id' ''))
                    Category             = [string](Get-PropertyValue $record 'Category' (Get-PropertyValue $record 'ServiceCategory' 'General'))
                    Title                = [string](Get-PropertyValue $record 'Title' (Get-PropertyValue $record 'Recommendation' ''))
                    Recommendation       = [string](Get-PropertyValue $record 'Recommendation' '')
                    RecommendationId     = [string](Get-PropertyValue $record 'RecommendationId' (Get-PropertyValue $record 'RuleId' ''))
                    Compliant            = Get-PropertyValue $record 'Compliant' $false
                    Severity             = [string](Get-PropertyValue $record 'Severity' (Get-PropertyValue $record 'Risk' 'Info'))
                    Detail               = [string](Get-PropertyValue $record 'Detail' (Get-PropertyValue $record 'Description' ''))
                    LearnMoreUrl         = [string](Get-PropertyValue $record 'LearnMoreUrl' (Get-PropertyValue $record 'Url' ''))
                    Remediation          = [string](Get-PropertyValue $record 'Remediation' '')
                    Impact               = [string](Get-PropertyValue $record 'Impact' '')
                    Effort               = [string](Get-PropertyValue $record 'Effort' '')
                    DeepLinkUrl          = [string](Get-PropertyValue $record 'DeepLinkUrl' (Get-PropertyValue $record 'PortalUrl' ''))
                    Pillar               = $pillar
                    Frameworks           = @($frameworks)
                    MitreTactics         = @($mitreTactics)
                    MitreTechniques      = @($mitreTechniques)
                    RemediationSnippets  = @(Get-PropertyValue $record 'RemediationSnippets' @())
                    EvidenceUris         = @(Convert-ToStringArray (Get-PropertyValue $record 'EvidenceUris' @()))
                    BaselineTags         = @(Convert-ToStringArray (Get-PropertyValue $record 'BaselineTags' @()))
                    EntityRefs           = @(Convert-ToStringArray (Get-PropertyValue $record 'EntityRefs' @()))
                    ToolVersion          = $recordVersion
                    SchemaVersion        = '1.0'
                }
            }
        } catch {
            Write-Warning "Could not parse azqr output file $($file.Name): $(Remove-Credentials -Text ([string]$_))"
        }
    }

    return [PSCustomObject]@{
        Source   = 'azqr'
        SchemaVersion = '1.0'
        Status   = 'Success'
        Message  = ''
        ToolVersion = $toolVersion
        Findings = $findings
    }
} catch {
    Write-Warning "azqr scan failed: $(Remove-Credentials -Text ([string]$_))"
    return [PSCustomObject]@{
        Source   = 'azqr'
        SchemaVersion = '1.0'
        Status   = 'Failed'
        Message  = Remove-Credentials -Text ([string]$_)
        Findings = @()
    }    Errors   = @()
$3
}
