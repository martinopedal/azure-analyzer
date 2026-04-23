#Requires -Version 7.4
<#
.SYNOPSIS
    Wrapper for Powerpipe compliance control packs.
.DESCRIPTION
    Runs a Powerpipe benchmark and returns a v1 envelope with flattened control
    findings for downstream normalization. Never throws.
.PARAMETER SubscriptionId
    Azure subscription ID used for entity fallback IDs in normalization.
.PARAMETER Benchmark
    Powerpipe benchmark selector. Default: all.
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param (
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string] $SubscriptionId,

    [string] $Benchmark = 'all'
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

$errorsPath = Join-Path $PSScriptRoot 'shared' 'Errors.ps1'
if (Test-Path $errorsPath) { . $errorsPath }
$envelopePath = Join-Path $PSScriptRoot 'shared' 'New-WrapperEnvelope.ps1'
if (Test-Path $envelopePath) { . $envelopePath }
if (-not (Get-Command New-WrapperEnvelope -ErrorAction SilentlyContinue)) { function New-WrapperEnvelope { param([string]$Source,[string]$Status='Failed',[string]$Message='',[object[]]$FindingErrors=@()) return [PSCustomObject]@{ Source=$Source; SchemaVersion='1.0'; Status=$Status; Message=$Message; Findings=@(); Errors=@($FindingErrors) } } }
if (-not (Get-Command New-FindingError -ErrorAction SilentlyContinue)) {
    function New-FindingError { param([string]$Source,[string]$Category,[string]$Reason,[string]$Remediation,[string]$Details) return [pscustomobject]@{ Source=$Source; Category=$Category; Reason=$Reason; Remediation=$Remediation; Details=$Details } }
}
if (-not (Get-Command Format-FindingErrorMessage -ErrorAction SilentlyContinue)) {
    function Format-FindingErrorMessage {
        param([Parameter(Mandatory)]$FindingError)
        $line = "[{0}] {1}: {2}" -f $FindingError.Source, $FindingError.Category, $FindingError.Reason
        if ($FindingError.Remediation) { $line += " Action: $($FindingError.Remediation)" }
        return $line
    }
}

function Test-PowerpipeInstalled {
    return $null -ne (Get-Command powerpipe -ErrorAction SilentlyContinue)
}

function Get-Prop {
    param([object]$Obj, [string[]]$Names, [object]$Default = $null)
    if ($null -eq $Obj) { return $Default }
    foreach ($name in $Names) {
        $prop = $Obj.PSObject.Properties[$name]
        if ($null -ne $prop -and $null -ne $prop.Value) { return $prop.Value }
    }
    return $Default
}

function Flatten-PowerpipeControls {
    param (
        [Parameter(Mandatory)]
        [object] $Node,
        [Parameter(Mandatory)]
        [System.Collections.Generic.List[object]] $Findings
    )

    if ($null -eq $Node) { return }
    if ($Node -is [array]) {
        foreach ($item in $Node) {
            Flatten-PowerpipeControls -Node $item -Findings $Findings
        }
        return
    }

    $controls = Get-Prop -Obj $Node -Names @('controls', 'Controls') -Default @()
    foreach ($control in @($controls)) {
        if ($null -eq $control) { continue }
        $status = [string](Get-Prop -Obj $control -Names @('status', 'Status') -Default '')
        $controlId = [string](Get-Prop -Obj $control -Names @('control_id', 'controlId', 'id', 'name', 'key') -Default ([guid]::NewGuid().ToString()))
        $title = [string](Get-Prop -Obj $control -Names @('title', 'Title', 'display_name', 'description') -Default $controlId)
        $detail = [string](Get-Prop -Obj $control -Names @('description', 'Description', 'reason', 'summary') -Default '')
        $severity = [string](Get-Prop -Obj $control -Names @('severity', 'Severity', 'level') -Default 'Medium')
        $resourceId = [string](Get-Prop -Obj $control -Names @('resource_id', 'resourceId', 'ResourceId') -Default '')
        $learnMore = [string](Get-Prop -Obj $control -Names @('documentation_url', 'DocumentationUrl', 'doc_url', 'LearnMoreUrl') -Default '')
        $remediation = [string](Get-Prop -Obj $control -Names @('remediation_doc', 'remediation', 'Remediation') -Default '')
        $tags = Get-Prop -Obj $control -Names @('tags', 'Tags') -Default @{}
        $evidence = Get-Prop -Obj $control -Names @('evidence_uris', 'EvidenceUris') -Default @()
        $rows = Get-Prop -Obj $control -Names @('rows', 'Rows') -Default @()
        if ((-not $evidence -or @($evidence).Count -eq 0) -and $rows) {
            $rowUris = [System.Collections.Generic.List[string]]::new()
            foreach ($row in @($rows)) {
                $uri = [string](Get-Prop -Obj $row -Names @('url', 'uri', 'link', 'deep_link') -Default '')
                if (-not [string]::IsNullOrWhiteSpace($uri)) { $rowUris.Add($uri) | Out-Null }
            }
            $evidence = @($rowUris)
        }

        $Findings.Add([pscustomobject]@{
                Id                 = "powerpipe/$controlId"
                Source             = 'powerpipe'
                ControlId          = $controlId
                Title              = $title
                Status             = $status
                Severity           = $severity
                Category           = [string](Get-Prop -Obj $control -Names @('category', 'Category', 'group') -Default '')
                Detail             = $detail
                Remediation        = $remediation
                ResourceId         = $resourceId
                LearnMoreUrl       = $learnMore
                Tags               = $tags
                EvidenceUris       = @($evidence)
                DeepLinkUrl        = [string](Get-Prop -Obj $control -Names @('deep_link_url', 'DeepLinkUrl') -Default $learnMore)
                RemediationSnippets = @()
                BaselineTags       = @()
                ToolVersion        = ''
            }) | Out-Null
    }

    foreach ($childName in @('children', 'benchmarks', 'groups', 'items')) {
        $children = Get-Prop -Obj $Node -Names @($childName) -Default @()
        foreach ($child in @($children)) {
            Flatten-PowerpipeControls -Node $child -Findings $Findings
        }
    }
}

if (-not (Test-PowerpipeInstalled)) {
    Write-MissingToolNotice -Tool 'powerpipe' -Message 'powerpipe is not installed. Skipping Powerpipe scan. Install from https://powerpipe.io'
    return [PSCustomObject]@{
        Source        = 'powerpipe'
        SchemaVersion = '1.0'
        Status        = 'Skipped'
        Message       = 'powerpipe not installed'
        ToolVersion   = ''
        Findings      = @()
        Errors   = @()
    }
}

try {
    $versionOut = (& powerpipe --version 2>&1 | Select-Object -First 1)
    $toolVersion = if ($versionOut) { [string]$versionOut } else { '' }

    $rawOutput = & powerpipe benchmark run $Benchmark --output json 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw (Format-FindingErrorMessage (New-FindingError `
            -Source 'wrapper:powerpipe' `
            -Category 'UnexpectedFailure' `
            -Reason "powerpipe benchmark run failed (exit $LASTEXITCODE)." `
            -Remediation 'Inspect powerpipe CLI output; ensure the benchmark mod is installed and credentials configured.' `
            -Details (Remove-Credentials -Text ([string]$rawOutput))))
    }

    $parsed = $rawOutput | ConvertFrom-Json -Depth 100 -ErrorAction Stop
    $findings = [System.Collections.Generic.List[object]]::new()

    if ($parsed.PSObject.Properties['findings'] -and $parsed.findings) {
        foreach ($f in @($parsed.findings)) {
            $findings.Add($f) | Out-Null
        }
    } else {
        Flatten-PowerpipeControls -Node $parsed -Findings $findings
    }

    foreach ($f in @($findings)) {
        if (-not $f.PSObject.Properties['ToolVersion']) {
            $f | Add-Member -NotePropertyName ToolVersion -NotePropertyValue $toolVersion -Force
        } elseif (-not $f.ToolVersion) {
            $f.ToolVersion = $toolVersion
        }
    }

    return [PSCustomObject]@{
        Source        = 'powerpipe'
        SchemaVersion = '1.0'
        Status        = 'Success'
        Message       = ''
        ToolVersion   = $toolVersion
        Subscription  = $SubscriptionId
        Findings      = @($findings)
        Errors   = @()
    }
} catch {
    Write-Warning "powerpipe scan failed: $(Remove-Credentials -Text ([string]$_))"
    return [PSCustomObject]@{
        Source        = 'powerpipe'
        SchemaVersion = '1.0'
        Status        = 'Failed'
        Message       = (Remove-Credentials -Text ([string]$_))
        ToolVersion   = ''
        Findings      = @()
        Errors   = @()
    }
}
