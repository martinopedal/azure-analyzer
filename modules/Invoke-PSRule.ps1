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
if (-not (Get-Command Remove-Credentials -ErrorAction SilentlyContinue)) {
    function Remove-Credentials { param([string]$Text) return $Text }
}

function Test-PSRuleInstalled {
    $null -ne (Get-Module -Name PSRule -ListAvailable -ErrorAction SilentlyContinue) -and
    $null -ne (Get-Module -Name PSRule.Rules.Azure -ListAvailable -ErrorAction SilentlyContinue)
}

if (-not (Test-PSRuleInstalled)) {
    Write-Warning "PSRule.Rules.Azure is not installed. Skipping PSRule scan. Run: Install-Module PSRule.Rules.Azure"
    return [PSCustomObject]@{
        Source   = 'psrule'
        Status   = 'Skipped'
        Message  = 'PSRule.Rules.Azure not installed'
        Findings = @()
    }
}

try {
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
        $ruleName = $_.RuleName
        $title = if ($info -and $info.DisplayName) { $info.DisplayName } else { $ruleName }
        $detail = if ($_.Detail -and $_.Detail.Reason) { $_.Detail.Reason -join '; ' } else { '' }
        $learnUrl = ''
        if ($info -and $info.Annotations) {
            $onlineVer = $info.Annotations.'online version'
            if ($onlineVer) { $learnUrl = $onlineVer }
        }
        $remediation = if ($info -and $info.Recommendation) { $info.Recommendation } else { '' }

        [PSCustomObject]@{
            Source        = 'psrule'
            Title         = $title
            Category      = $ruleName
            Compliant     = ($_.Outcome.ToString() -eq 'Pass')
            Severity      = 'Medium'
            Detail        = $detail
            ResourceId    = if ($_.TargetName -match '^/subscriptions/') { $_.TargetName } else { '' }
            LearnMoreUrl  = $learnUrl
            Remediation   = $remediation
            SchemaVersion = '1.0'
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
