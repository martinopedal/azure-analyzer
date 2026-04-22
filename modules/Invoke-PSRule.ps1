#Requires -Version 7.0
<#
.SYNOPSIS
    Wrapper for PSRule for Azure.
.DESCRIPTION
    Runs PSRule.Rules.Azure against a subscription or IaC path.
    Returns PSObject array of rule violations.
    If PSRule is not installed, writes a warning and returns empty result.
    Never throws.
.PARAMETER SubscriptionId
    Azure subscription ID to evaluate. Used for live Azure resource evaluation.
.PARAMETER Path
    Path to IaC files (ARM templates, Bicep) for static analysis.
    Mutually exclusive with SubscriptionId.
#>
[CmdletBinding(DefaultParameterSetName = 'Subscription')]
param (
    [Parameter(Mandatory, ParameterSetName = 'Subscription')]
    [ValidateNotNullOrEmpty()]
    [string] $SubscriptionId,

    [Parameter(Mandatory, ParameterSetName = 'Path')]
    [ValidateNotNullOrEmpty()]
    [string] $Path
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

function Test-PSRuleInstalled {
    $null -ne (Get-Module -Name PSRule -ListAvailable -ErrorAction SilentlyContinue) -and
    $null -ne (Get-Module -Name PSRule.Rules.Azure -ListAvailable -ErrorAction SilentlyContinue)
}

function Get-PSRuleToolVersion {
    $module = Get-Module -Name PSRule.Rules.Azure -ListAvailable -ErrorAction SilentlyContinue |
        Sort-Object -Property Version -Descending |
        Select-Object -First 1
    if ($module -and $module.Version) {
        return [string]$module.Version
    }
    return ''
}

function Convert-PSRuleLevelToSeverity {
    param (
        [Parameter(Mandatory)]
        [string] $Level
    )

    switch -Regex ($Level.ToLowerInvariant()) {
        'critical'    { return 'Critical' }
        'error|high'  { return 'High' }
        'warning|medium' { return 'Medium' }
        'low'         { return 'Low' }
        'information|info' { return 'Info' }
        default       { return 'Medium' }
    }
}

function Get-PSRuleAnnotationValue {
    param (
        [Parameter(Mandatory)]
        [object] $Annotations,
        [Parameter(Mandatory)]
        [string[]] $KeyHints
    )

    if ($null -eq $Annotations) { return $null }
    foreach ($property in $Annotations.PSObject.Properties) {
        $name = [string]$property.Name
        foreach ($hint in $KeyHints) {
            if ($name -match $hint) {
                return $property.Value
            }
        }
    }
    return $null
}

function ConvertTo-StringArray {
    param([object] $Value)
    if ($null -eq $Value) { return @() }
    if ($Value -is [string]) {
        if ([string]::IsNullOrWhiteSpace($Value)) { return @() }
        return @($Value.Trim())
    }
    if ($Value -is [System.Collections.IEnumerable]) {
        return @($Value | ForEach-Object {
                if ($null -eq $_) { return }
                $candidate = [string]$_
                if (-not [string]::IsNullOrWhiteSpace($candidate)) { $candidate.Trim() }
            } | Where-Object { $_ } | Select-Object -Unique)
    }
    return @([string]$Value)
}

if (-not (Test-PSRuleInstalled)) {
    Write-MissingToolNotice -Tool 'psrule' -Message "PSRule.Rules.Azure is not installed. Skipping PSRule scan. Run: Install-Module PSRule.Rules.Azure"
    return [PSCustomObject]@{
        Source   = 'psrule'
        Status   = 'Skipped'
        Message  = 'PSRule.Rules.Azure not installed'
        Findings = @()
    }
}

try {
    $toolVersion = Get-PSRuleToolVersion
    $invokeParams = @{
        Module = 'PSRule.Rules.Azure'
    }

    if ($PSCmdlet.ParameterSetName -eq 'Path') {
        Write-Verbose "Running PSRule on path: $Path"
        $invokeParams['InputPath'] = $Path
    } else {
        Write-Verbose "Running PSRule for subscription: $SubscriptionId"
        $invokeParams['Option'] = @{ 'Configuration.AZURE_SUBSCRIPTION_ID' = $SubscriptionId }
    }

    $results = Invoke-PSRule @invokeParams -ErrorAction Stop

    $findings = $results | ForEach-Object {
        $info = $_.Info
        $ruleName = if ($_.PSObject.Properties['RuleName'] -and $_.RuleName) { [string]$_.RuleName } else { '' }
        $ruleId = if ($_.PSObject.Properties['RuleId'] -and $_.RuleId) { [string]$_.RuleId } elseif ($ruleName) { $ruleName } else { '' }
        $title = if ($info -and $info.DisplayName) { $info.DisplayName } else { $ruleName }
        $detail = if ($_.Detail -and $_.Detail.Reason) { $_.Detail.Reason -join '; ' } else { '' }
        $learnUrl = if ($ruleId) { "https://azure.github.io/PSRule.Rules.Azure/en/rules/$ruleId/" } else { '' }
        $deepLinkUrl = $learnUrl
        $annotations = if ($info -and $info.Annotations) { $info.Annotations } else { $null }
        $onlineVersion = Get-PSRuleAnnotationValue -Annotations $annotations -KeyHints @('(?i)^online version$', '(?i)url$')
        if ($onlineVersion) {
            $learnUrl = [string]$onlineVersion
            $deepLinkUrl = [string]$onlineVersion
        }

        $pillar = ''
        $pillarValue = Get-PSRuleAnnotationValue -Annotations $annotations -KeyHints @('(?i)waf.*/pillar', '(?i)^pillar$')
        if ($pillarValue) {
            $pillar = [string]$pillarValue
        }

        $baselineTags = @()
        if ($info -and $info.PSObject.Properties['Baseline']) {
            $baselineTags += ConvertTo-StringArray -Value $info.Baseline
        }
        $annotationBaselines = Get-PSRuleAnnotationValue -Annotations $annotations -KeyHints @('(?i)baseline')
        if ($annotationBaselines) {
            $baselineTags += ConvertTo-StringArray -Value $annotationBaselines
        }
        $baselineTags = @($baselineTags | Select-Object -Unique)

        $remediation = if ($info -and $info.Recommendation) { $info.Recommendation } else { '' }
        $frameworks = @()
        if ($ruleName) {
            $frameworks = @(
                @{
                    Name     = 'WAF'
                    Controls = @($ruleName)
                }
            )
        }

        $outcome = ''
        if ($_.PSObject.Properties['Outcome'] -and $_.Outcome) {
            $outcome = [string]$_.Outcome
        }
        $isCompliant = ($outcome -eq 'Pass')
        $level = if ($_.PSObject.Properties['Level'] -and $_.Level) { [string]$_.Level } else { 'Warning' }
        $severity = if ($isCompliant) { 'Info' } else { Convert-PSRuleLevelToSeverity -Level $level }

        [PSCustomObject]@{
            Source         = 'psrule'
            Title          = $title
            Category       = $ruleName
            RuleId         = $ruleId
            Compliant      = $isCompliant
            Severity       = $severity
            Detail         = $detail
            ResourceId     = if ($_.TargetName -match '^/subscriptions/') { $_.TargetName } else { '' }
            LearnMoreUrl   = $learnUrl
            DeepLinkUrl    = $deepLinkUrl
            Remediation    = $remediation
            Pillar         = $pillar
            Frameworks     = $frameworks
            BaselineTags   = $baselineTags
            ToolVersion    = $toolVersion
            SchemaVersion  = '1.0'
        }
    }

    return [PSCustomObject]@{
        Source   = 'psrule'
        Status   = 'Success'
        Message  = ''
        Findings = @($findings)
    }
} catch {
    Write-Warning "PSRule scan failed: $(Remove-Credentials -Text ([string]$_))"
    return [PSCustomObject]@{
        Source   = 'psrule'
        Status   = 'Failed'
        Message  = Remove-Credentials -Text ([string]$_)
        Findings = @()
    }
}
