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

function Test-PSRuleInstalled {
    $null -ne (Get-Module -Name PSRule -ListAvailable -ErrorAction SilentlyContinue) -and
    $null -ne (Get-Module -Name PSRule.Rules.Azure -ListAvailable -ErrorAction SilentlyContinue)
}

if (-not (Test-PSRuleInstalled)) {
    Write-Warning "PSRule.Rules.Azure is not installed. Skipping PSRule scan. Run: Install-Module PSRule.Rules.Azure"
    return [PSCustomObject]@{
        Source   = 'psrule'
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
        [PSCustomObject]@{
            RuleName  = $_.RuleName
            Outcome   = $_.Outcome
            TargetName = $_.TargetName
            Message   = $_.Detail.Reason -join '; '
        }
    }

    return [PSCustomObject]@{
        Source   = 'psrule'
        Findings = @($findings)
    }
} catch {
    Write-Warning "PSRule scan failed: $_"
    return [PSCustomObject]@{
        Source   = 'psrule'
        Findings = @()
    }
}
