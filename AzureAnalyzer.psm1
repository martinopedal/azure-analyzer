#Requires -Version 7.4
<#
.SYNOPSIS
    Azure Analyzer PowerShell Module - Root module script.
.DESCRIPTION
    Loads shared helper functions and root-level public entry scripts.
    The public commands are exposed via wrapper functions that invoke the
    scripts (Invoke-AzureAnalyzer.ps1, New-HtmlReport.ps1, New-MdReport.ps1).
    
    This is a local module for convenience; use after Import-Module ./AzureAnalyzer.psd1
    in the cloned repository.
#>

Set-StrictMode -Version Latest

# Get the module root path
$ModuleRoot = $PSScriptRoot

# Dot-source shared helper modules only
# Wrapper/normalizer/report scripts are invoked by the orchestrator and not loaded at import time
$sharedModulePath = Join-Path $ModuleRoot 'modules\shared'
Get-ChildItem -Path $sharedModulePath -Filter '*.ps1' -Recurse -ErrorAction SilentlyContinue | ForEach-Object {
    . $_.FullName
}

# Import public functions from root level
# These are exported in the manifest as FunctionsToExport
$publicFunctions = @(
    'Invoke-AzureAnalyzer',
    'New-HtmlReport',
    'New-MdReport'
)

function Invoke-ModuleScript {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $ScriptPath,

        [Parameter(ValueFromRemainingArguments = $true)]
        [object[]] $Arguments
    )

    if (-not (Test-Path $ScriptPath)) {
        throw "Required script not found: $ScriptPath"
    }

    & $ScriptPath @Arguments
}

function Invoke-AzureAnalyzer {
    [CmdletBinding()]
    param(
        [Parameter(ParameterSetName = 'Help')]
        [switch] $Help,
        [string] $SubscriptionId,
        [string] $ManagementGroupId,
        [string] $TenantId,
        [string] $OutputPath = (Join-Path $ModuleRoot 'output'),
        [string[]] $IncludeTools,
        [string[]] $ExcludeTools,
        [switch] $NonInteractive,
        [switch] $SkipPrereqCheck,
        [switch] $InstallMissingModules,
        [string] $InstallConfigPath,
        [switch] $Recurse,
        [string] $Repository,
        [string] $GitHubHost = 'github.com',
        [string] $RepoPath,
        [Alias('AdoOrganization')]
        [string] $AdoOrg,
        [string] $AdoProject,
        [Alias('AdoPatToken')]
        [string] $AdoPat,
        [string] $GitleaksConfigPath,
        [string] $AdoOrganizationUrl,
        [string] $AdoServerUrl,
        [string] $AdoRepoUrl,
        [ValidateRange(0, 10)]
        [int] $ScorecardThreshold = 7,
        [string] $ScanPath,
        [ValidateSet('fs', 'repo')]
        [string] $ScanType,
        [ValidateSet('CIS', 'NIST', 'PCI')]
        [string] $Framework,
        [string] $PreviousRun,
        [string] $CompareTo,
        [switch] $CompareToPrevious,
        [switch] $Incremental,
        [Nullable[datetime]] $Since,
        [ValidateSet('auto', 'none')]
        [string] $BaselineMode = 'auto',
        [switch] $InstallFalco,
        [switch] $UninstallFalco,
        [ValidateRange(1, 60)]
        [int] $FalcoCaptureMinutes = 5,
        [string] $KubeconfigPath,
        [string] $KubeContext,
        [string] $KubescapeNamespace = '',
        [string] $FalcoNamespace = 'falco',
        [string] $KubeBenchNamespace = 'kube-system',
        [ValidateSet('Default', 'Kubelogin', 'WorkloadIdentity')]
        [string] $KubeAuthMode = 'Default',
        [string] $KubeloginServerId,
        [string] $KubeloginClientId,
        [string] $KubeloginTenantId,
        [string] $WorkloadIdentityClientId,
        [string] $WorkloadIdentityTenantId,
        [string] $WorkloadIdentityServiceAccountToken,
        [string] $SentinelWorkspaceId,
        [ValidateRange(1, 365)]
        [int] $SentinelLookbackDays = 30,
        [switch] $EnableAiTriage,
        [ValidateSet('Pro', 'Business', 'Enterprise')]
        [string] $CopilotTier,
        [ValidatePattern('^(?i)(Auto|Explicit:.+)$')]
        [string] $TriageModel = 'Auto',
        [switch] $SingleModel,
        [ValidateSet('Auto','Force','Off')]
        [string] $AlzReferenceMode = 'Auto',
        [switch] $SinkLogAnalytics,
        [string] $LogAnalyticsConfig,
        [ValidateRange(1, 365)]
        [int] $HistoryRetention = 30,
        [string] $TenantConfig,
        [string[]] $Tenants,
        [switch] $Show,
        [ValidateRange(1, 65535)]
        [int] $ViewerPort = 4280,
        [switch] $NoBanner
    )

    $scriptPath = Join-Path $ModuleRoot 'Invoke-AzureAnalyzer.ps1'
    if (-not (Test-Path $scriptPath)) {
        throw "Required script not found: $scriptPath"
    }

    & $scriptPath @PSBoundParameters
}

function New-HtmlReport {
    [CmdletBinding()]
    param(
        [Parameter(ValueFromRemainingArguments = $true)]
        [object[]] $Arguments
    )

    Invoke-ModuleScript -ScriptPath (Join-Path $ModuleRoot 'New-HtmlReport.ps1') @Arguments
}

function New-MdReport {
    [CmdletBinding()]
    param(
        [Parameter(ValueFromRemainingArguments = $true)]
        [object[]] $Arguments
    )

    Invoke-ModuleScript -ScriptPath (Join-Path $ModuleRoot 'New-MdReport.ps1') @Arguments
}

# Warn if core required modules are missing
$coreRequired = @('Az.Accounts', 'Az.ResourceGraph')
foreach ($moduleName in $coreRequired) {
    if (-not (Get-Module -Name $moduleName -ListAvailable -ErrorAction SilentlyContinue)) {
        Write-Warning "Core module '$moduleName' not found. Install with: Install-Module $moduleName -Scope CurrentUser"
    }
}

# Export public functions
Export-ModuleMember -Function $publicFunctions
