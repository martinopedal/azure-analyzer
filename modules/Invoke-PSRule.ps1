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
$envelopePath = Join-Path $PSScriptRoot 'shared' 'New-WrapperEnvelope.ps1'
if (Test-Path $envelopePath) { . $envelopePath }
if (-not (Get-Command New-WrapperEnvelope -ErrorAction SilentlyContinue)) { function New-WrapperEnvelope { param([string]$Source,[string]$Status='Failed',[string]$Message='',[object[]]$FindingErrors=@()) return [PSCustomObject]@{ Source=$Source; SchemaVersion='1.0'; Status=$Status; Message=$Message; Findings=@(); Errors=@($FindingErrors) } } }
$errorsPath = Join-Path $PSScriptRoot 'shared' 'Errors.ps1'
if (Test-Path $errorsPath) { . $errorsPath }
if (-not (Get-Command New-FindingError -ErrorAction SilentlyContinue)) {
    function New-FindingError { param([string]$Source,[string]$Category,[string]$Reason,[string]$Remediation,[string]$Details) return [pscustomobject]@{ Source=$Source; Category=$Category; Reason=$Reason; Remediation=$Remediation; Details=$Details } }
}
if (-not (Get-Command Format-FindingErrorMessage -ErrorAction SilentlyContinue)) {
    function Format-FindingErrorMessage { param([Parameter(Mandatory)]$FindingError) $line = "[{0}] {1}: {2}" -f $FindingError.Source, $FindingError.Category, $FindingError.Reason; if ($FindingError.Remediation) { $line += " Action: $($FindingError.Remediation)" }; return $line }
}
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
        [AllowNull()]
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
        Errors   = @()
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
        Write-Verbose "Exporting Azure resource data for subscription: $SubscriptionId"
        # PSRule.Rules.Azure cannot scan a live subscription directly. Resources must first be
        # exported to JSON by Export-AzRuleData and then scanned by path. Previously this branch
        # passed no InputPath at all, so every subscription scan silently returned nothing.
        $exportPath = Join-Path ([System.IO.Path]::GetTempPath()) ("psrule-" + $SubscriptionId)
        if (Test-Path $exportPath) { Remove-Item (Join-Path $exportPath '*') -Force -Recurse -ErrorAction SilentlyContinue }
        else { $null = New-Item -ItemType Directory -Path $exportPath -Force }
        $exportParams = @{ Subscription = $SubscriptionId; OutputPath = $exportPath; ErrorAction = 'Stop' }

        # Scope the export to the tenant that owns the TARGET subscription. Taking the tenant
        # from the current context instead would pin every scan to whichever tenant happened to
        # be active and export nothing for subscriptions in any other tenant. The Az context is
        # process-wide, and Invoke-ParallelTools runs Azure tools concurrently, so this wrapper
        # must not call Set-AzContext: switching the active subscription here would change it
        # underneath every other tool running at the same time.
        $targetSub = Get-AzSubscription -SubscriptionId $SubscriptionId -ErrorAction SilentlyContinue
        if ($targetSub -and $targetSub.PSObject.Properties['TenantId'] -and $targetSub.TenantId) {
            $exportParams['Tenant'] = [string]$targetSub.TenantId
        }

        $null = Export-AzRuleData @exportParams -WarningAction SilentlyContinue

        # Export-AzRuleData returns quietly when no Az context matches the requested
        # subscription, so an empty output directory is the only available signal. Fail loudly
        # instead of scanning an empty folder and reporting a clean, empty result.
        $exportedFiles = @(Get-ChildItem -Path $exportPath -Filter '*.json' -File -ErrorAction SilentlyContinue)
        if ($exportedFiles.Count -eq 0) {
            throw (Format-FindingErrorMessage (New-FindingError `
                -Source 'wrapper:psrule' `
                -Category 'NotFound' `
                -Reason "Export-AzRuleData produced no resource data for subscription '$SubscriptionId'." `
                -Remediation 'Confirm the signed-in account has an Az context for this subscription (Connect-AzAccount) and at least Reader access to it.'))
        }

        Write-Verbose "Running PSRule on $($exportedFiles.Count) exported file(s) in: $exportPath"
        $invokeParams['InputPath'] = (Join-Path $exportPath '*.json')
        $invokeParams['Option'] = @{ 'Configuration.AZURE_SUBSCRIPTION_ID' = $SubscriptionId }
    }

    $results = Invoke-PSRule @invokeParams -ErrorAction Stop

    $findings = @($results) | ForEach-Object {
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

        $resourceArmId = ''
        $targetObj = if ($_.PSObject.Properties['TargetObject']) { $_.TargetObject } else { $null }
        if ($targetObj) {
            foreach ($propName in @('id', 'Id', 'resourceId', 'ResourceId')) {
                if ($targetObj.PSObject.Properties[$propName]) {
                    $candStr = [string]$targetObj.PSObject.Properties[$propName].Value
                    if ($candStr -match '^/subscriptions/') { $resourceArmId = $candStr; break }
                }
            }
        }
        $targetName = if ($_.PSObject.Properties['TargetName']) { [string]$_.TargetName } else { '' }
        if (-not $resourceArmId -and $targetName -match '^/subscriptions/') {
            $resourceArmId = $targetName
        }

        [PSCustomObject]@{
            Source         = 'psrule'
            Title          = $title
            Category       = $ruleName
            RuleId         = $ruleId
            Compliant      = $isCompliant
            Severity       = $severity
            Detail         = $detail
            ResourceId     = $resourceArmId
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
        Errors   = @()
    }
} catch {
    Write-Warning "PSRule scan failed: $(Remove-Credentials -Text ([string]$_))"
    return [PSCustomObject]@{
        Source   = 'psrule'
        Status   = 'Failed'
        Message  = Remove-Credentials -Text ([string]$_)
        Findings = @()
        Errors   = @()
    }
}
