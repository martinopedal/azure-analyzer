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
    Azure DevOps organization name. Required for ADO-scoped tools (e.g. ado-connections).
    When provided, ADO tools are included in the run.
.PARAMETER AdoProject
    Azure DevOps project name. When omitted, ADO tools scan all projects in the organization.
.PARAMETER AdoPat
    Azure DevOps PAT passed to ADO-scoped wrappers. Optional; wrappers also read
    ADO_PAT_TOKEN, AZURE_DEVOPS_EXT_PAT, and AZ_DEVOPS_PAT.
.PARAMETER SentinelWorkspaceId
    Full ARM resource ID of the Log Analytics workspace linked to Microsoft Sentinel.
    When provided, the sentinel-incidents tool queries active incidents via KQL.
    Example: /subscriptions/<guid>/resourceGroups/<rg>/providers/Microsoft.OperationalInsights/workspaces/<name>
.PARAMETER SentinelLookbackDays
    Number of days to look back for Sentinel incidents. Default 30. Range 1-365.
.PARAMETER EnableAiTriage
    When set, enriches non-compliant findings via GitHub Copilot SDK with priority
    ranking, risk context, and remediation steps. Requires a GitHub Copilot license.
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
    [string] $SubscriptionId,
    [string] $ManagementGroupId,
    [string] $TenantId,
    [string] $OutputPath = (Join-Path $PSScriptRoot 'output'),
    [string[]] $IncludeTools,
    [string[]] $ExcludeTools,
    [switch] $SkipPrereqCheck,
    [switch] $InstallMissingModules,
    [switch] $Recurse,
    [string] $Repository,
    [string] $GitHubHost = 'github.com',
    [string] $RepoPath,
    [Alias('AdoOrganization')]
    [string] $AdoOrg,
    [string] $AdoProject,
    [Alias('AdoPatToken')]
    [string] $AdoPat,
    [string] $AdoRepoUrl,
    [ValidateRange(0, 10)]
    [int] $ScorecardThreshold = 7,
    [string] $ScanPath,
    [ValidateSet('fs', 'repo')]
    [string] $ScanType,
    [ValidateSet('CIS','NIST','PCI')]
    [string] $Framework,
    [string] $PreviousRun,
    [switch] $InstallFalco,
    [switch] $UninstallFalco,
    [ValidateRange(1, 60)]
    [int] $FalcoCaptureMinutes = 5,
    [string] $SentinelWorkspaceId,
    [ValidateRange(1, 365)]
    [int] $SentinelLookbackDays = 30,
    [switch] $EnableAiTriage
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Dot-source shared modules
# ---------------------------------------------------------------------------
$sharedDir = Join-Path $PSScriptRoot 'modules' 'shared'
foreach ($sharedModule in @('Sanitize', 'Mask', 'Schema', 'Canonicalize', 'EntityStore', 'WorkerPool', 'Checkpoint', 'Installer', 'RemoteClone', 'FrameworkMapper', 'Retry')) {
    $sharedPath = Join-Path $sharedDir "$sharedModule.ps1"
    if (Test-Path $sharedPath) { . $sharedPath }
}
if (-not (Get-Command Remove-Credentials -ErrorAction SilentlyContinue)) {
    function Remove-Credentials { param ([string]$Text) return $Text }
}
if (-not (Get-Command Invoke-WithRetry -ErrorAction SilentlyContinue)) {
    function Invoke-WithRetry { param([scriptblock]$ScriptBlock) & $ScriptBlock }
}

# ---------------------------------------------------------------------------
# Read tool manifest
# ---------------------------------------------------------------------------
$manifest = Get-Content (Join-Path $PSScriptRoot 'tools' 'tool-manifest.json') -Raw | ConvertFrom-Json

# ---------------------------------------------------------------------------
# Tool selection (manifest-driven)
# ---------------------------------------------------------------------------
$validTools = @($manifest.tools | ForEach-Object { $_.name })
$azureScopedTools = @($manifest.tools | Where-Object { $_.provider -eq 'azure' } | ForEach-Object { $_.name })

if ($IncludeTools -and $ExcludeTools) {
    throw "Cannot use both -IncludeTools and -ExcludeTools. Use one or the other."
}
foreach ($t in @($IncludeTools) + @($ExcludeTools) | Where-Object { $_ }) {
    if ($t -notin $validTools) { throw "Unknown tool '$t'. Valid: $($validTools -join ', ')" }
}

function ShouldRunTool { param ([string]$ToolName)
    if ($IncludeTools) { return $ToolName -in $IncludeTools }
    if ($ExcludeTools) { return $ToolName -notin $ExcludeTools }
    return $true
}

# PSRule can run in path-mode without Azure scope; workspace-scoped tools
# (sentinel-incidents) only need -SentinelWorkspaceId, not a subscription.
$workspaceScopedTools = @($manifest.tools | Where-Object { $_.scope -eq 'workspace' } | ForEach-Object { $_.name })
$needsAzureScope = $azureScopedTools | Where-Object { ShouldRunTool $_ } | Where-Object { $_ -ne 'psrule' -and $_ -notin $workspaceScopedTools }
if ($needsAzureScope -and -not $SubscriptionId -and -not $ManagementGroupId) {
    throw "At least one of -SubscriptionId or -ManagementGroupId is required for: $($needsAzureScope -join ', ')."
}

# ---------------------------------------------------------------------------
# Management group subscription discovery
# ---------------------------------------------------------------------------
function Get-ChildSubscriptions {
    param ([string]$ManagementGroupId)
    $query = "resourcecontainers | where type == 'microsoft.resources/subscriptions'"
    try {
        $subs = Invoke-WithRetry -ScriptBlock {
            Search-AzGraph -Query $query -ManagementGroup $ManagementGroupId -First 1000 -ErrorAction Stop
        }
        return @($subs | Select-Object -ExpandProperty subscriptionId -Unique)
    } catch {
        Write-Warning (Remove-Credentials "Failed to enumerate subscriptions under $ManagementGroupId : $_")
        return @()
    }
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

# ---------------------------------------------------------------------------
# Prerequisite check (manifest-driven auto-installer)
# ---------------------------------------------------------------------------
if (-not $SkipPrereqCheck) {
    $shouldRunRef = { param($name) ShouldRunTool $name }.GetNewClosure()
    $null = Install-PrerequisitesFromManifest `
        -Manifest $manifest `
        -RepoRoot $PSScriptRoot `
        -ShouldRunTool $shouldRunRef `
        -SkipInstall:(-not $InstallMissingModules)
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
Write-Host "=== Azure Analyzer ===" -ForegroundColor Cyan

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
                if ($toolDef.name -eq 'falco') {
                    if ($InstallFalco)  { $params['InstallFalco'] = $true }
                    if ($UninstallFalco) { $params['UninstallFalco'] = $true }
                    $params['CaptureMinutes'] = $FalcoCaptureMinutes
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
                    if (-not $scanTargetUrl -and $ScanPath) { $params['ScanPath'] = $ScanPath }
                    if (-not $scanTargetUrl -and $ScanType) { $params['ScanType'] = $ScanType }
                }
                if ($toolDef.name -eq 'zizmor') {
                    if (-not $scanTargetUrl) {
                        $localPath = if ($RepoPath) { $RepoPath } else { '.' }
                        $params['Repository'] = $localPath
                    }
                }
                if ($toolDef.name -eq 'gitleaks') {
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
# Per-tool aggregation for tool-status.json
$toolAgg = @{}   # toolName → @{ WorstStatus; Messages; Count }

foreach ($wr in $parallelResults) {
    $meta     = $toolMetaMap[$wr.Tool]
    $toolName = if ($meta) { $meta.name } else { $wr.Tool }

    # Initialise aggregation bucket
    if (-not $toolAgg.ContainsKey($toolName)) {
        $toolAgg[$toolName] = @{ WorstStatus = 'Success'; Messages = [System.Collections.Generic.List[string]]::new(); Count = 0 }
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
            $v3Findings = @(& $normFunc -ToolResult $toolResult)
        } catch {
            Write-Warning (Remove-Credentials "Normaliser $normFunc failed: $_")
            $v3Findings = @()
        }
    }

    # Feed v3 findings into EntityStore
    foreach ($finding in $v3Findings) {
        try {
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
                        ResourceGroup  = $finding.ResourceGroup
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
        . $corrScript

        $corrParams = @{ EntityStore = $store; TenantId = ($TenantId ?? 'unknown') }
        if ($corrDef.optionalParams -contains 'IncludeGraphLookup') {
            $mgCmd = Get-Command -Name 'Get-MgApplication' -ErrorAction SilentlyContinue
            if ($mgCmd) { $corrParams['IncludeGraphLookup'] = $true }
        }

        $corrFindings = @(Invoke-IdentityCorrelation @corrParams)

        # Feed correlation findings into EntityStore and flat results
        $corrNormFunc = $corrDef.normalizer
        $corrV3 = $corrFindings
        if ($corrNormFunc -and (Get-Command $corrNormFunc -ErrorAction SilentlyContinue)) {
            $corrToolResult = [PSCustomObject]@{ Status = 'Success'; Findings = $corrFindings }
            $corrV3 = @(& $corrNormFunc -ToolResult $corrToolResult)
        }

        foreach ($finding in $corrV3) {
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
            })
        }

        Write-Host "  $corrName`: $($corrV3.Count) correlation finding(s)" -ForegroundColor Gray
        $toolStatus.Add([PSCustomObject]@{ Tool = $corrName; Status = 'Success'; Message = "Emitted $($corrV3.Count) correlation finding(s)"; Findings = $corrV3.Count })
    } catch {
        $errMsg = Remove-Credentials "$_"
        Write-Warning "Correlator $corrName failed: $errMsg"
        $toolStatus.Add([PSCustomObject]@{ Tool = $corrName; Status = 'Failed'; Message = $errMsg; Findings = 0 })
    }
}

# ---------------------------------------------------------------------------
# Write output
# ---------------------------------------------------------------------------
try {
    if (-not (Test-Path $OutputPath)) {
        $null = New-Item -ItemType Directory -Path $OutputPath -Force
    }

    # v1-compatible flat findings (backward compat for reports)
    $outputFile = Join-Path $OutputPath 'results.json'
    $resultsJson = if ($allResults.Count -eq 0) { '[]' } else { $allResults | ConvertTo-Json -Depth 5 }
    Set-Content -Path $outputFile -Value $resultsJson -Encoding UTF8

    # v3 entity-centric output
    $entitiesFile = Join-Path $OutputPath 'entities.json'
    $entities = Export-Entities -Store $store
    if ($null -eq $entities) { $entities = @() }
    $entitiesJson = if (@($entities).Count -eq 0) { '[]' } else { $entities | ConvertTo-Json -Depth 30 }
    Set-Content -Path $entitiesFile -Value $entitiesJson -Encoding UTF8

    # Tool status
    $statusFile = Join-Path $OutputPath 'tool-status.json'
    $toolStatus | ConvertTo-Json -Depth 3 | Set-Content -Path $statusFile -Encoding UTF8

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
        $triageResult = & (Join-Path $modulesPath 'Invoke-CopilotTriage.ps1') `
            -InputPath $outputFile -OutputPath $triageFile
        if ($null -eq $triageResult) { Write-Warning "AI triage did not produce results." }
    } catch { Write-Warning (Remove-Credentials "AI triage failed: $_ -- continuing without enrichment.") }
} else {
    if (Test-Path $triageFile) { Remove-Item $triageFile -Force -ErrorAction SilentlyContinue }
}
$triageArg = if (Test-Path $triageFile) { @{ TriagePath = $triageFile } } else { @{} }
$prevRunArg = if ($PreviousRun -and (Test-Path $PreviousRun)) { @{ PreviousRun = $PreviousRun } } else { @{} }

# ---------------------------------------------------------------------------
# Generate reports
# ---------------------------------------------------------------------------
$htmlReport = Join-Path $OutputPath 'report.html'
$mdReport   = Join-Path $OutputPath 'report.md'

try {
    & "$PSScriptRoot\New-HtmlReport.ps1" -InputPath $outputFile -OutputPath $htmlReport @triageArg @prevRunArg
} catch {
    Write-Warning (Remove-Credentials "HTML report generation failed: $_")
}

try {
    & "$PSScriptRoot\New-MdReport.ps1" -InputPath $outputFile -OutputPath $mdReport @triageArg
} catch {
    Write-Warning (Remove-Credentials "Markdown report generation failed: $_")
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
