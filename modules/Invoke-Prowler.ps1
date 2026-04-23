#Requires -Version 7.4
[CmdletBinding()]
param (
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string] $SubscriptionId,

    [string] $OutputPath = (Join-Path (Get-Location) 'output' 'prowler')
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

function Get-ObjProp {
    param([object]$Obj, [string]$Name, [object]$Default = $null)
    if ($null -eq $Obj) { return $Default }
    $p = $Obj.PSObject.Properties[$Name]
    if ($null -eq $p -or $null -eq $p.Value) { return $Default }
    return $p.Value
}

function Test-ProwlerInstalled {
    $null -ne (Get-Command prowler -ErrorAction SilentlyContinue)
}

function Get-ProwlerVersion {
    try {
        $output = prowler --version 2>$null
        $text = ($output | Out-String).Trim()
        if ($text -match '(\d+\.\d+\.\d+)') {
            return $Matches[1]
        }
    } catch {} # best-effort: prowler CLI not installed; ToolVersion stays empty
    return ''
}

function Convert-FrameworkDisplayName {
    param([string]$Name)
    if ([string]::IsNullOrWhiteSpace($Name)) { return '' }
    $raw = $Name.Trim()
    $upper = $raw.ToUpperInvariant()
    if ($upper -like '*CIS*') { return 'CIS' }
    if ($upper -like '*NIST*') { return 'NIST' }
    if ($upper -like '*ISO*27001*') { return 'ISO27001' }
    if ($upper -like '*PCI*') { return 'PCI-DSS' }
    if ($upper -like '*HIPAA*') { return 'HIPAA' }
    if ($upper -like '*SOC*2*') { return 'SOC2' }
    if ($upper -like '*MITRE*') { return 'MITRE ATT&CK' }
    if ($upper -like '*GDPR*') { return 'GDPR' }
    if ($upper -like '*FEDRAMP*') { return 'FedRAMP' }
    return ($raw -replace '_', ' ')
}

function Get-ProwlerFrameworkNames {
    param([object]$Check)
    $names = [System.Collections.Generic.List[string]]::new()

    $compliance = Get-ObjProp -Obj $Check -Name 'Compliance'
    if ($compliance) {
        foreach ($prop in $compliance.PSObject.Properties) {
            $display = Convert-FrameworkDisplayName -Name ([string]$prop.Name)
            if (-not [string]::IsNullOrWhiteSpace($display) -and -not $names.Contains($display)) {
                $names.Add($display) | Out-Null
            }
        }
    }

    $frameworks = Get-ObjProp -Obj $Check -Name 'Frameworks'
    foreach ($item in @($frameworks)) {
        $candidate = if ($item -is [string]) { $item } else { Get-ObjProp -Obj $item -Name 'Name' '' }
        $display = Convert-FrameworkDisplayName -Name ([string]$candidate)
        if (-not [string]::IsNullOrWhiteSpace($display) -and -not $names.Contains($display)) {
            $names.Add($display) | Out-Null
        }
    }

    return @($names)
}

function Get-ProwlerRemediationSnippets {
    param([object]$Check)
    $snippets = [System.Collections.Generic.List[hashtable]]::new()
    $remediation = Get-ObjProp -Obj $Check -Name 'Remediation'
    $code = if ($remediation) { Get-ObjProp -Obj $remediation -Name 'Code' } else { $null }
    if (-not $code) { return @() }

    foreach ($prop in $code.PSObject.Properties) {
        $value = [string]$prop.Value
        if ([string]::IsNullOrWhiteSpace($value)) { continue }
        $snippets.Add(@{ Type = [string]$prop.Name; Code = $value }) | Out-Null
    }
    return @($snippets)
}

if (-not (Test-ProwlerInstalled)) {
    Write-MissingToolNotice -Tool 'prowler' -Message 'prowler is not installed. Skipping Prowler scan. Install from https://github.com/prowler-cloud/prowler'
    return [PSCustomObject]@{
        Source        = 'prowler'
        SchemaVersion = '1.0'
        Status        = 'Skipped'
        Message       = 'prowler not installed'
        ToolVersion   = ''
        Findings      = @()
    }
}

if (-not (Test-Path $OutputPath)) {
    $null = New-Item -ItemType Directory -Path $OutputPath -Force
}

$toolVersion = Get-ProwlerVersion

try {
    $null = prowler azure --subscription-id $SubscriptionId --output-formats json --output-directory $OutputPath --output-filename "prowler-$SubscriptionId" 2>&1

    $jsonFiles = Get-ChildItem -Path $OutputPath -Filter '*.json' -File -ErrorAction SilentlyContinue
    $rawChecks = [System.Collections.Generic.List[object]]::new()
    foreach ($file in $jsonFiles) {
        try {
            $parsed = Get-Content -Raw $file.FullName | ConvertFrom-Json -ErrorAction Stop
            foreach ($entry in @($parsed)) { $rawChecks.Add($entry) | Out-Null }
        } catch {
            Write-Warning "Could not parse prowler output file $($file.Name): $(Remove-Credentials -Text ([string]$_))"
        }
    }

    $findings = [System.Collections.Generic.List[PSCustomObject]]::new()
    foreach ($check in $rawChecks) {
        $checkId = [string](Get-ObjProp -Obj $check -Name 'CheckID' (Get-ObjProp -Obj $check -Name 'CheckId' (Get-ObjProp -Obj $check -Name 'Id' '')))
        if ([string]::IsNullOrWhiteSpace($checkId)) { $checkId = [guid]::NewGuid().ToString() }

        $frameworkNames = @(Get-ProwlerFrameworkNames -Check $check)
        $frameworks = @(
            foreach ($frameworkName in $frameworkNames) {
                @{
                    Name     = $frameworkName
                    Controls = @($checkId)
                }
            }
        )
        $baselineTags = @(
            foreach ($frameworkName in $frameworkNames) {
                "baseline:$($frameworkName.ToLowerInvariant())"
            }
        )

        $status = [string](Get-ObjProp -Obj $check -Name 'Status' '')
        $isCompliant = $status -match '^(?i)pass(ed)?$'
        $severityRaw = [string](Get-ObjProp -Obj $check -Name 'Severity' 'medium')
        $severity = switch -Regex ($severityRaw.ToLowerInvariant()) {
            'critical' { 'Critical' }
            '^high$' { 'High' }
            '^medium$' { 'Medium' }
            '^low$' { 'Low' }
            '^info' { 'Info' }
            default { 'Medium' }
        }

        $resourceArn = [string](Get-ObjProp -Obj $check -Name 'ResourceArn' (Get-ObjProp -Obj $check -Name 'ResourceARN' ''))
        $resourceId = [string](Get-ObjProp -Obj $check -Name 'ResourceId' (Get-ObjProp -Obj $check -Name 'ResourceID' $resourceArn))
        $learnMore = [string](Get-ObjProp -Obj $check -Name 'LearnMoreUrl' '')
        if ([string]::IsNullOrWhiteSpace($learnMore)) {
            $remediationObj = Get-ObjProp -Obj $check -Name 'Remediation'
            $recommendationObj = if ($remediationObj) { Get-ObjProp -Obj $remediationObj -Name 'Recommendation' } else { $null }
            $learnMore = [string](Get-ObjProp -Obj $recommendationObj -Name 'Url' '')
        }
        $deepLink = [string](Get-ObjProp -Obj $check -Name 'DeepLinkUrl' '')
        if ([string]::IsNullOrWhiteSpace($deepLink)) {
            $deepLink = "https://docs.prowler.com/checks/$checkId"
        }
        if ([string]::IsNullOrWhiteSpace($learnMore)) {
            $learnMore = $deepLink
        }

        $remediation = ''
        $remediationObj = Get-ObjProp -Obj $check -Name 'Remediation'
        if ($remediationObj) {
            $recommendationObj = Get-ObjProp -Obj $remediationObj -Name 'Recommendation'
            if ($recommendationObj) {
                $remediation = [string](Get-ObjProp -Obj $recommendationObj -Name 'Text' '')
            }
        }

        $findings.Add([PSCustomObject]@{
            Id                  = $checkId
            RuleId              = $checkId
            Source              = 'prowler'
            Category            = [string](Get-ObjProp -Obj $check -Name 'ServiceName' 'SecurityPosture')
            Title               = [string](Get-ObjProp -Obj $check -Name 'CheckTitle' (Get-ObjProp -Obj $check -Name 'Title' $checkId))
            Severity            = $severity
            Compliant           = [bool]$isCompliant
            Detail              = [string](Get-ObjProp -Obj $check -Name 'StatusExtended' (Get-ObjProp -Obj $check -Name 'Description' ''))
            Remediation         = $remediation
            LearnMoreUrl        = $learnMore
            DeepLinkUrl         = $deepLink
            ResourceId          = $resourceId
            ResourceArn         = $resourceArn
            Pillar              = 'Security'
            Frameworks          = $frameworks
            BaselineTags        = $baselineTags
            MitreTactics        = @((Get-ObjProp -Obj $check -Name 'MitreTactics' @()))
            MitreTechniques     = @((Get-ObjProp -Obj $check -Name 'MitreTechniques' @()))
            RemediationSnippets = @(Get-ProwlerRemediationSnippets -Check $check)
            ToolVersion         = $toolVersion
            SchemaVersion       = '1.0'
        }) | Out-Null
    }

    return [PSCustomObject]@{
        Source        = 'prowler'
        SchemaVersion = '1.0'
        Status        = 'Success'
        Message       = ''
        ToolVersion   = $toolVersion
        Findings      = @($findings)
    }
} catch {
    Write-Warning "prowler scan failed: $(Remove-Credentials -Text ([string]$_))"
    return [PSCustomObject]@{
        Source        = 'prowler'
        SchemaVersion = '1.0'
        Status        = 'Failed'
        Message       = Remove-Credentials -Text ([string]$_)
        ToolVersion   = $toolVersion
        Findings      = @()
    }
}
