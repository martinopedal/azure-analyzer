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
    <#
    .SYNOPSIS
        Azure Analyzer — unified Azure assessment orchestrator (v3 manifest-driven).
    .DESCRIPTION
        Reads tools/tool-manifest.json, runs enabled tool wrappers via Invoke-ParallelTools,
        normalises findings into schema v2 FindingRows, feeds them into an EntityStore, and
        writes dual output: output/entities.json (entity-centric) and output/results.json
        (v1-compatible flat findings).
        At least one of -SubscriptionId or -ManagementGroupId is required for Azure-scoped
        tools.  Tools that are not installed are skipped gracefully.
    .PARAMETER SubscriptionId
        Azure subscription ID. Used by azqr, PSRule (live), alz-queries, and WARA.
    .PARAMETER ManagementGroupId
        Management group ID. Used by AzGovViz and alz-queries.
    .PARAMETER TenantId
        Azure tenant ID. Used by WARA collector. Defaults to current Az context tenant.
    .PARAMETER OutputPath
        Output directory for results.json. Defaults to .\output.
    .PARAMETER Repository
        GitHub repository to scan with OpenSSF Scorecard (e.g. "github.com/org/repo").
        Required for Scorecard tool; ignored by Azure-scoped tools.
        For GHEC-DR or GHES, use the enterprise host (e.g. "github.contoso.com/org/repo")
        together with -GitHubHost.
    .PARAMETER GitHubHost
        Custom GitHub host for GHEC-DR or GHES instances (e.g. "github.contoso.com").
        Sets the GH_HOST environment variable for the Scorecard CLI. When empty,
        defaults to github.com. Requires a GITHUB_AUTH_TOKEN valid on the enterprise instance.
    .PARAMETER RepoPath
        Local repository path for CI/CD security scanning tools (zizmor, gitleaks).
        Defaults to the current directory. Tools scan workflow files and git history at this path.
    .PARAMETER AdoOrg
        Azure DevOps organization name. Required for ADO-scoped tools
        (e.g. ado-connections, ado-pipelines, ado-repos-secrets, ado-pipeline-correlator).
        When provided, ADO tools are included in the run.
    .PARAMETER AdoProject
        Azure DevOps project name. When omitted, ADO tools scan all projects in the organization.
    .PARAMETER AdoPat
        Azure DevOps PAT passed to ADO-scoped wrappers. Optional; wrappers also read
        ADO_PAT_TOKEN, AZURE_DEVOPS_EXT_PAT, and AZ_DEVOPS_PAT.
    .PARAMETER GitleaksConfigPath
        Optional local path to a gitleaks TOML config file. Forwarded to gitleaks and
        ado-repos-secrets wrappers for org-level or repo-level pattern tuning.
    .PARAMETER AdoOrganizationUrl
        Optional Azure DevOps organization URL for ADO repo secret scanning.
        Supports cloud URLs (dev.azure.com / *.visualstudio.com) and on-prem collection URLs.
    .PARAMETER AdoServerUrl
        Optional Azure DevOps Server collection URL (on-prem) for ADO repo secret scanning.
    .PARAMETER SentinelWorkspaceId
        Full ARM resource ID of the Log Analytics workspace linked to Microsoft Sentinel.
        When provided, the sentinel-incidents tool queries active incidents via KQL.
        Example: /subscriptions/<guid>/resourceGroups/<rg>/providers/Microsoft.OperationalInsights/workspaces/<name>
    .PARAMETER SentinelLookbackDays
        Number of days to look back for Sentinel incidents. Default 30. Range 1-365.
    .PARAMETER EnableAiTriage
        When set, enriches non-compliant findings via GitHub Copilot SDK with priority
        ranking, risk context, and remediation steps. Requires a GitHub Copilot license.
    .PARAMETER SinkLogAnalytics
        When set, sends findings and entities to Azure Monitor Logs Ingestion API using
        stream mapping from -LogAnalyticsConfig.
    .PARAMETER LogAnalyticsConfig
        Path to a JSON file with DCR ingestion settings:
        { DceEndpoint, DcrImmutableId, FindingsStream, EntitiesStream, DryRun }.
    .PARAMETER BaselineMode
        Controls auto-baseline discovery for the delta banner. Values:
          auto  — (default) pick the most recent snapshot from $OutputPath\snapshots\ automatically.
          none  — suppress baseline comparison entirely.
        The explicit -PreviousRun parameter always wins over -BaselineMode when both are supplied.
    .PARAMETER CompareTo
        Path to a previous run output directory containing entities.json.
        When provided, the orchestrator writes drift-report.json and drift-report.md
        by comparing that snapshot to the current run entities.json.
    .PARAMETER CompareToPrevious
        Auto-discovers the latest prior sibling run directory under the current output root
        and uses it as the drift baseline for entities.json comparison.
    .PARAMETER NoBanner
        Suppresses the ASCII startup banner. The banner is also suppressed when
        the AZUREANALYZER_NO_BANNER environment variable is set. Color codes in
        the banner are skipped when NO_COLOR is set (per https://no-color.org/).
    .EXAMPLE
        .\Invoke-AzureAnalyzer.ps1 -SubscriptionId "00000000-0000-0000-0000-000000000000"
        .\Invoke-AzureAnalyzer.ps1 -SubscriptionId "..." -ManagementGroupId "my-mg"
        .\Invoke-AzureAnalyzer.ps1 -SubscriptionId "..." -Repository "github.com/org/repo"
        .\Invoke-AzureAnalyzer.ps1 -Repository "github.contoso.com/org/repo" -GitHubHost "github.contoso.com"
        .\Invoke-AzureAnalyzer.ps1 -AdoOrg "contoso" -AdoProject "my-project"
        .\Invoke-AzureAnalyzer.ps1 -RepoPath "C:\repos\my-app"
        .\Invoke-AzureAnalyzer.ps1 -SubscriptionId "..." -SentinelWorkspaceId "/subscriptions/.../resourceGroups/.../providers/Microsoft.OperationalInsights/workspaces/..."
    #>
    [CmdletBinding()]
    param (
        [Parameter(ParameterSetName='Help')]
        [switch]$Help,
        [string] $SubscriptionId,
        [string] $ManagementGroupId,
        [string] $TenantId,
        [string] $OutputPath = (Join-Path $PSScriptRoot 'output'),
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
        [ValidateSet('CIS','NIST','PCI')]
        [string] $Framework,
        [string] $PreviousRun,
        [string] $CompareTo,
        [switch] $CompareToPrevious,
        [switch] $Incremental,
        [Nullable[datetime]] $Since,
        [ValidateSet('auto','none')]
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

