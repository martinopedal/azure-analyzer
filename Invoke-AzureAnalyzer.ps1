#Requires -Version 7.4
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
.PARAMETER AlzReferenceMode
    Controls ALZ reference matching mode for policy recommendations:
    Auto (default), Force, or Off.
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

if ($Help) {
    Get-Help -Name $PSCommandPath -Full
    return
}

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Dot-source shared modules
# ---------------------------------------------------------------------------
$sharedDir = Join-Path $PSScriptRoot 'modules' 'shared'
foreach ($sharedModule in @('Sanitize', 'Mask', 'Schema', 'Canonicalize', 'EntityStore', 'WorkerPool', 'Checkpoint', 'Installer', 'Errors', 'MissingTool', 'RemoteClone', 'FrameworkMapper', 'Retry', 'RunHistory', 'ReportDelta', 'Compare-EntitySnapshots', 'ScanState', 'MultiTenantOrchestrator', 'ReportManifest', 'PromptForMandatoryParams', 'Banner')) {
    $sharedPath = Join-Path $sharedDir "$sharedModule.ps1"
    if (Test-Path $sharedPath) { . $sharedPath }
}
$preflightPath = Join-Path $sharedDir 'Preflight' 'Get-RequiredInputs.ps1'
if (Test-Path $preflightPath) { . $preflightPath }
if (-not (Get-Command Remove-Credentials -ErrorAction SilentlyContinue)) {
    function Remove-Credentials { param ([string]$Text) return $Text }
}
if (-not (Get-Command Invoke-WithRetry -ErrorAction SilentlyContinue)) {
    function Invoke-WithRetry { param([scriptblock]$ScriptBlock) & $ScriptBlock }
}

# Startup banner (cosmetic). Suppressed by -NoBanner or
# $env:AZUREANALYZER_NO_BANNER, and respects $env:NO_COLOR. Must run before
# any other Write-Host output so it appears at the top of the console run.
if (Get-Command Write-AzureAnalyzerBanner -ErrorAction SilentlyContinue) {
    Write-AzureAnalyzerBanner -NoBanner:$NoBanner
}

# ---------------------------------------------------------------------------
# Multi-tenant fan-out (#163): when -TenantConfig or -Tenants is supplied,
# delegate to Invoke-MultiTenantScan and exit. This branch must run BEFORE
# any single-tenant validation that would reject the absence of
# -SubscriptionId / -ManagementGroupId / -TenantId, because those are
# supplied per-tenant by the fan-out layer.
# ---------------------------------------------------------------------------
if ($TenantConfig -or ($Tenants -and $Tenants.Count -gt 0)) {
    if ($TenantConfig -and $Tenants -and $Tenants.Count -gt 0) {
        throw (Format-FindingErrorMessage (New-FindingError -Source 'orchestrator' `
            -Category 'InvalidParameter' `
            -Reason '-TenantConfig and -Tenants are mutually exclusive.' `
            -Remediation 'Pass either -TenantConfig <path-to-json> or -Tenants <list>, not both.'))
    }
    foreach ($conflict in 'TenantId','SubscriptionId','ManagementGroupId') {
        if ($PSBoundParameters.ContainsKey($conflict)) {
            throw (Format-FindingErrorMessage (New-FindingError -Source 'orchestrator' `
                -Category 'InvalidParameter' `
                -Reason "-$conflict cannot be combined with -TenantConfig/-Tenants in v1." `
                -Remediation 'Per-tenant scope is supplied by the fan-out config; remove the conflicting parameter.'))
        }
    }
    if (-not (Get-Command Invoke-MultiTenantScan -ErrorAction SilentlyContinue)) {
        throw (Format-FindingErrorMessage (New-FindingError -Source 'orchestrator' `
            -Category 'MissingDependency' `
            -Reason 'MultiTenantOrchestrator module failed to load; cannot fan out.' `
            -Remediation 'Verify modules/shared/MultiTenantOrchestrator.ps1 exists and re-import AzureAnalyzer.'))
    }
    $tenantList = if ($TenantConfig) {
        ConvertFrom-TenantConfig -Path $TenantConfig
    } else {
        ConvertFrom-TenantConfig -TenantList $Tenants
    }
    $summary = Invoke-MultiTenantScan -Tenants $tenantList -OutputPath $OutputPath `
        -ScriptPath $PSCommandPath -ForwardParams $PSBoundParameters
    $failed = @($summary.Tenants | Where-Object { $_.Status -ne 'success' }).Count
    if ($failed -gt 0) {
        Write-Warning "Multi-tenant scan completed with $failed failed tenant(s) of $($summary.Tenants.Count). See $OutputPath\multi-tenant-summary.json"
        exit 1
    }
    Write-Host "Multi-tenant scan complete: $($summary.Tenants.Count) tenant(s). Summary: $OutputPath\multi-tenant-summary.json" -ForegroundColor Green
    exit 0
}

$sinkModulePath = Join-Path $PSScriptRoot 'modules' 'sinks' 'Send-FindingsToLogAnalytics.ps1'
if (Test-Path $sinkModulePath) { . $sinkModulePath }

# ---------------------------------------------------------------------------
# Read tool manifest
# ---------------------------------------------------------------------------
$manifest = Get-Content (Join-Path $PSScriptRoot 'tools' 'tool-manifest.json') -Raw | ConvertFrom-Json

# ---------------------------------------------------------------------------
# Incremental defaults (#94): auto-resolve baseline when -Incremental is set.
# An explicit -PreviousRun always wins; -Since alone does not auto-rebase.
# When -Incremental is requested but no baseline exists, this is the first
# bootstrap run: we must fall through to Full semantics so this run SEEDS the
# baseline + state. Otherwise subsequent -Incremental runs would keep running
# against an empty state and never produce a baseline (#94 R1 Goldeneye).
# ---------------------------------------------------------------------------
$bootstrapRun = $false
if ($Incremental -and -not $PreviousRun) {
    $autoBaseline = Join-Path $OutputPath 'results-baseline.json'
    if (Test-Path $autoBaseline) {
        $PreviousRun = $autoBaseline
        Write-Host "[incremental] Using baseline $autoBaseline for delta comparison." -ForegroundColor DarkCyan
    } else {
        $bootstrapRun = $true
        Write-Host "[incremental] No baseline found at $autoBaseline; bootstrapping a full run to seed the baseline." -ForegroundColor DarkYellow
    }
}

# ---------------------------------------------------------------------------
# Load scan-state BEFORE tool dispatch so Resolve-IncrementalSince can
# inform the per-tool -Since hint passed into wrappers (#94 R1 Goldeneye).
# ---------------------------------------------------------------------------
$scanStatePreRun = $null
$incrementalSinceMap = @{}
try {
    $scanStateModulePath = Join-Path $PSScriptRoot 'modules' 'shared' 'ScanState.ps1'
    if (Test-Path $scanStateModulePath) {
        if (-not (Get-Command Read-ScanState -ErrorAction SilentlyContinue)) { . $scanStateModulePath }
        $scanStatePreRun = Read-ScanState -OutputPath $OutputPath
        $passIncremental = ($Incremental -and -not $bootstrapRun)
        foreach ($toolDef in $manifest.tools) {
            if (-not $toolDef.enabled) { continue }
            $resolved = Resolve-IncrementalSince -State $scanStatePreRun -Tool $toolDef.name `
                -Incremental:$passIncremental -Override $Since
            if ($null -ne $resolved) {
                $incrementalSinceMap[$toolDef.name] = [datetime]$resolved
            }
        }
    }
} catch {
    Write-Warning (Remove-Credentials "Failed to preload scan-state: $_")
}

# ---------------------------------------------------------------------------
# Tool selection (manifest-driven)
# ---------------------------------------------------------------------------
$validTools = @($manifest.tools | ForEach-Object { $_.name })
$azureScopedTools = @($manifest.tools | Where-Object { $_.provider -eq 'azure' } | ForEach-Object { $_.name })

if ($IncludeTools -and $ExcludeTools) {
    throw (Format-FindingErrorMessage (New-FindingError -Source 'orchestrator' `
        -Category 'InvalidParameter' `
        -Reason 'Cannot use both -IncludeTools and -ExcludeTools.' `
        -Remediation 'Pass one or the other.'))
}
foreach ($t in @($IncludeTools) + @($ExcludeTools) | Where-Object { $_ }) {
    if ($t -notin $validTools) {
        throw (Format-FindingErrorMessage (New-FindingError -Source 'orchestrator' `
            -Category 'InvalidParameter' `
            -Reason "Unknown tool '$t'." `
            -Remediation "Valid tools: $($validTools -join ', ')."))
    }
}

function ShouldRunTool { param ([string]$ToolName)
    if ($IncludeTools) { return $ToolName -in $IncludeTools }
    if ($ExcludeTools) { return $ToolName -notin $ExcludeTools }
    return $true
}

# Signal to wrappers that they were launched via the orchestrator. Used by
# Write-MissingToolNotice (modules\shared\MissingTool.ps1) to decide whether
# a missing-tool message should be a loud warning (explicitly requested) or
# a quiet verbose note (default scan, tool not asked for). Issue #472.
$script:PriorOrchestratedFlag    = $env:AZURE_ANALYZER_ORCHESTRATED
$script:PriorExplicitToolsFlag   = $env:AZURE_ANALYZER_EXPLICIT_TOOLS
$env:AZURE_ANALYZER_ORCHESTRATED   = '1'
$env:AZURE_ANALYZER_EXPLICIT_TOOLS = if ($IncludeTools) { ($IncludeTools -join ',') } else { '' }

# ---------------------------------------------------------------------------
# Mandatory scanner-param prompts (#426): for the headline params common to
# all scanners (subscription, tenant, GitHub org/repo, ADO org), prompt the
# user when interactive, fall back to env vars otherwise. Per-tool, deeper
# requirements are still resolved by Get-RequiredInputs below.
# ---------------------------------------------------------------------------
if ((Get-Command Read-MandatoryScannerParam -ErrorAction SilentlyContinue) -and -not $NonInteractive) {
    $selectedToolsForPrompt = @($manifest.tools | Where-Object { $_.enabled -and (ShouldRunTool $_.name) })
    $providers = @($selectedToolsForPrompt | ForEach-Object { $_.provider } | Where-Object { $_ } | Sort-Object -Unique)
    $scopes    = @($selectedToolsForPrompt | ForEach-Object { $_.scope    } | Where-Object { $_ } | Sort-Object -Unique)

    if (('azure' -in $providers) -and -not $SubscriptionId -and -not $ManagementGroupId) {
        $v = Read-MandatoryScannerParam -ScannerName 'azure-scanners' -ParamName 'SubscriptionId' -EnvVarFallback 'AZURE_SUBSCRIPTION_ID' -Example '00000000-0000-0000-0000-000000000000'
        if ($v) { $SubscriptionId = $v; $PSBoundParameters['SubscriptionId'] = $v }
    }
    if (('azure' -in $providers) -and -not $TenantId) {
        $v = Read-MandatoryScannerParam -ScannerName 'azure-scanners' -ParamName 'TenantId' -EnvVarFallback 'AZURE_TENANT_ID' -Example '00000000-0000-0000-0000-000000000000'
        if ($v) { $TenantId = $v; $PSBoundParameters['TenantId'] = $v }
    }
    if (('ado' -in $providers) -and -not $AdoOrg) {
        $v = Read-MandatoryScannerParam -ScannerName 'ado-scanners' -ParamName 'AdoOrg' -EnvVarFallback 'ADO_ORG' -Example 'contoso'
        if ($v) { $AdoOrg = $v; $PSBoundParameters['AdoOrg'] = $v }
    }
    if (('github' -in $providers) -and -not $Repository) {
        $v = Read-MandatoryScannerParam -ScannerName 'github-scanners' -ParamName 'Repository' -EnvVarFallback 'GITHUB_REPOSITORY' -Example 'github.com/org/repo'
        if ($v) { $Repository = $v; $PSBoundParameters['Repository'] = $v }
    }
    if (('repository' -in $scopes) -and -not $RepoPath -and -not $Repository) {
        $v = Read-MandatoryScannerParam -ScannerName 'repo-scanners' -ParamName 'RepoPath' -EnvVarFallback 'AZUREANALYZER_REPO_PATH' -Example 'C:\repos\my-app'
        if ($v) { $RepoPath = $v; $PSBoundParameters['RepoPath'] = $v }
    }
}

if (Get-Command Get-RequiredInputs -ErrorAction SilentlyContinue) {
    $selectedTools = @($manifest.tools | Where-Object { $_.enabled -and (ShouldRunTool $_.name) })
    $declaredParamNames = @($MyInvocation.MyCommand.Parameters.Keys)
    $cliValues = @{}
    foreach ($name in $PSBoundParameters.Keys) {
        $cliValues[$name] = $PSBoundParameters[$name]
    }
    try {
        $resolvedRequiredInputs = Get-RequiredInputs -Tools $selectedTools -CliValues $cliValues -NonInteractive:$NonInteractive
        foreach ($name in $resolvedRequiredInputs.Keys) {
            if ($name -notin $declaredParamNames) { continue }
            # Keep both variable state and bound-parameter state in sync:
            # - script vars are read directly throughout orchestration flow
            # - PSBoundParameters is used by ContainsKey guards for optional forwarding
            Set-Variable -Name $name -Value $resolvedRequiredInputs[$name] -Scope Script
            $PSBoundParameters[$name] = $resolvedRequiredInputs[$name]
        }
    } catch {
        [Console]::Error.WriteLine((Remove-Credentials -Text $_.Exception.Message))
        exit 2
    }
}

# PSRule can run in path-mode without Azure scope; workspace-scoped tools
# (sentinel-incidents) only need -SentinelWorkspaceId, not a subscription.
$workspaceScopedTools = @($manifest.tools | Where-Object { $_.scope -eq 'workspace' } | ForEach-Object { $_.name })
$needsAzureScope = $azureScopedTools | Where-Object { ShouldRunTool $_ } | Where-Object { $_ -ne 'psrule' -and $_ -notin $workspaceScopedTools }
if ($needsAzureScope -and -not $SubscriptionId -and -not $ManagementGroupId) {
    throw (Format-FindingErrorMessage (New-FindingError -Source 'orchestrator' `
        -Category 'InvalidParameter' `
        -Reason "At least one of -SubscriptionId or -ManagementGroupId is required for: $($needsAzureScope -join ', ')." `
        -Remediation 'Pass -SubscriptionId <guid> or -ManagementGroupId <name>, or use -IncludeTools to scope to non-Azure tools only.'))
}
if ($SinkLogAnalytics -and [string]::IsNullOrWhiteSpace($LogAnalyticsConfig)) {
    throw (Format-FindingErrorMessage (New-FindingError -Source 'orchestrator' `
        -Category 'InvalidParameter' `
        -Reason '-LogAnalyticsConfig is required when -SinkLogAnalytics is enabled.' `
        -Remediation 'Pass -LogAnalyticsConfig <path-to-json> with WorkspaceId/DcrImmutableId/DceUri/StreamName.'))
}
if ($SinkLogAnalytics -and -not (Test-Path $LogAnalyticsConfig)) {
    throw (Format-FindingErrorMessage (New-FindingError -Source 'orchestrator' `
        -Category 'NotFound' `
        -Reason "Log Analytics config file not found: $LogAnalyticsConfig" `
        -Remediation 'Verify the -LogAnalyticsConfig path exists and is readable.'))
}

# ---------------------------------------------------------------------------
# Management group subscription discovery
# ---------------------------------------------------------------------------
function Invoke-SearchAzGraphAllResults {
    param (
        [Parameter(Mandatory)]
        [string] $Query,

        [string] $ManagementGroupId,

        [int] $PageSize = 1000
    )

    $allRows = [System.Collections.Generic.List[object]]::new()
    $skipToken = $null

    do {
        $pageResult = Invoke-WithRetry -ScriptBlock {
            $params = @{
                Query       = $Query
                First       = $PageSize
                ErrorAction = 'Stop'
            }
            if ($ManagementGroupId) { $params['ManagementGroup'] = $ManagementGroupId }
            if ($skipToken) { $params['SkipToken'] = $skipToken }
            Search-AzGraph @params
        }

        $pageRows = @()
        $nextToken = $null
        if ($pageResult -and $pageResult.PSObject.Properties['Data']) {
            $pageRows = @($pageResult.Data)
            if ($pageResult.PSObject.Properties['SkipToken']) {
                $nextToken = [string]$pageResult.SkipToken
            }
        } else {
            $pageRows = @($pageResult)
        }

        foreach ($row in $pageRows) {
            if ($row) { $allRows.Add($row) | Out-Null }
        }

        if ([string]::IsNullOrWhiteSpace($nextToken)) {
            $skipToken = $null
        } else {
            $skipToken = $nextToken
        }
    } while ($skipToken)

    return @($allRows)
}

function Get-ChildSubscriptions {
    param ([string]$ManagementGroupId)
    $query = "resourcecontainers | where type == 'microsoft.resources/subscriptions'"
    try {
        $subs = Invoke-SearchAzGraphAllResults -Query $query -ManagementGroupId $ManagementGroupId
        return @($subs | Select-Object -ExpandProperty subscriptionId -Unique)
    } catch {
        Write-Warning (Remove-Credentials "Failed to enumerate subscriptions under $ManagementGroupId : $_")
        return @()
    }
}

function Get-SubscriptionContextLookup {
    param (
        [string] $ManagementGroupId,
        [string[]] $SubscriptionIds
    )

    $lookup = @{}
    foreach ($subId in @($SubscriptionIds | Where-Object { $_ } | Select-Object -Unique)) {
        $lookup[$subId.ToLowerInvariant()] = [pscustomobject]@{
            SubscriptionId      = $subId
            SubscriptionName    = $subId
            ManagementGroupPath = @()
            IsInMgSubtree       = $false
        }
    }

    if (-not $ManagementGroupId) {
        return $lookup
    }

    $query = @"
resourcecontainers
| where type =~ 'microsoft.resources/subscriptions'
| project subscriptionId, subscriptionName = name, mgChain = properties.managementGroupAncestorsChain
"@

    try {
        $records = Invoke-SearchAzGraphAllResults -Query $query -ManagementGroupId $ManagementGroupId

        foreach ($record in @($records)) {
            $subId = [string]($record.subscriptionId ?? $record.SubscriptionId)
            if ([string]::IsNullOrWhiteSpace($subId)) { continue }

            $path = @()
            $mgChain = $null
            if ($record.PSObject.Properties['mgChain']) { $mgChain = $record.mgChain }
            elseif ($record.PSObject.Properties['ManagementGroupPath']) { $mgChain = $record.ManagementGroupPath }

            $orderedChain = @($mgChain)
            if (@($orderedChain).Count -gt 1) {
                [array]::Reverse($orderedChain)
            }

            foreach ($entry in @($orderedChain)) {
                if (-not $entry) { continue }
                if ($entry -is [string]) {
                    $path += $entry
                    continue
                }

                foreach ($candidateProp in @('displayName', 'name', 'id')) {
                    if ($entry.PSObject.Properties[$candidateProp] -and -not [string]::IsNullOrWhiteSpace([string]$entry.$candidateProp)) {
                        $value = [string]$entry.$candidateProp
                        if ($candidateProp -eq 'id' -and $value -match '/([^/]+)$') {
                            $value = $Matches[1]
                        }
                        $path += $value
                        break
                    }
                }
            }

            if ($path.Count -eq 0) {
                $path = @($ManagementGroupId)
            }

            $lookup[$subId.ToLowerInvariant()] = [pscustomobject]@{
                SubscriptionId      = $subId
                SubscriptionName    = if ($record.PSObject.Properties['subscriptionName'] -and $record.subscriptionName) { [string]$record.subscriptionName } elseif ($record.PSObject.Properties['name'] -and $record.name) { [string]$record.name } else { $subId }
                ManagementGroupPath = @($path)
                IsInMgSubtree       = $true
            }
        }
    } catch {
        Write-Warning (Remove-Credentials "Failed to resolve management-group context for $ManagementGroupId : $_")
    }

    return $lookup
}

function Get-DefaultSubscriptionId {
    param ([string] $ToolSpecName)
    if ([string]::IsNullOrWhiteSpace($ToolSpecName)) { return $null }
    $parts = $ToolSpecName -split '\|'
    if ($parts.Count -eq 2 -and $parts[1] -match '^[0-9a-f-]{36}$') {
        return $parts[1].ToLowerInvariant()
    }
    return $null
}

function Update-FindingScopeContext {
    param (
        [pscustomobject] $Finding,
        [hashtable] $SubscriptionContextLookup,
        [string] $DefaultSubscriptionId,
        [string] $ManagementGroupId
    )

    if (-not $Finding) { return $null }

    $subscriptionId = if ($Finding.PSObject.Properties['SubscriptionId']) { [string]$Finding.SubscriptionId } else { '' }
    if ([string]::IsNullOrWhiteSpace($subscriptionId) -and -not [string]::IsNullOrWhiteSpace($DefaultSubscriptionId)) {
        $subscriptionId = $DefaultSubscriptionId
    }
    if ([string]::IsNullOrWhiteSpace($subscriptionId)) {
        foreach ($textProp in @('ResourceId', 'EntityId', 'Detail')) {
            if (-not $Finding.PSObject.Properties[$textProp]) { continue }
            $textValue = [string]$Finding.$textProp
            if ($textValue -match '(?i)/subscriptions/([0-9a-f-]{36})') {
                $subscriptionId = $Matches[1].ToLowerInvariant()
                break
            }
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($subscriptionId)) {
        $Finding.SubscriptionId = $subscriptionId
        $ctx = $SubscriptionContextLookup[$subscriptionId.ToLowerInvariant()]
        if ($ctx) {
            $currentSubscriptionName = if ($Finding.PSObject.Properties['SubscriptionName']) { [string]$Finding.SubscriptionName } else { '' }
            if ([string]::IsNullOrWhiteSpace($currentSubscriptionName) -or $currentSubscriptionName -eq $subscriptionId) {
                $Finding | Add-Member -NotePropertyName SubscriptionName -NotePropertyValue $ctx.SubscriptionName -Force
            }

            $existingPath = @()
            if ($Finding.PSObject.Properties['ManagementGroupPath'] -and $Finding.ManagementGroupPath) {
                $existingPath = @($Finding.ManagementGroupPath | Where-Object { $_ })
            }
            $isConfirmedMgContext = $false
            if (-not $ManagementGroupId) {
                $isConfirmedMgContext = $true
            } elseif ($ctx.PSObject.Properties['IsInMgSubtree']) {
                $isConfirmedMgContext = [bool]$ctx.IsInMgSubtree
            }

            if ($existingPath.Count -eq 0 -and $isConfirmedMgContext -and @($ctx.ManagementGroupPath).Count -gt 0) {
                $Finding | Add-Member -NotePropertyName ManagementGroupPath -NotePropertyValue @($ctx.ManagementGroupPath) -Force
            }
        }
    } elseif ($ManagementGroupId) {
        $existingPath = @()
        if ($Finding.PSObject.Properties['ManagementGroupPath'] -and $Finding.ManagementGroupPath) {
            $existingPath = @($Finding.ManagementGroupPath | Where-Object { $_ })
        }
        if ($existingPath.Count -eq 0) {
            $Finding | Add-Member -NotePropertyName ManagementGroupPath -NotePropertyValue @($ManagementGroupId) -Force
        }
    }

    return $Finding
}

$subscriptionsToScan = [System.Collections.Generic.List[string]]::new()
if ($SubscriptionId) { $subscriptionsToScan.Add($SubscriptionId) }

$shouldRecurse = $ManagementGroupId -and (-not $PSBoundParameters.ContainsKey('Recurse') -or $Recurse)
if ($shouldRecurse) {
    $childSubs = Get-ChildSubscriptions -ManagementGroupId $ManagementGroupId
    foreach ($cs in $childSubs) {
        if ($cs -notin $subscriptionsToScan) { $subscriptionsToScan.Add($cs) }
    }
    Write-Host "Discovered $($subscriptionsToScan.Count) subscription(s) under management group '$ManagementGroupId'" -ForegroundColor Cyan
} elseif ($ManagementGroupId -and -not $shouldRecurse) {
    Write-Host "Management group '$ManagementGroupId' provided without -Recurse; subscription-scoped tools will only scan explicitly provided subscriptions" -ForegroundColor DarkGray
}
$subscriptionContextLookup = Get-SubscriptionContextLookup -ManagementGroupId $ManagementGroupId -SubscriptionIds @($subscriptionsToScan)

# ---------------------------------------------------------------------------
# Prerequisite check (manifest-driven auto-installer)
# ---------------------------------------------------------------------------
$installConfig = Read-InstallConfig -Path $InstallConfigPath -Manifest $manifest

# defaults.autoInstall from config enables auto-install when the CLI flag
# was not explicitly passed (CLI > config > off).
$effectiveInstallMissing = $InstallMissingModules
if (-not $PSBoundParameters.ContainsKey('InstallMissingModules') -and
    $null -ne $installConfig -and
    $installConfig.PSObject.Properties['defaults'] -and
    $null -ne $installConfig.defaults -and
    $installConfig.defaults.PSObject.Properties['autoInstall'] -and
    $installConfig.defaults.autoInstall -eq $true) {
    $effectiveInstallMissing = $true
    Write-Verbose "[install-config] defaults.autoInstall=true; enabling auto-install."
}

if (-not $SkipPrereqCheck) {
    # Closure captures $IncludeTools/$ExcludeTools by value so the predicate
    # works even when invoked from another module's session state (e.g. when
    # Invoke-AzureAnalyzer is called via the AzureAnalyzer.psm1 wrapper, where
    # the script-level ShouldRunTool function would not be visible to a
    # scriptblock dispatched from inside Install-PrerequisitesFromManifest).
    $includeToolsLocal = $IncludeTools
    $excludeToolsLocal = $ExcludeTools
    $shouldRunRef = {
        param($name)
        if ($includeToolsLocal) { return $name -in $includeToolsLocal }
        if ($excludeToolsLocal) { return $name -notin $excludeToolsLocal }
        return $true
    }.GetNewClosure()
    $null = Install-PrerequisitesFromManifest `
        -Manifest $manifest `
        -RepoRoot $PSScriptRoot `
        -ShouldRunTool $shouldRunRef `
        -SkipInstall:(-not $effectiveInstallMissing) `
        -InstallConfig $installConfig `
        -CliIncludedTools $IncludeTools
}

# ---------------------------------------------------------------------------
# Dot-source normalizers
# ---------------------------------------------------------------------------
$normalizersDir = Join-Path $PSScriptRoot 'modules' 'normalizers'
foreach ($toolDef in $manifest.tools) {
    if (-not $toolDef.normalizer) { continue }
    $normPath = Join-Path $normalizersDir "$($toolDef.normalizer).ps1"
    if (Test-Path $normPath) { . $normPath }
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
$modulesPath = Join-Path $PSScriptRoot 'modules'
$toolErrors  = [System.Collections.Generic.List[PSCustomObject]]::new()
$toolStatus  = [System.Collections.Generic.List[PSCustomObject]]::new()

function Map-Severity {
    param ([string]$Raw)
    if ([string]::IsNullOrEmpty($Raw)) { return 'Info' }
    switch -Regex ($Raw.ToLowerInvariant()) {
        'critical'        { return 'Critical' }
        'high'            { return 'High' }
        'medium|moderate' { return 'Medium' }
        'low'             { return 'Low' }
        default           { return 'Info' }
    }
}

function Get-SeverityRank ([string]$Sev) {
    switch ($Sev) { 'Critical' { 4 } 'High' { 3 } 'Medium' { 2 } 'Low' { 1 } default { 0 } }
}

# ---------------------------------------------------------------------------
# Build ToolSpecs from manifest
# ---------------------------------------------------------------------------
if (-not $env:AZURE_ANALYZER_NO_BANNER -and -not ($env:CI -eq 'true' -or $env:GITHUB_ACTIONS -eq 'true')) {
    Write-Host "=== Azure Analyzer ===" -ForegroundColor Cyan
}

# ScriptBlock used by every ToolSpec — self-contained, runs in parallel runspace
$runnerBlock = {
    param ([string]$ScriptPath, [hashtable]$ToolParams)
    if (-not (Test-Path $ScriptPath)) {
        return [PSCustomObject]@{
            Source   = [System.IO.Path]::GetFileNameWithoutExtension($ScriptPath)
            Status   = 'Failed'
            Message  = "Script not found: $ScriptPath"
            Findings = @()
        }
    }
    $sanitizePath = Join-Path ([System.IO.Path]::GetDirectoryName($ScriptPath)) 'shared' 'Sanitize.ps1'
    if (Test-Path $sanitizePath) { . $sanitizePath }
    if (-not (Get-Command Remove-Credentials -ErrorAction SilentlyContinue)) {
        function Remove-Credentials { param ([string]$Text) return $Text }
    }
    try {
        $result = & $ScriptPath @ToolParams
        return $result
    } catch {
        return [PSCustomObject]@{
            Source   = [System.IO.Path]::GetFileNameWithoutExtension($ScriptPath)
            Status   = 'Failed'
            Message  = (Remove-Credentials $_.Exception.Message)
            Findings = @()
        }
    }
}

$toolSpecs   = [System.Collections.Generic.List[PSCustomObject]]::new()
$toolMetaMap = @{}   # spec-name → manifest tool object

foreach ($toolDef in $manifest.tools) {
    if (-not $toolDef.enabled) { continue }
    if (-not (ShouldRunTool $toolDef.name)) {
        $toolStatus.Add([PSCustomObject]@{ Tool = $toolDef.name; Status = 'Excluded'; Message = 'Excluded by user'; Findings = 0 })
        continue
    }

    # Check install config for enabled=false override (skips scan as well as install),
    # but CLI -IncludeTools takes precedence (CLI > config > manifest).
    $cliExplicitInclude = $IncludeTools -and ($toolDef.name -in $IncludeTools)
    if (-not $cliExplicitInclude -and
        $null -ne $installConfig -and
        $installConfig.PSObject.Properties['tools'] -and
        $null -ne $installConfig.tools -and
        $installConfig.tools.PSObject.Properties[$toolDef.name]) {
        $cfgEntry = $installConfig.tools.($toolDef.name)
        if ($cfgEntry.PSObject.Properties['enabled'] -and $cfgEntry.enabled -eq $false) {
            $toolStatus.Add([PSCustomObject]@{ Tool = $toolDef.name; Status = 'Skipped'; Message = 'Disabled by install config'; Findings = 0 })
            continue
        }
    }

    # Correlators run post-collection, not in the parallel tool loop
    if ($toolDef.type -eq 'correlator') { continue }

    $scriptPath = Join-Path $PSScriptRoot $toolDef.script

    switch ($toolDef.scope) {
        'subscription' {
            if ($subscriptionsToScan.Count -eq 0) {
                $toolStatus.Add([PSCustomObject]@{ Tool = $toolDef.name; Status = 'Skipped'; Message = 'No subscriptions to scan'; Findings = 0 })
                continue
            }
            foreach ($subId in $subscriptionsToScan) {
                $params = @{ SubscriptionId = $subId }
                # Tool-specific optional params
                if ($toolDef.name -eq 'wara') {
                    if ($TenantId) { $params['TenantId'] = $TenantId }
                    $params['OutputPath'] = Join-Path $OutputPath "wara-$subId"
                }
                if ($toolDef.name -eq 'azqr') {
                    $params['OutputPath'] = Join-Path $OutputPath "azqr-$subId"
                }
                if ($toolDef.name -eq 'finops') {
                    $params['OutputPath'] = Join-Path $OutputPath "finops-$subId"
                }
                # Inline helper: append KubeAuthMode + sub-params to a wrapper
                # param hashtable ONLY when the user explicitly bound them.
                # Backward compat: leaving the hashtable untouched preserves
                # the wrapper default (KubeAuthMode='Default').
                $kubeAuthForward = @(
                    'KubeAuthMode',
                    'KubeloginServerId', 'KubeloginClientId', 'KubeloginTenantId',
                    'WorkloadIdentityClientId', 'WorkloadIdentityTenantId',
                    'WorkloadIdentityServiceAccountToken'
                )
                if ($toolDef.name -eq 'falco') {
                    if ($InstallFalco)  { $params['InstallFalco'] = $true }
                    if ($UninstallFalco) { $params['UninstallFalco'] = $true }
                    $params['CaptureMinutes'] = $FalcoCaptureMinutes
                    if ($PSBoundParameters.ContainsKey('KubeconfigPath')) { $params['KubeconfigPath'] = $KubeconfigPath }
                    if ($PSBoundParameters.ContainsKey('KubeContext'))    { $params['KubeContext']    = $KubeContext }
                    if ($PSBoundParameters.ContainsKey('FalcoNamespace')) { $params['Namespace']      = $FalcoNamespace }
                    foreach ($k in $kubeAuthForward) {
                        if ($PSBoundParameters.ContainsKey($k)) { $params[$k] = (Get-Variable -Name $k -ValueOnly) }
                    }
                }
                if ($toolDef.name -eq 'kubescape') {
                    if ($PSBoundParameters.ContainsKey('KubeconfigPath'))      { $params['KubeconfigPath'] = $KubeconfigPath }
                    if ($PSBoundParameters.ContainsKey('KubeContext'))         { $params['KubeContext']    = $KubeContext }
                    if ($PSBoundParameters.ContainsKey('KubescapeNamespace'))  { $params['Namespace']      = $KubescapeNamespace }
                    foreach ($k in $kubeAuthForward) {
                        if ($PSBoundParameters.ContainsKey($k)) { $params[$k] = (Get-Variable -Name $k -ValueOnly) }
                    }
                }
                if ($toolDef.name -eq 'kube-bench') {
                    if ($PSBoundParameters.ContainsKey('KubeconfigPath'))     { $params['KubeconfigPath'] = $KubeconfigPath }
                    if ($PSBoundParameters.ContainsKey('KubeContext'))        { $params['KubeContext']    = $KubeContext }
                    if ($PSBoundParameters.ContainsKey('KubeBenchNamespace')) { $params['Namespace']      = $KubeBenchNamespace }
                    foreach ($k in $kubeAuthForward) {
                        if ($PSBoundParameters.ContainsKey($k)) { $params[$k] = (Get-Variable -Name $k -ValueOnly) }
                    }
                }
                $specName = "$($toolDef.name)|$subId"
                $toolSpecs.Add([PSCustomObject]@{
                    Name        = $specName
                    Provider    = $toolDef.provider
                    Scope       = $toolDef.scope
                    ScriptBlock = $runnerBlock
                    Arguments   = @{ ScriptPath = $scriptPath; ToolParams = $params }
                })
                $toolMetaMap[$specName] = $toolDef
            }
        }
        'managementGroup' {
            # alz-queries: also runnable with just SubscriptionId
            if (-not $ManagementGroupId -and $toolDef.name -ne 'alz-queries') {
                $toolStatus.Add([PSCustomObject]@{ Tool = $toolDef.name; Status = 'Skipped'; Message = 'No ManagementGroupId provided'; Findings = 0 })
                continue
            }
            if (-not $ManagementGroupId -and -not $SubscriptionId) {
                $toolStatus.Add([PSCustomObject]@{ Tool = $toolDef.name; Status = 'Skipped'; Message = 'No scope provided'; Findings = 0 })
                continue
            }
            $params = if ($ManagementGroupId) {
                @{ ManagementGroupId = $ManagementGroupId }
            } else {
                @{ SubscriptionId = $SubscriptionId }
            }
            $specName = "$($toolDef.name)|mg"
            $toolSpecs.Add([PSCustomObject]@{
                Name        = $specName
                Provider    = $toolDef.provider
                Scope       = $toolDef.scope
                ScriptBlock = $runnerBlock
                Arguments   = @{ ScriptPath = $scriptPath; ToolParams = $params }
            })
            $toolMetaMap[$specName] = $toolDef
        }
        'tenant' {
            $providerKey = if ($toolDef.provider -eq 'microsoft365') { 'Graph' } else { $toolDef.provider }
            $specName = "$($toolDef.name)|tenant"
            $toolSpecs.Add([PSCustomObject]@{
                Name        = $specName
                Provider    = $providerKey
                Scope       = $toolDef.scope
                ScriptBlock = $runnerBlock
                Arguments   = @{ ScriptPath = $scriptPath; ToolParams = @{} }
            })
            $toolMetaMap[$specName] = $toolDef
        }
        'repository' {
            # CLI-provider tools (trivy, zizmor, gitleaks): remote-first, local fallback.
            if ($toolDef.provider -eq 'cli') {
                $params = @{}
                $scanTargetUrl = $null
                if (Get-Command Resolve-ScanTargetUrl -ErrorAction SilentlyContinue) {
                    $resolveArgs = @{}
                    if ($AdoRepoUrl) { $resolveArgs['AdoRepoUrl'] = $AdoRepoUrl }
                    if ($Repository) { $resolveArgs['Repository'] = $Repository }
                    if ($GitHubHost) { $resolveArgs['GitHubHost'] = $GitHubHost }
                    $scanTargetUrl = Resolve-ScanTargetUrl @resolveArgs
                }
                if ($scanTargetUrl) {
                    $params['RemoteUrl'] = $scanTargetUrl
                }
                if ($toolDef.name -eq 'trivy') {
                    if (-not $scanTargetUrl) {
                        $localPath = if ($ScanPath) { $ScanPath } elseif ($RepoPath) { $RepoPath } else { $null }
                        if ($localPath) { $params['RepoPath'] = $localPath }
                    }
                    if (-not $scanTargetUrl -and $ScanType) { $params['ScanType'] = $ScanType }
                }
                if ($toolDef.name -eq 'zizmor') {
                    if (-not $scanTargetUrl) {
                        $localPath = if ($RepoPath) { $RepoPath } else { '.' }
                        $params['RepoPath'] = $localPath
                    }
                    if ($incrementalSinceMap.ContainsKey('zizmor')) {
                        $params['Since'] = $incrementalSinceMap['zizmor']
                    }
                }
                if ($toolDef.name -eq 'gitleaks') {
                    if (-not $scanTargetUrl -and $RepoPath) { $params['RepoPath'] = $RepoPath }
                    if ($GitleaksConfigPath) { $params['GitleaksConfigPath'] = $GitleaksConfigPath }
                }
                if ($toolDef.name -eq 'infracost') {
                    if (-not $scanTargetUrl -and $RepoPath) { $params['RepoPath'] = $RepoPath }
                }
                $specName = "$($toolDef.name)|repo"
                $toolSpecs.Add([PSCustomObject]@{
                    Name        = $specName
                    Provider    = $toolDef.provider
                    Scope       = $toolDef.scope
                    ScriptBlock = $runnerBlock
                    Arguments   = @{ ScriptPath = $scriptPath; ToolParams = $params }
                })
                $toolMetaMap[$specName] = $toolDef
                continue
            }
            # GitHub-provider tools (scorecard) require -Repository
            if (-not $Repository) {
                $toolStatus.Add([PSCustomObject]@{ Tool = $toolDef.name; Status = 'Skipped'; Message = 'No -Repository provided'; Findings = 0 })
                continue
            }
            $params = @{ Repository = $Repository }
            if ($toolDef.name -eq 'scorecard') {
                $params['Threshold'] = $ScorecardThreshold
                if ($GitHubHost) { $params['GitHubHost'] = $GitHubHost }
            }
            $specName = "$($toolDef.name)|repo"
            $toolSpecs.Add([PSCustomObject]@{
                Name        = $specName
                Provider    = $toolDef.provider
                Scope       = $toolDef.scope
                ScriptBlock = $runnerBlock
                Arguments   = @{ ScriptPath = $scriptPath; ToolParams = $params }
            })
            $toolMetaMap[$specName] = $toolDef
        }
        'ado' {
            if (-not $AdoOrg) {
                $toolStatus.Add([PSCustomObject]@{ Tool = $toolDef.name; Status = 'Skipped'; Message = 'No -AdoOrg provided'; Findings = 0 })
                continue
            }
            $params = @{ AdoOrg = $AdoOrg }
            if ($AdoProject) { $params['AdoProject'] = $AdoProject }
            if ($AdoPat) { $params['AdoPat'] = $AdoPat }
            if ($AdoOrganizationUrl -and $toolDef.optionalParams -contains 'AdoOrganizationUrl') { $params['AdoOrganizationUrl'] = $AdoOrganizationUrl }
            if ($AdoServerUrl -and $toolDef.optionalParams -contains 'AdoServerUrl') { $params['AdoServerUrl'] = $AdoServerUrl }
            if ($toolDef.name -eq 'ado-repos-secrets') {
                $params['OutputPath'] = Join-Path $OutputPath 'ado-repos-secrets-findings.json'
                if ($GitleaksConfigPath) { $params['GitleaksConfigPath'] = $GitleaksConfigPath }
            }
            $specName = "$($toolDef.name)|ado"
            $toolSpecs.Add([PSCustomObject]@{
                Name        = $specName
                Provider    = $toolDef.provider
                Scope       = $toolDef.scope
                ScriptBlock = $runnerBlock
                Arguments   = @{ ScriptPath = $scriptPath; ToolParams = $params }
            })
            $toolMetaMap[$specName] = $toolDef
        }
        'workspace' {
            if (-not $SentinelWorkspaceId) {
                $toolStatus.Add([PSCustomObject]@{ Tool = $toolDef.name; Status = 'Skipped'; Message = 'No -SentinelWorkspaceId provided'; Findings = 0 })
                continue
            }
            $params = @{ WorkspaceResourceId = $SentinelWorkspaceId; LookbackDays = $SentinelLookbackDays }
            $specName = "$($toolDef.name)|workspace"
            $toolSpecs.Add([PSCustomObject]@{
                Name        = $specName
                Provider    = $toolDef.provider
                Scope       = $toolDef.scope
                ScriptBlock = $runnerBlock
                Arguments   = @{ ScriptPath = $scriptPath; ToolParams = $params }
            })
            $toolMetaMap[$specName] = $toolDef
        }
    }
}

# Also handle psrule fallback when no subscriptions but tool is included
$psruleDef = $manifest.tools | Where-Object { $_.name -eq 'psrule' } | Select-Object -First 1
if ($psruleDef -and $psruleDef.enabled -and (ShouldRunTool 'psrule') -and $subscriptionsToScan.Count -eq 0) {
    $psruleScript = Join-Path $PSScriptRoot $psruleDef.script
    $specName = 'psrule|path'
    $toolSpecs.Add([PSCustomObject]@{
        Name        = $specName
        Provider    = $psruleDef.provider
        Scope       = $psruleDef.scope
        ScriptBlock = $runnerBlock
        Arguments   = @{ ScriptPath = $psruleScript; ToolParams = @{ Path = '.' } }
    })
    $toolMetaMap[$specName] = $psruleDef
    # Remove the 'Skipped' status that was added for psrule
    $psruleSkipped = $toolStatus | Where-Object { $_.Tool -eq 'psrule' -and $_.Status -eq 'Skipped' }
    if ($psruleSkipped) {
        $toolStatus.Remove($psruleSkipped) | Out-Null
    }
}

# ---------------------------------------------------------------------------
# Execute tools in parallel
# ---------------------------------------------------------------------------
$parallelResults = @()
if ($toolSpecs.Count -gt 0) {
    $specCount = $toolSpecs.Count
    $toolNames = @($toolMetaMap.Values | ForEach-Object { $_.name } | Select-Object -Unique)
    Write-Host "`nRunning $specCount tool spec(s) across $($toolNames.Count) tool(s): $($toolNames -join ', ')" -ForegroundColor Yellow
    $parallelResults = Invoke-ParallelTools -ToolSpecs @($toolSpecs)
} else {
    Write-Host "`nNo tools to run." -ForegroundColor DarkGray
}

# ---------------------------------------------------------------------------
# Normalise results → v3 FindingRows → EntityStore
# ---------------------------------------------------------------------------
$store      = [EntityStore]::new(50000, $OutputPath)
$allResults = [System.Collections.Generic.List[PSCustomObject]]::new()
$normalizerEdgeCollector = [System.Collections.Generic.List[psobject]]::new()
# Per-tool aggregation for tool-status.json
$toolAgg = @{}   # toolName → @{ WorstStatus; Messages; Count }

foreach ($wr in $parallelResults) {
    $meta     = $toolMetaMap[$wr.Tool]
    $toolName = if ($meta) { $meta.name } else { $wr.Tool }
    $defaultSubscriptionId = Get-DefaultSubscriptionId -ToolSpecName $wr.Tool

    # Initialise aggregation bucket
    if (-not $toolAgg.ContainsKey($toolName)) {
        $toolAgg[$toolName] = @{ WorstStatus = 'Success'; Messages = [System.Collections.Generic.List[string]]::new(); Count = 0; RunMode = $null }
    }
    $agg = $toolAgg[$toolName]

    # --- Determine wrapper status ---
    $toolResult = $wr.Result
    if (-not $toolResult) {
        $toolResult = [PSCustomObject]@{ Source = $toolName; Status = 'Failed'; Message = 'No result returned'; Findings = @() }
    }
    $wrapperStatus = 'Success'
    if ($wr.Status -eq 'Failed') {
        $wrapperStatus = 'Failed'
    } elseif ($toolResult.PSObject.Properties['Status'] -and $toolResult.Status) {
        $wrapperStatus = $toolResult.Status
    }

    # Capture wrapper-reported RunMode (#94 R1): wrappers that opt into -Since
    # report their actual coverage so orchestrator state records it accurately.
    if ($toolResult.PSObject.Properties['RunMode'] -and $toolResult.RunMode) {
        $agg.RunMode = [string]$toolResult.RunMode
    }

    # Track errors
    if ($wrapperStatus -eq 'Failed') {
        $errMsg = ''
        if ($wr.Error) { $errMsg = $wr.Error }
        elseif ($toolResult.PSObject.Properties['Message'] -and $toolResult.Message) { $errMsg = $toolResult.Message }
        else { $errMsg = 'Tool execution failed' }
        $toolErrors.Add([PSCustomObject]@{ Tool = $toolName; Error = Remove-Credentials $errMsg; Timestamp = Get-Date })
    }

    # Update worst status (ranking: Failed > PartialSuccess > Skipped > Success)
    if ($wrapperStatus -eq 'Failed') {
        $agg.WorstStatus = 'Failed'
        $rawMsg = if ($toolResult.PSObject.Properties['Message'] -and $toolResult.Message) { $toolResult.Message } else { '' }
        $agg.Messages.Add((Remove-Credentials $rawMsg))
    } elseif ($wrapperStatus -eq 'PartialSuccess' -and $agg.WorstStatus -notin @('Failed')) {
        $agg.WorstStatus = 'PartialSuccess'
        $rawMsg = if ($toolResult.PSObject.Properties['Message'] -and $toolResult.Message) { $toolResult.Message } else { '' }
        $agg.Messages.Add((Remove-Credentials $rawMsg))
    } elseif ($wrapperStatus -eq 'Skipped' -and $agg.WorstStatus -notin @('Failed', 'PartialSuccess')) {
        $agg.WorstStatus = 'Skipped'
    }

    # --- Run normaliser ---
    $normFunc = if ($meta) { $meta.normalizer } else { $null }
    $v3Findings = @()
    if ($normFunc -and (Get-Command $normFunc -ErrorAction SilentlyContinue)) {
        try {
            $normCmd = Get-Command $normFunc -ErrorAction SilentlyContinue
            $normParams = @{ ToolResult = $toolResult }
            if ($normCmd -and (@($normCmd.Parameters.Keys) -contains 'EdgeCollector')) {
                $normParams['EdgeCollector'] = $normalizerEdgeCollector
            }
            $v3Findings = @(& $normFunc @normParams)
        } catch {
            Write-Warning (Remove-Credentials "Normaliser $normFunc failed: $_")
            $v3Findings = @()
        }
    }

    # Feed v3 findings into EntityStore
    foreach ($finding in $v3Findings) {
        if (-not $finding) { continue }
        try {
            $finding = Update-FindingScopeContext `
                -Finding $finding `
                -SubscriptionContextLookup $subscriptionContextLookup `
                -DefaultSubscriptionId $defaultSubscriptionId `
                -ManagementGroupId $ManagementGroupId

            if (Get-Command Add-FrameworkMapping -ErrorAction SilentlyContinue) {
                $null = Add-FrameworkMapping -Finding $finding -FilterFramework $Framework
            }
            $store.AddFinding($finding)

            # If the finding carries cost metadata, fold it onto the owning entity.
            if ($finding.PSObject.Properties['MonthlyCost'] -or $finding.PSObject.Properties['Currency']) {
                $hasCost = ($finding.PSObject.Properties['MonthlyCost'] -and $null -ne $finding.MonthlyCost -and $finding.MonthlyCost -ne 0) -or `
                           ($finding.PSObject.Properties['Currency'] -and $finding.Currency)
                if ($hasCost) {
                    $stub = [pscustomobject]@{
                        EntityId       = $finding.EntityId
                        EntityType     = $finding.EntityType
                        Platform       = $finding.Platform
                        MonthlyCost    = $finding.MonthlyCost
                        Currency       = $finding.Currency
                        CostTrend      = if ($finding.PSObject.Properties['CostTrend']) { $finding.CostTrend } else { $null }
                        SubscriptionId = $finding.SubscriptionId
                        SubscriptionName = if ($finding.PSObject.Properties['SubscriptionName']) { $finding.SubscriptionName } else { $null }
                        ResourceGroup  = $finding.ResourceGroup
                        ManagementGroupPath = if ($finding.PSObject.Properties['ManagementGroupPath']) { $finding.ManagementGroupPath } else { $null }
                    }
                    try { $store.MergeEntityMetadata($stub) } catch {
                        Write-Warning (Remove-Credentials "MergeEntityMetadata failed for cost enrichment: $_")
                    }
                }
            }
        } catch {
            Write-Warning (Remove-Credentials "EntityStore.AddFinding failed for $toolName : $_")
        }
    }

    $agg.Count += $v3Findings.Count

    # Build v1-compatible flat finding for results.json backward compat
    foreach ($f in $v3Findings) {
        $allResults.Add([PSCustomObject]@{
            Id           = $f.Id
            Source       = $f.Source
            Category     = if ($f.PSObject.Properties['Category'] -and $f.Category) { $f.Category } else { '' }
            Title        = $f.Title
            Severity     = if ($f.PSObject.Properties['Severity'] -and $f.Severity) { $f.Severity } else { 'Info' }
            Compliant    = $f.Compliant
            Detail       = if ($f.PSObject.Properties['Detail'] -and $f.Detail) { $f.Detail } else { '' }
            Remediation  = if ($f.PSObject.Properties['Remediation'] -and $f.Remediation) { $f.Remediation } else { '' }
            ResourceId   = if ($f.PSObject.Properties['ResourceId'] -and $f.ResourceId) { $f.ResourceId } else { '' }
            LearnMoreUrl = if ($f.PSObject.Properties['LearnMoreUrl'] -and $f.LearnMoreUrl) { $f.LearnMoreUrl } else { '' }
            EntityId     = if ($f.PSObject.Properties['EntityId']) { $f.EntityId } else { '' }
            EntityType   = if ($f.PSObject.Properties['EntityType']) { $f.EntityType } else { '' }
            Platform     = if ($f.PSObject.Properties['Platform']) { $f.Platform } else { '' }
            SubscriptionId = if ($f.PSObject.Properties['SubscriptionId']) { $f.SubscriptionId } else { '' }
            SubscriptionName = if ($f.PSObject.Properties['SubscriptionName']) { $f.SubscriptionName } else { '' }
            ResourceGroup = if ($f.PSObject.Properties['ResourceGroup']) { $f.ResourceGroup } else { '' }
            ManagementGroupPath = if ($f.PSObject.Properties['ManagementGroupPath']) { $f.ManagementGroupPath } else { @() }
            Confidence   = if ($f.PSObject.Properties['Confidence']) { $f.Confidence } else { '' }
            EvidenceCount = if ($f.PSObject.Properties['EvidenceCount']) { $f.EvidenceCount } else { 0 }
            MissingDimensions = if ($f.PSObject.Properties['MissingDimensions']) { $f.MissingDimensions } else { @() }
            Frameworks   = if ($f.PSObject.Properties['Frameworks']   -and $f.Frameworks)   { $f.Frameworks }   else { @() }
            Controls     = if ($f.PSObject.Properties['Controls']     -and $f.Controls)     { $f.Controls }     else { @() }
        })
    }
}

# Emit per-tool status lines and build tool-status.json entries
foreach ($entry in $toolAgg.GetEnumerator()) {
    Write-Host "  $($entry.Key): $($entry.Value.Count) findings" -ForegroundColor Gray
    $toolStatus.Add([PSCustomObject]@{
        Tool     = $entry.Key
        Status   = $entry.Value.WorstStatus
        Message  = ($entry.Value.Messages -join '; ')
        Findings = $entry.Value.Count
        RunMode  = $entry.Value.RunMode
    })
}

# ---------------------------------------------------------------------------
# Post-collection correlation stage
# ---------------------------------------------------------------------------
$correlators = @($manifest.tools | Where-Object { $_.type -eq 'correlator' -and $_.enabled -and (ShouldRunTool $_.name) })
foreach ($corrDef in $correlators) {
    $corrName = $corrDef.name
    Write-Host "`n[correlator] Running $($corrDef.displayName)..." -ForegroundColor Magenta
    try {
        $corrScript = Join-Path $PSScriptRoot $corrDef.script
        if (-not (Test-Path $corrScript)) {
            Write-Warning "Correlator script not found: $corrScript"
            $toolStatus.Add([PSCustomObject]@{ Tool = $corrName; Status = 'Failed'; Message = "Script not found: $corrScript"; Findings = 0 })
            continue
        }
        $corrToolResult = $null
        if ($corrName -eq 'ado-pipeline-correlator') {
            . $corrScript
            if (-not $AdoOrg) {
                $toolStatus.Add([PSCustomObject]@{ Tool = $corrName; Status = 'Skipped'; Message = 'No -AdoOrg provided'; Findings = 0 })
                continue
            }
            $corrParams = @{
                AdoOrg              = $AdoOrg
                SecretsFindingsPath = (Join-Path $OutputPath 'ado-repos-secrets-findings.json')
            }
            if ($AdoProject) { $corrParams['AdoProject'] = $AdoProject }
            if ($AdoPat) { $corrParams['AdoPat'] = $AdoPat }
            $corrToolResult = & $corrScript @corrParams
            if (-not $corrToolResult) {
                $corrToolResult = [PSCustomObject]@{
                    Source   = 'ado-pipeline-correlator'
                    Status   = 'Failed'
                    Message  = 'Correlator returned no result.'
                    Findings = @()
                }
            }
        } else {
            . $corrScript
            $corrParams = @{ EntityStore = $store; TenantId = ($TenantId ?? 'unknown') }
            if ($corrDef.optionalParams -contains 'IncludeGraphLookup') {
                $mgCmd = Get-Command -Name 'Get-MgApplication' -ErrorAction SilentlyContinue
                if ($mgCmd) { $corrParams['IncludeGraphLookup'] = $true }
            }
            if ($ManagementGroupId -and $subscriptionsToScan.Count -gt 1) {
                $corrParams['PortfolioMode'] = $true
            }

            # Dispatch by entryFunction (manifest), falling back to Invoke-IdentityCorrelation
            # so older manifests keep working.
            $entryFn = if ($corrDef.PSObject.Properties['entryFunction'] -and $corrDef.entryFunction) {
                [string]$corrDef.entryFunction
            } else {
                'Invoke-IdentityCorrelation'
            }
            $entryCmd = Get-Command -Name $entryFn -ErrorAction SilentlyContinue
            if (-not $entryCmd) {
                Write-Warning "Correlator ${corrName}: entry function '$entryFn' not found after dot-sourcing $($corrDef.script)"
                $toolStatus.Add([PSCustomObject]@{ Tool = $corrName; Status = 'Failed'; Message = "Entry function '$entryFn' missing"; Findings = 0 })
                continue
            }

            # Strip params that the entry function does not accept (defensive against
            # heterogeneous correlator signatures).
            $accepted = @($entryCmd.Parameters.Keys)
            $callParams = @{}
            foreach ($k in $corrParams.Keys) {
                if ($accepted -contains $k) { $callParams[$k] = $corrParams[$k] }
            }
            # Wrapper-envelope contract (issue #187): correlators MAY return either
            #   (a) a flat array of FindingRow objects (legacy, e.g. Invoke-IdentityCorrelation), or
            #   (b) a PSCustomObject envelope @{ Status; RunId?; Findings; Edges? } where
            #       the wrapper has already self-added Edges to the EntityStore.
            # Sniff requires Findings AND a second envelope marker (Status or Edges) to
            # avoid misclassifying a future correlator that returns a single PSCustomObject
            # finding row that happens to expose a `.Findings` property.
            $corrRaw = & $entryCmd @callParams
            $isEnvelope = (
                $corrRaw -is [pscustomobject] -and
                $corrRaw.PSObject.Properties['Findings'] -and (
                    $corrRaw.PSObject.Properties['Status'] -or
                    $corrRaw.PSObject.Properties['Edges']
                )
            )
            if ($isEnvelope) {
                $corrFindings = @($corrRaw.Findings)
            } else {
                $corrFindings = @($corrRaw)
            }
            $corrToolResult = [PSCustomObject]@{
                Source   = $corrName
                Status   = 'Success'
                Message  = ''
                Findings = $corrFindings
            }
        }

        # Feed correlation findings into EntityStore and flat results
        $corrNormFunc = $corrDef.normalizer
        $corrV3 = @()
        if ($corrNormFunc -and (Get-Command $corrNormFunc -ErrorAction SilentlyContinue)) {
            $corrV3 = @(& $corrNormFunc -ToolResult $corrToolResult)
        } elseif ($corrToolResult -and $corrToolResult.PSObject.Properties['Findings']) {
            $corrV3 = @($corrToolResult.Findings)
        }

        foreach ($finding in $corrV3) {
            if (-not $finding) { continue }
            $finding = Update-FindingScopeContext `
                -Finding $finding `
                -SubscriptionContextLookup $subscriptionContextLookup `
                -DefaultSubscriptionId $null `
                -ManagementGroupId $ManagementGroupId
            try { $store.AddFinding($finding) }
            catch { Write-Warning (Remove-Credentials "EntityStore.AddFinding failed for $corrName : $_") }
        }

        foreach ($f in $corrV3) {
            $allResults.Add([PSCustomObject]@{
                Id           = $f.Id
                Source       = $f.Source
                Category     = if ($f.PSObject.Properties['Category'] -and $f.Category) { $f.Category } else { '' }
                Title        = $f.Title
                Severity     = if ($f.PSObject.Properties['Severity'] -and $f.Severity) { $f.Severity } else { 'Info' }
                Compliant    = $f.Compliant
                Detail       = if ($f.PSObject.Properties['Detail'] -and $f.Detail) { $f.Detail } else { '' }
                Remediation  = if ($f.PSObject.Properties['Remediation'] -and $f.Remediation) { $f.Remediation } else { '' }
                ResourceId   = if ($f.PSObject.Properties['ResourceId'] -and $f.ResourceId) { $f.ResourceId } else { '' }
                LearnMoreUrl = if ($f.PSObject.Properties['LearnMoreUrl'] -and $f.LearnMoreUrl) { $f.LearnMoreUrl } else { '' }
                EntityId     = if ($f.PSObject.Properties['EntityId']) { $f.EntityId } else { '' }
                EntityType   = if ($f.PSObject.Properties['EntityType']) { $f.EntityType } else { '' }
                Platform     = if ($f.PSObject.Properties['Platform']) { $f.Platform } else { '' }
                SubscriptionId = if ($f.PSObject.Properties['SubscriptionId']) { $f.SubscriptionId } else { '' }
                SubscriptionName = if ($f.PSObject.Properties['SubscriptionName']) { $f.SubscriptionName } else { '' }
                ResourceGroup = if ($f.PSObject.Properties['ResourceGroup']) { $f.ResourceGroup } else { '' }
                ManagementGroupPath = if ($f.PSObject.Properties['ManagementGroupPath']) { $f.ManagementGroupPath } else { @() }
                Confidence   = if ($f.PSObject.Properties['Confidence']) { $f.Confidence } else { '' }
                EvidenceCount = if ($f.PSObject.Properties['EvidenceCount']) { $f.EvidenceCount } else { 0 }
                MissingDimensions = if ($f.PSObject.Properties['MissingDimensions']) { $f.MissingDimensions } else { @() }
            })
        }

        Write-Host "  $corrName`: $($corrV3.Count) correlation finding(s)" -ForegroundColor Gray
        $corrStatus = if ($corrToolResult.PSObject.Properties['Status'] -and $corrToolResult.Status) { [string]$corrToolResult.Status } else { 'Success' }
        $corrMessage = if ($corrToolResult.PSObject.Properties['Message'] -and $corrToolResult.Message) { Remove-Credentials ([string]$corrToolResult.Message) } else { "Emitted $($corrV3.Count) correlation finding(s)" }
        $toolStatus.Add([PSCustomObject]@{ Tool = $corrName; Status = $corrStatus; Message = $corrMessage; Findings = $corrV3.Count })
    } catch {
        $errMsg = Remove-Credentials "$_"
        Write-Warning "Correlator $corrName failed: $errMsg"
        $toolStatus.Add([PSCustomObject]@{ Tool = $corrName; Status = 'Failed'; Message = $errMsg; Findings = 0 })
    }
}

# ---------------------------------------------------------------------------
# Write output
# ---------------------------------------------------------------------------
$portfolio = $null
$portfolioFile = Join-Path $OutputPath 'portfolio.json'
try {
    if (-not (Test-Path $OutputPath)) {
        $null = New-Item -ItemType Directory -Path $OutputPath -Force
    }

    # v1-compatible flat findings (backward compat for reports)
    $outputFile = Join-Path $OutputPath 'results.json'
    $resultsJson = if ($allResults.Count -eq 0) { '[]' } else { $allResults | ConvertTo-Json -Depth 5 }
    Set-Content -Path $outputFile -Value (Remove-Credentials $resultsJson) -Encoding UTF8

    # v3 entity-centric output (v3.1 shape: { SchemaVersion, Entities, Edges })
    $entitiesFile = Join-Path $OutputPath 'entities.json'
    $entities = Export-Entities -Store $store
    if ($null -eq $entities) { $entities = @() }
    foreach ($edge in @($normalizerEdgeCollector)) {
        if (-not $edge) { continue }
        try { $store.AddEdge([pscustomobject]$edge) }
        catch {
            $getEdgePropertySafely = {
                param([object] $EdgeObject, [string] $PropertyName)
                if ($EdgeObject -and $EdgeObject.PSObject.Properties[$PropertyName]) { return [string]$EdgeObject.$PropertyName }
                return '<missing>'
            }
            $edgeRelation = & $getEdgePropertySafely $edge 'Relation'
            $edgeSource = & $getEdgePropertySafely $edge 'Source'
            $edgeTarget = & $getEdgePropertySafely $edge 'Target'
            $edgeSummary = "Relation=$edgeRelation; Source=$edgeSource; Target=$edgeTarget"
            Write-Warning (Remove-Credentials "EdgeCollector edge rejected ($edgeSummary): $_")
        }
    }
    $edges = @()
    if (Get-Command Export-Edges -ErrorAction SilentlyContinue) {
        $edges = @(Export-Edges -Store $store)
    }
    $entitiesPayload = [PSCustomObject]@{
        SchemaVersion = '3.1'
        Entities      = @($entities)
        Edges         = $edges
    }
    $entitiesJson = $entitiesPayload | ConvertTo-Json -Depth 30
    Set-Content -Path $entitiesFile -Value (Remove-Credentials $entitiesJson) -Encoding UTF8

    $reportManifestPath = Join-Path $OutputPath 'report-manifest.json'
    if ((Get-Command Select-ReportArchitecture -ErrorAction SilentlyContinue) -and (Get-Command New-ReportManifest -ErrorAction SilentlyContinue)) {
        try {
            $reportArchConfig = $null
            if ($manifest.PSObject.Properties['report_architecture']) {
                $reportArchConfig = $manifest.report_architecture
            }
            # Do NOT pass -HeadroomFactor here: Select-ReportArchitecture honors
            # report_architecture.headroom_factor from the manifest when unbound.
            $selection = Select-ReportArchitecture `
                -FindingCount $allResults.Count `
                -EntityCount @($entities).Count `
                -EdgeCount @($edges).Count `
                -ArchitectureConfig $reportArchConfig
            $verification = [pscustomobject]@{}
            if (Get-Command Get-ReportVerificationStubs -ErrorAction SilentlyContinue) {
                $verification = Get-ReportVerificationStubs -ArchitectureConfig $reportArchConfig
            }
            $null = New-ReportManifest `
                -Path $reportManifestPath `
                -SelectedTier $selection.Tier `
                -Measurements $selection.Measurements `
                -HeadroomFactor ([double]$selection.Headroom.Factor) `
                -PickerReasoning @($selection.Reasoning) `
                -ForcedOverride ([bool]$selection.ForcedOverride) `
                -VerificationResults $verification `
                -AutoUpgrades @() `
                -Timings ([pscustomobject]@{}) `
                -Features @() `
                -Policy ([pscustomobject]@{
                        alz = [pscustomobject]@{
                            mode = $AlzReferenceMode
                        }
                    })
        } catch {
            Write-Warning (Remove-Credentials "Failed to write report-manifest.json: $_")
        }
    }

    $portfolio = Get-PortfolioRollup -Store $store -Entities $entities -ManagementGroupId $ManagementGroupId
    $portfolioJson = if ($null -eq $portfolio) { '{}' } else { $portfolio | ConvertTo-Json -Depth 30 }
    Set-Content -Path $portfolioFile -Value (Remove-Credentials $portfolioJson) -Encoding UTF8

    # Optional entity snapshot drift report (issue #160)
    $compareBaseDir = $null
    if ($CompareTo) {
        if (Test-Path $CompareTo -PathType Container) {
            $compareBaseDir = (Resolve-Path $CompareTo).Path
        } else {
            Write-Host "  [Drift] Compare path not found, skipping: $CompareTo" -ForegroundColor DarkGray
        }
    } elseif ($CompareToPrevious -and (Get-Command Get-LatestPreviousRun -ErrorAction SilentlyContinue)) {
        $outputRoot = Split-Path -Parent $OutputPath
        $autoPrevious = Get-LatestPreviousRun -OutputRoot $outputRoot -CurrentRunDir $OutputPath
        if ($autoPrevious) {
            $compareBaseDir = $autoPrevious
            Write-Host "  [Drift] Auto-selected previous run: $compareBaseDir" -ForegroundColor DarkGray
        } else {
            Write-Host "  [Drift] No previous run found under output root, skipping." -ForegroundColor DarkGray
        }
    }

    if ($compareBaseDir) {
        $previousEntitiesPath = Join-Path $compareBaseDir 'entities.json'
        if (Test-Path $previousEntitiesPath) {
            try {
                $drift = Compare-EntitySnapshots -Previous $previousEntitiesPath -Current $entitiesFile
                $driftReportScript = Join-Path $PSScriptRoot 'modules' 'reports' 'New-DriftReport.ps1'
                if (Test-Path $driftReportScript) {
                    & $driftReportScript -Comparison $drift -PreviousSnapshot $previousEntitiesPath -CurrentSnapshot $entitiesFile -OutputPath $OutputPath
                } else {
                    Write-Warning "Drift report script not found at '$driftReportScript'."
                }
            } catch {
                Write-Warning (Remove-Credentials "Drift comparison failed: $_")
            }
        } else {
            Write-Host "  [Drift] Previous entities snapshot not found, skipping: $previousEntitiesPath" -ForegroundColor DarkGray
        }
    }

    if ($SinkLogAnalytics) {
        $sinkStatus = 'Success'
        $sinkMessage = 'Findings and entities sent to Azure Monitor Logs Ingestion API.'
        try {
            $sinkConfigRaw = Get-Content -Path $LogAnalyticsConfig -Raw -ErrorAction Stop
            $sinkConfig = $sinkConfigRaw | ConvertFrom-Json -ErrorAction Stop

            foreach ($requiredField in @('DceEndpoint', 'DcrImmutableId', 'FindingsStream', 'EntitiesStream')) {
                if (-not $sinkConfig.PSObject.Properties[$requiredField] -or [string]::IsNullOrWhiteSpace([string]$sinkConfig.$requiredField)) {
                    throw "Missing required Log Analytics config field '$requiredField'."
                }
            }

            $sinkDryRun = $false
            if ($sinkConfig.PSObject.Properties['DryRun']) {
                $sinkDryRun = [bool]$sinkConfig.DryRun
            }

            $findingsSinkResult = Send-FindingsToLogAnalytics `
                -EntitiesJson $entitiesFile `
                -DceEndpoint ([string]$sinkConfig.DceEndpoint) `
                -DcrImmutableId ([string]$sinkConfig.DcrImmutableId) `
                -StreamName ([string]$sinkConfig.FindingsStream) `
                -DryRun:$sinkDryRun

            $entitiesSinkResult = Send-EntitiesToLogAnalytics `
                -EntitiesJson $entitiesFile `
                -DceEndpoint ([string]$sinkConfig.DceEndpoint) `
                -DcrImmutableId ([string]$sinkConfig.DcrImmutableId) `
                -StreamName ([string]$sinkConfig.EntitiesStream) `
                -DryRun:$sinkDryRun

            $sinkMessage = "Findings records: $($findingsSinkResult.RecordsProcessed) in $($findingsSinkResult.BatchesProcessed) batch(es); entities records: $($entitiesSinkResult.RecordsProcessed) in $($entitiesSinkResult.BatchesProcessed) batch(es)." + $(if ($sinkDryRun) { ' DryRun enabled.' } else { '' })
            Write-Host "[sink] $sinkMessage" -ForegroundColor DarkCyan
        } catch {
            $sinkStatus = 'PartialSuccess'
            $sinkMessage = Remove-Credentials "$_"
            Write-Warning "[sink] Log Analytics sink failed: $sinkMessage"
        }
        $toolStatus.Add([PSCustomObject]@{
                Tool     = 'log-analytics-sink'
                Status   = $sinkStatus
                Message  = $sinkMessage
                Findings = @($allResults).Count
            })
    }

    # Tool status
    $statusFile = Join-Path $OutputPath 'tool-status.json'
    $statusJson = $toolStatus | ConvertTo-Json -Depth 3
    $statusJson = Remove-Credentials $statusJson
    $statusJson | Set-Content -Path $statusFile -Encoding UTF8

    $store.CleanupSpillFiles()
} catch {
    Write-Error (Remove-Credentials "Failed to write output to ${OutputPath}: $_")
    return
}

# ---------------------------------------------------------------------------
# AI triage (optional)
# ---------------------------------------------------------------------------
$triageFile = Join-Path $OutputPath 'triage.json'
if ($EnableAiTriage) {
    Write-Host "`n[AI] Running Copilot triage..." -ForegroundColor Magenta
    try {
        # Wire to the new sanitized PowerShell triage module. The legacy
        # modules/Invoke-CopilotTriage.ps1 path bypassed Remove-Credentials
        # and is no longer supported (round-2 triage bottom-fix).
        $triageModulePath = Join-Path $modulesPath 'shared' 'Triage' 'Invoke-CopilotTriage.ps1'
        if (-not (Test-Path -LiteralPath $triageModulePath)) {
            # Dot-source Schema.ps1 to access New-FindingError if it has not
            # been loaded yet by the orchestrator's earlier setup.
            $schemaPath = Join-Path $modulesPath 'shared' 'Schema.ps1'
            if ((Test-Path -LiteralPath $schemaPath) -and -not (Get-Command -Name New-FindingError -ErrorAction SilentlyContinue)) {
                . $schemaPath
            }
            if (Get-Command -Name New-FindingError -ErrorAction SilentlyContinue) {
                throw (New-FindingError -Source 'triage' -Category 'TriageModuleMissing' `
                    -Reason 'AI triage module not found at expected path.' `
                    -Remediation 'Reinstall azure-analyzer or restore modules/shared/Triage/Invoke-CopilotTriage.ps1 from source control.' `
                    -Details "Expected: $triageModulePath")
            }
            # Defensive last-resort: Schema.ps1 unavailable. Throw a structured
            # PSCustomObject (same shape) so callers still get the rich-error
            # contract instead of a raw string.
            throw ([PSCustomObject]@{
                PSTypeName   = 'AzureAnalyzer.FindingError'
                Source       = 'triage'
                Category     = 'TriageModuleMissing'
                Reason       = 'AI triage module not found at expected path.'
                Remediation  = 'Reinstall azure-analyzer or restore modules/shared/Triage/Invoke-CopilotTriage.ps1 from source control.'
                Details      = "Expected: $triageModulePath"
                TimestampUtc = (Get-Date).ToUniversalTime().ToString('o')
            })
        }
        . $triageModulePath
        $triageFindings = @()
        if (Test-Path -LiteralPath $outputFile) {
            try {
                $triageInput = Get-Content -LiteralPath $outputFile -Raw -Encoding utf8 | ConvertFrom-Json -Depth 20
                if ($triageInput -is [System.Collections.IEnumerable] -and -not ($triageInput -is [string])) {
                    $triageFindings = @($triageInput)
                } elseif ($null -ne $triageInput.findings) {
                    $triageFindings = @($triageInput.findings)
                } else {
                    $triageFindings = @($triageInput)
                }
            } catch {
                Write-Warning (Remove-Credentials "Failed to parse findings for triage: $_")
            }
        }
        if ($triageFindings.Count -gt 0) {
            $triageParams = @{
                Findings    = $triageFindings
                TriageModel = $TriageModel
            }
            if (-not [string]::IsNullOrWhiteSpace($CopilotTier)) {
                $triageParams['CopilotTier'] = $CopilotTier
            }
            if ($SingleModel) {
                $triageParams['SingleModel'] = $true
            }
            $triageResult = Invoke-CopilotTriage @triageParams
            if ($null -ne $triageResult) {
                $triageJson = $triageResult | ConvertTo-Json -Depth 10
                # Defense-in-depth: scrub the serialized payload before writing.
                $triageJson = Remove-Credentials $triageJson
                Set-Content -LiteralPath $triageFile -Value $triageJson -Encoding utf8
            } else {
                Write-Warning "AI triage did not produce results."
            }
        } else {
            Write-Warning "AI triage skipped: no findings to triage."
        }
    } catch { Write-Warning (Remove-Credentials "AI triage failed: $_ -- continuing without enrichment.") }
} else {
    if (Test-Path $triageFile) { Remove-Item $triageFile -Force -ErrorAction SilentlyContinue }
}
$triageArg    = if (Test-Path $triageFile) { @{ TriagePath = $triageFile } } else { @{} }
$portfolioArg = if ($portfolio) { @{ Portfolio = $portfolio } } else { @{} }
$snapshotDir  = Join-Path $OutputPath 'snapshots'

# 1. Resolve baseline BEFORE archiving the current run so it is not in the index yet.
#    Explicit -PreviousRun always wins over -BaselineMode auto-discovery.
$resolvedBaseline = ''
if ($PreviousRun -and (Test-Path $PreviousRun)) {
    $resolvedBaseline = $PreviousRun
} elseif ($BaselineMode -eq 'auto' -and (Get-Command Resolve-BaselineRun -ErrorAction SilentlyContinue)) {
    $autoBaseline = Resolve-BaselineRun -SnapshotDir $snapshotDir
    if ($autoBaseline) {
        Write-Host "  [Baseline] Auto-selected prior run: $autoBaseline" -ForegroundColor DarkGray
        $resolvedBaseline = $autoBaseline
    }
}

$prevRunArg = if ($resolvedBaseline) { @{ PreviousRun = $resolvedBaseline } } else { @{} }

# 2. Archive + trend are both suppressed when -BaselineMode none.
#    RunId uses millisecond precision + random suffix to avoid second-resolution collision
#    on concurrent or rapid successive runs.
$trendArg = @{}
if ($BaselineMode -ne 'none') {
    $runId = "$((Get-Date -Format 'yyyyMMdd-HHmmssfff'))-$(Get-Random -Max 9999)"
    if (Get-Command Add-RunSnapshot -ErrorAction SilentlyContinue) {
        try {
            Add-RunSnapshot -SnapshotDir $snapshotDir -RunId $runId -SourceFile $outputFile -MaxHistory 10
        } catch {
            Write-Warning (Remove-Credentials "Snapshot archive failed: $_")
        }
    }
    if (Get-Command Get-RunTrend -ErrorAction SilentlyContinue) {
        try {
            $trend = Get-RunTrend -SnapshotDir $snapshotDir -MaxRuns 10
            if ($trend.Count -ge 2) {
                $trendArg = @{ Trend = $trend }
            }
        } catch {
            Write-Warning (Remove-Credentials "Trend aggregation failed: $_")
        }
    }
}

# ---------------------------------------------------------------------------
# Persist scan state and run metadata for incremental / scheduled runs (#94)
# ---------------------------------------------------------------------------
$runMode = if ($bootstrapRun) { 'Full' }
           elseif ($Incremental) { 'Incremental' }
           elseif (($null -ne $Since)) { 'Incremental' }
           else { 'Full' }
$baselineFile = Join-Path $OutputPath 'results-baseline.json'
$runMetadataFile = Join-Path $OutputPath 'run-metadata.json'

try {
    if (Get-Command Read-ScanState -ErrorAction SilentlyContinue) {
        $scanState = if ($scanStatePreRun) { $scanStatePreRun } else { Read-ScanState -OutputPath $OutputPath }
        $nowUtc = (Get-Date).ToUniversalTime()
        $sinceUsed = if (($null -ne $Since)) { ([datetime]$Since).ToUniversalTime() } else { $null }

        foreach ($ts in $toolStatus) {
            # Prefer wrapper-reported RunMode. If the wrapper opted in ($null -ne RunMode)
            # we trust it. Otherwise under -Incremental default to FullFallback so
            # reports do not falsely advertise incremental coverage. Bootstrap runs
            # and pure full runs always record Full (#94 R1 Goldeneye).
            $wrapperRunMode = if ($ts.PSObject.Properties['RunMode']) { $ts.RunMode } else { $null }
            $entryRunMode =
                if ($bootstrapRun) {
                    'Full'
                } elseif ($wrapperRunMode) {
                    [string]$wrapperRunMode
                } elseif ($Incremental -or ($null -ne $Since)) {
                    'FullFallback'
                } else {
                    'Full'
                }
            $toolSinceUsed = if ($incrementalSinceMap.ContainsKey($ts.Tool)) { [datetime]$incrementalSinceMap[$ts.Tool] } else { $sinceUsed }
            $statusForState = switch ($ts.Status) {
                'Success' { 'Success'; break }
                'Failed'  { 'Failed';  break }
                'Skipped' { 'Skipped'; break }
                default   { 'Partial' }
            }
            $null = Update-ScanStateToolEntry -State $scanState -Tool $ts.Tool `
                -Status $statusForState -RunMode $entryRunMode `
                -FindingCount ([int]$ts.Findings) -SinceUsed $toolSinceUsed -Now $nowUtc
        }

        if (Get-Command Update-FindingHistoryFromDelta -ErrorAction SilentlyContinue) {
            $null = Update-FindingHistoryFromDelta -State $scanState -Current $allResults -Now $nowUtc
        }

        # Bootstrap runs MUST seed the baseline so subsequent -Incremental runs
        # have something to diff against (#94 R1 Goldeneye).
        $shouldRefreshBaseline = $bootstrapRun -or (-not $Incremental -and -not ($null -ne $Since))
        $null = Update-ScanStateRun -State $scanState -RunMode $runMode -Now $nowUtc -UpdateBaseline:$shouldRefreshBaseline
        $null = Write-ScanState -OutputPath $OutputPath -State $scanState

        if ($shouldRefreshBaseline -and (Test-Path $outputFile)) {
            try {
                Copy-Item -Path $outputFile -Destination $baselineFile -Force
            } catch {
                Write-Warning (Remove-Credentials "Failed to refresh baseline ${baselineFile}: $_")
            }
        }

        $runMeta = [ordered]@{
            schemaVersion   = 1
            runMode         = $runMode
            generatedUtc    = $nowUtc.ToString('o')
            sinceUtc        = if ($sinceUsed) { $sinceUsed.ToString('o') } else { $null }
            baselineUtc     = if ($scanState.runs.lastBaselineUtc) { [string]$scanState.runs.lastBaselineUtc } else { $null }
            previousRunPath = if ($PreviousRun) { $PreviousRun } else { $null }
            tools = @($toolStatus | ForEach-Object {
                $entry = Get-ScanStateToolEntry -State $scanState -Tool $_.Tool
                [ordered]@{
                    tool          = $_.Tool
                    status        = $_.Status
                    findingCount  = [int]$_.Findings
                    runMode       = if ($entry) { [string]$entry.runMode } else { $runMode }
                    lastSuccessUtc = if ($entry) { [string]$entry.lastSuccessUtc } else { $null }
                    sinceUsedUtc  = if ($entry) { [string]$entry.sinceUsedUtc } else { $null }
                }
            })
        }
        $runMetaJson = $runMeta | ConvertTo-Json -Depth 6
        if (Get-Command Remove-Credentials -ErrorAction SilentlyContinue) {
            $runMetaJson = Remove-Credentials $runMetaJson
        }
        $runMetaTemp = "$runMetadataFile.tmp-$([Guid]::NewGuid().ToString('N'))"
        Set-Content -Path $runMetaTemp -Value $runMetaJson -Encoding UTF8
        Move-Item -Path $runMetaTemp -Destination $runMetadataFile -Force
    }
} catch {
    Write-Warning (Remove-Credentials "Scan-state persistence failed: $_")
}

# ---------------------------------------------------------------------------
# Generate reports
# ---------------------------------------------------------------------------
$htmlReport = Join-Path $OutputPath 'report.html'
$mdReport   = Join-Path $OutputPath 'report.md'

try {
    & "$PSScriptRoot\New-HtmlReport.ps1" -InputPath $outputFile -OutputPath $htmlReport @triageArg @prevRunArg @trendArg @portfolioArg
} catch {
    Write-Warning (Remove-Credentials "HTML report generation failed: $_")
}

$mdBaselineArg = if ($resolvedBaseline) { @{ BaselinePath = $resolvedBaseline } } else { @{} }
try {
    & "$PSScriptRoot\New-MdReport.ps1" -InputPath $outputFile -OutputPath $mdReport @triageArg @mdBaselineArg @trendArg @portfolioArg
} catch {
    Write-Warning (Remove-Credentials "Markdown report generation failed: $_")
}

# ---------------------------------------------------------------------------
# Run history snapshot + executive dashboard (#97)
# ---------------------------------------------------------------------------
if (Get-Command Save-RunSnapshot -ErrorAction SilentlyContinue) {
    try {
        $toolNames = @($manifest.tools | Where-Object { ShouldRunTool $_.name } | ForEach-Object { $_.name })
        $null = Save-RunSnapshot `
            -OutputPath $OutputPath `
            -ResultsPath $outputFile `
            -Tools $toolNames `
            -Subscriptions @($subscriptionsToScan)
        $null = Remove-OldRunSnapshots -OutputPath $OutputPath -Retention $HistoryRetention
    } catch {
        Write-Warning (Remove-Credentials "Run history snapshot failed: $_")
    }
}

try {
    $dashboardReport = Join-Path $OutputPath 'dashboard.html'
    & "$PSScriptRoot\New-ExecDashboard.ps1" -InputPath $outputFile -OutputPath $dashboardReport
} catch {
    Write-Warning (Remove-Credentials "Executive dashboard generation failed: $_")
}

$critical = @($allResults | Where-Object { $_.Severity -eq 'Critical' -and -not $_.Compliant }).Count
$high     = @($allResults | Where-Object { $_.Severity -eq 'High' -and -not $_.Compliant }).Count
$medium   = @($allResults | Where-Object { $_.Severity -eq 'Medium' -and -not $_.Compliant }).Count
$low      = @($allResults | Where-Object { $_.Severity -eq 'Low' -and -not $_.Compliant }).Count

Write-Host "`n=== Summary ===" -ForegroundColor Cyan
Write-Host "  Total findings: $($allResults.Count)"
Write-Host "  Non-compliant — Critical: $critical  High: $high  Medium: $medium  Low: $low" -ForegroundColor Yellow
Write-Host "  Output: $outputFile" -ForegroundColor Green
if (Test-Path $entitiesFile) {
    Write-Host "  Entities: $entitiesFile" -ForegroundColor Green
}
if (Test-Path $portfolioFile) {
    Write-Host "  Portfolio: $portfolioFile" -ForegroundColor Green
}

# ---------------------------------------------------------------------------
# Optional findings viewer launch (#430)
# ---------------------------------------------------------------------------
if ($Show) {
    try {
        if (-not (Get-Command Start-AzureAnalyzerViewer -ErrorAction SilentlyContinue)) {
            $viewerModulePath = Join-Path $PSScriptRoot 'modules' 'shared' 'Viewer.ps1'
            if (Test-Path $viewerModulePath) { . $viewerModulePath }
        }
        if (Get-Command Start-AzureAnalyzerViewer -ErrorAction SilentlyContinue) {
            $viewer = Start-AzureAnalyzerViewer -OutputPath $OutputPath -Port $ViewerPort
            $authUrl = if ($viewer.PSObject.Properties['AuthUrl']) { [string]$viewer.AuthUrl } else { [string]$viewer.Url }
            Write-Host "  Viewer (open in browser): $authUrl" -ForegroundColor Green
            Write-Host "  Viewer Health: $($viewer.HealthUrl)" -ForegroundColor Green
            try {
                # Harden parent dir BEFORE writing the token file so the file inherits a
                # locked-down permission set rather than briefly existing world-readable.
                $tokenDir = Join-Path $OutputPath 'viewer'
                if (-not (Test-Path -LiteralPath $tokenDir)) {
                    New-Item -ItemType Directory -Path $tokenDir -Force | Out-Null
                    if (-not $IsWindows) {
                        & chmod 700 $tokenDir 2>$null
                    }
                }
                $viewerTokenFile = Join-Path $tokenDir 'session-token.txt'
                $previousUmask = $null
                if (-not $IsWindows) {
                    try { $previousUmask = (& sh -c 'umask 077 && umask') } catch { $previousUmask = $null }
                }
                Set-Content -Path $viewerTokenFile -Value ([string]$viewer.Token) -Encoding UTF8
                if ($IsWindows) {
                    try {
                        $acl = New-Object System.Security.AccessControl.FileSecurity
                        $acl.SetAccessRuleProtection($true, $false)
                        $sid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User
                        $rule = New-Object System.Security.AccessControl.FileSystemAccessRule($sid, [System.Security.AccessControl.FileSystemRights]::FullControl, [System.Security.AccessControl.AccessControlType]::Allow)
                        $acl.AddAccessRule($rule)
                        Set-Acl -LiteralPath $viewerTokenFile -AclObject $acl
                    } catch {
                        Write-Warning "Unable to restrict ACL on viewer session token file: $viewerTokenFile"
                    }
                } else {
                    & chmod 600 $viewerTokenFile 2>$null
                    if ($LASTEXITCODE -ne 0) {
                        Write-Warning "Unable to set restrictive permissions on viewer session token file: $viewerTokenFile"
                    }
                }
                Write-Host "  Viewer session token written to: $viewerTokenFile" -ForegroundColor DarkGray
            } catch {
                Write-Warning (Remove-Credentials "Failed to persist viewer session token: $_")
            }
        } else {
            Write-Warning "Viewer module could not be loaded. Skipping -Show launch."
        }
    } catch {
        Write-Warning (Remove-Credentials "Viewer launch failed: $_")
    }
}

# ---------------------------------------------------------------------------
# Error summary
# ---------------------------------------------------------------------------
if ($toolErrors.Count -gt 0) {
    $errorsFile = Join-Path $OutputPath 'errors.json'
    try {
        $errorsJson = $toolErrors | ConvertTo-Json -Depth 3
        $errorsJson = Remove-Credentials $errorsJson
        $errorsJson | Set-Content -Path $errorsFile -Encoding UTF8
    } catch {
        Write-Warning (Remove-Credentials "Failed to write errors.json: $_")
    }
    Write-Host "`n⚠️ $($toolErrors.Count) tool(s) encountered errors:" -ForegroundColor Red
    foreach ($te in $toolErrors) {
        Write-Host (Remove-Credentials "  - $($te.Tool): $($te.Error)") -ForegroundColor Red
    }
}

# Restore env-vars touched for missing-tool messaging (issue #472)
if ($null -eq $script:PriorOrchestratedFlag) { Remove-Item Env:AZURE_ANALYZER_ORCHESTRATED -ErrorAction SilentlyContinue } else { $env:AZURE_ANALYZER_ORCHESTRATED = $script:PriorOrchestratedFlag }
if ($null -eq $script:PriorExplicitToolsFlag) { Remove-Item Env:AZURE_ANALYZER_EXPLICIT_TOOLS -ErrorAction SilentlyContinue } else { $env:AZURE_ANALYZER_EXPLICIT_TOOLS = $script:PriorExplicitToolsFlag }
