#Requires -Version 7.4
<#
.SYNOPSIS
    Runs tool scriptblocks with bounded, per-provider parallelism.
.DESCRIPTION
    Provides three execution paths:

    1. Serial (default and guaranteed-correct fallback): runs in the current
       runspace via a plain foreach loop. Used when MaxParallel <= 1.

    2. RunspacePool (opt-in safe parallel): builds a RunspacePool from an
       [InitialSessionState]::CreateDefault() that pre-loads all shared modules
       via StartupScripts before any worker code runs. This eliminates the
       module-autoload race that caused silent finding loss (#1218). Activated
       by -UseRunspacePool switch or $env:AZURE_ANALYZER_USE_RUNSPACE_POOL = 1.

    3. ForEach-Object -Parallel (legacy fallback): retained for backward
       compatibility when MaxParallel > 1 but -UseRunspacePool is not set.
       Known to have autoload races; prefer the RunspacePool path instead.

    Env gate from #1218 is unchanged: AZURE_ANALYZER_MAX_PARALLEL=1 forces
    serial execution regardless of other flags.
.PARAMETER ToolSpecs
    Collection of tool specs. Each spec should include:
    - Name (string)
    - Provider (string)
    - Scope (string, optional)
    - ScriptBlock (scriptblock)
    - Arguments (hashtable or object[], optional)
.PARAMETER ProviderConcurrencyLimits
    Hashtable of per-provider concurrency caps (e.g. @{ Graph = 4; ADO = 2 }).
.PARAMETER DefaultConcurrency
    Concurrency cap used when a provider does not have an explicit limit.
.PARAMETER MaxParallel
    Overall parallelism cap for the worker pool. Defaults to the sum of all
    provider limits, or 1 if no limits are supplied.
.PARAMETER UseRunspacePool
    When present, use the InitialSessionState-provisioned runspace pool for
    safe parallel execution. Also activated by
    $env:AZURE_ANALYZER_USE_RUNSPACE_POOL = 1.
#>
[CmdletBinding()]
param ()

Set-StrictMode -Version Latest

# ---------------------------------------------------------------------------
# Build an InitialSessionState that pre-loads every shared module as a startup
# script. Startup scripts run once per runspace before any user code, so all
# functions defined in those scripts are available to worker scriptblocks
# without relying on module autoloading.
#
# StartupScripts (not ImportPSModule) is the right API for .ps1 script files.
# ImportPSModule is for .psm1 modules and module manifests; calling it on a
# .ps1 file will not import the functions it defines into the session.
#
# StrictMode and preference variables are injected via SessionStateVariableEntry
# so workers behave identically to the orchestrator runspace.
# ---------------------------------------------------------------------------
function New-WorkerSessionState {
    <#
    .SYNOPSIS
        Builds a fully-provisioned InitialSessionState for worker runspaces.
    .DESCRIPTION
        All *.ps1 files under modules/shared/ (except WorkerPool.ps1 itself)
        are added as StartupScripts so workers start with every shared function
        defined. Preference variables and Set-StrictMode are injected as session
        variables so StrictMode differences between the orchestrator and a
        worker cannot produce latent load-order bugs.
    .PARAMETER SharedModulesPath
        Absolute path to the shared modules directory. Defaults to the
        modules/shared folder co-located with this script.
    .PARAMETER OrchestratorPreferences
        Hashtable of preference variable names to values, e.g.
        @{ ErrorActionPreference = 'Stop' }. Merged over the defaults below.
    #>
    [CmdletBinding()]
    [OutputType([System.Management.Automation.Runspaces.InitialSessionState])]
    param (
        [string]    $SharedModulesPath       = '',
        [hashtable] $OrchestratorPreferences = @{}
    )

    # Walk up two levels from modules/shared/WorkerPool.ps1 to the repo root.
    if (-not $SharedModulesPath) {
        $repoRoot          = Split-Path (Split-Path $PSCommandPath -Parent) -Parent
        $SharedModulesPath = Join-Path $repoRoot 'modules' 'shared'
    }

    # CreateDefault() gives a full session with all built-in commands.
    # Do NOT use CreateDefault2() -- that is the constrained/minimal JEA state.
    $iss = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()

    # Collect all shared *.ps1 files, excluding this file to avoid recursion.
    $thisFile   = $PSCommandPath
    $scriptFiles = Get-ChildItem -Path $SharedModulesPath -Filter '*.ps1' -File -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -ne $thisFile } |
        Select-Object -ExpandProperty FullName

    # Add each script as a StartupScript. StartupScripts run in the runspace
    # session before it is returned from the pool, so all functions and
    # variables they define are available to subsequent worker code.
    foreach ($scriptFile in $scriptFiles) {
        [void]$iss.StartupScripts.Add($scriptFile)
    }

    # Inject preference variables so workers start with the same error-handling
    # and output behaviour as the orchestrator. Without this, a worker running
    # under SilentlyContinue could swallow errors that would be terminating in
    # the orchestrator, producing silent bugs that only surface under load.
    $defaultPrefs = [ordered]@{
        ErrorActionPreference  = 'Stop'
        WarningPreference      = 'Continue'
        VerbosePreference      = 'SilentlyContinue'
        DebugPreference        = 'SilentlyContinue'
        InformationPreference  = 'SilentlyContinue'
        ProgressPreference     = 'SilentlyContinue'
    }
    foreach ($pref in $defaultPrefs.GetEnumerator()) {
        $value = if ($OrchestratorPreferences.ContainsKey($pref.Key)) {
            $OrchestratorPreferences[$pref.Key]
        } else {
            $pref.Value
        }
        $varEntry = [System.Management.Automation.Runspaces.SessionStateVariableEntry]::new(
            $pref.Key, $value, ''
        )
        [void]$iss.Variables.Add($varEntry)
    }

    return $iss
}

# ---------------------------------------------------------------------------
# Execute ToolSpecs via an explicit RunspacePool provisioned by
# New-WorkerSessionState. Uses PowerShell.BeginInvoke/EndInvoke (not
# ForEach-Object -Parallel) so the full PSCustomObject graph -- including
# Suppressed, FindingKey, and SuppressionReason properties added by
# Suppression.ps1 (#1229) -- is preserved across the runspace boundary.
# ForEach-Object -Parallel uses a different serialisation path that can
# flatten nested PSCustomObject properties.
# ---------------------------------------------------------------------------
function Invoke-RunspacePoolTools {
    <#
    .SYNOPSIS
        Executes tool scriptblocks via a pre-provisioned RunspacePool.
    .DESCRIPTION
        Builds a RunspacePool from the InitialSessionState returned by
        New-WorkerSessionState. Each tool gets its own PowerShell instance
        launched asynchronously. Results are collected via EndInvoke after all
        tools have been launched, providing bounded parallelism without the
        autoload races of ForEach-Object -Parallel.
    .PARAMETER ToolSpecs
        Tool specification objects.
    .PARAMETER MaxParallel
        Maximum number of concurrent runspaces in the pool.
    .PARAMETER SharedModulesPath
        Forwarded to New-WorkerSessionState.
    .PARAMETER OrchestratorPreferences
        Forwarded to New-WorkerSessionState.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [PSCustomObject[]] $ToolSpecs,

        [ValidateRange(1, 512)]
        [int] $MaxParallel = 4,

        [string]    $SharedModulesPath       = '',
        [hashtable] $OrchestratorPreferences = @{}
    )

    $iss  = New-WorkerSessionState -SharedModulesPath       $SharedModulesPath `
                                    -OrchestratorPreferences $OrchestratorPreferences
    $pool = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspacePool(
        1, [Math]::Max(1, $MaxParallel), $iss, $Host
    )
    $pool.Open()

    try {
        # Worker script: Set-StrictMode is injected here too (belt-and-suspenders)
        # because StartupScripts run Set-StrictMode per-script but the session-level
        # enforcement needs to be explicit in the worker invocation as well.
        $workerScript = {
            param($ToolScriptBlock, $ToolArguments, $ToolName)
            Set-StrictMode -Version Latest
            if ($ToolScriptBlock -isnot [scriptblock]) {
                throw "Tool '$ToolName' does not provide a ScriptBlock."
            }
            if ($ToolArguments -is [hashtable]) {
                & $ToolScriptBlock @ToolArguments
            } elseif ($ToolArguments -is [object[]]) {
                & $ToolScriptBlock @ToolArguments
            } elseif ($null -ne $ToolArguments) {
                & $ToolScriptBlock $ToolArguments
            } else {
                & $ToolScriptBlock
            }
        }

        # StrictMode-safe property reader -- same helper used in the serial path.
        $getProp = {
            param($obj, $name)
            if ($obj -and $obj.PSObject.Properties[$name]) {
                $obj.PSObject.Properties[$name].Value
            } else { $null }
        }

        # Launch all tools asynchronously.
        $handles = [System.Collections.Generic.List[hashtable]]::new()
        foreach ($tool in $ToolSpecs) {
            $toolName  = (& $getProp $tool 'Name') ?? (& $getProp $tool 'Tool') ?? (& $getProp $tool 'Source') ?? 'unknown'
            $provider  = (& $getProp $tool 'Provider') ?? 'Default'
            $scope     = (& $getProp $tool 'Scope') ?? ''
            $sb        = & $getProp $tool 'ScriptBlock'
            $toolArgs  = & $getProp $tool 'Arguments'
            $startTime = Get-Date

            $ps              = [System.Management.Automation.PowerShell]::Create()
            $ps.RunspacePool = $pool
            $null = $ps.AddScript($workerScript).AddParameters(@{
                ToolScriptBlock = $sb
                ToolArguments   = $toolArgs
                ToolName        = $toolName
            })

            $stopwatch   = [System.Diagnostics.Stopwatch]::StartNew()
            $asyncResult = $ps.BeginInvoke()

            $handles.Add(@{
                PS          = $ps
                AsyncResult = $asyncResult
                Stopwatch   = $stopwatch
                ToolName    = $toolName
                Provider    = $provider
                Scope       = $scope
                StartTime   = $startTime
            })
        }

        # Collect results. EndInvoke blocks per handle until the runspace finishes.
        # PSCustomObject properties (Suppressed, FindingKey, SuppressionReason) are
        # preserved because in-process runspaces do not deserialise PSObjects --
        # the reference passes through the shared AppDomain intact.
        $results = foreach ($h in $handles) {
            $status       = 'Success'
            $errorMessage = ''
            $output       = $null
            try {
                $rawOutput = $h.PS.EndInvoke($h.AsyncResult)
                $output    = @($rawOutput)
                if ($h.PS.Streams.Error.Count -gt 0) {
                    $status       = 'Failed'
                    $errorMessage = ($h.PS.Streams.Error | ForEach-Object { $_.ToString() }) -join '; '
                }
            } catch {
                $status       = 'Failed'
                $errorMessage = ($_ | Out-String).Trim()
            } finally {
                $h.Stopwatch.Stop()
                $h.PS.Dispose()
            }

            [PSCustomObject]@{
                Tool       = $h.ToolName
                Provider   = $h.Provider
                Scope      = $h.Scope
                Status     = $status
                StartTime  = $h.StartTime
                EndTime    = Get-Date
                DurationMs = [int]$h.Stopwatch.ElapsedMilliseconds
                Result     = $output
                Error      = $errorMessage
            }
        }

        return @($results)
    } finally {
        $pool.Close()
        $pool.Dispose()
    }
}

function Invoke-ParallelTools {
    <#
    .SYNOPSIS
        Executes tool scriptblocks with bounded concurrency.
    .DESCRIPTION
        Routes to one of three execution paths based on parameters and env vars:

        Serial (MaxParallel <= 1 OR AZURE_ANALYZER_MAX_PARALLEL=1):
            Runs in the current runspace via a plain foreach. Guaranteed
            correct: inherits all loaded modules and StrictMode. This is the
            guaranteed-correct fallback introduced by #1218.

        RunspacePool (opt-in via -UseRunspacePool or
        AZURE_ANALYZER_USE_RUNSPACE_POOL=1):
            Builds a RunspacePool from an InitialSessionState that pre-loads
            all shared modules via StartupScripts. Safe parallel execution
            without autoload races. The AZURE_ANALYZER_MAX_PARALLEL env gate
            takes precedence -- if it is set to 1, serial is always used.

        ForEach-Object -Parallel (legacy default when MaxParallel > 1 and
        neither serial nor RunspacePool applies):
            Retained for backward compatibility. Has known autoload races;
            prefer the RunspacePool path.

    .PARAMETER ToolSpecs
        Tool specification objects describing what to run.
    .PARAMETER ProviderConcurrencyLimits
        Hashtable of provider names to concurrency limits.
    .PARAMETER DefaultConcurrency
        Fallback concurrency limit for unrecognized providers.
    .PARAMETER MaxParallel
        Global throttle limit for the parallel pipeline.
    .PARAMETER UseRunspacePool
        When set, use the InitialSessionState-provisioned RunspacePool path.
        Also activated by $env:AZURE_ANALYZER_USE_RUNSPACE_POOL = 1.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [PSCustomObject[]] $ToolSpecs,

        [hashtable] $ProviderConcurrencyLimits = @{
            Azure  = 8
            Graph  = 4
            ADO    = 2
            GitHub = 1
            CLI    = 4
        },

        [ValidateRange(1, 256)]
        [int] $DefaultConcurrency = 1,

        [ValidateRange(0, 512)]
        [int] $MaxParallel = 0,

        [switch] $UseRunspacePool
    )

    $normalizedLimits = @{}
    foreach ($entry in $ProviderConcurrencyLimits.GetEnumerator()) {
        $limit = [int]$entry.Value
        if ($limit -lt 1) {
            $limit = 1
        }
        $normalizedLimits[$entry.Key] = $limit
    }

    $sumLimits = 0
    if ($normalizedLimits.Count -gt 0) {
        $sumLimits = ($normalizedLimits.Values | Measure-Object -Sum).Sum
    }

    if ($MaxParallel -le 0) {
        $MaxParallel = [Math]::Max(1, [int]$sumLimits)
    }

    # AZURE_ANALYZER_MAX_PARALLEL env gate from #1218: when set to '1', force
    # serial regardless of any other flags. Do not rename or remove this gate.
    if ($env:AZURE_ANALYZER_MAX_PARALLEL -eq '1') {
        $MaxParallel = 1
    }

    $providerSemaphores = @{}
    foreach ($entry in $normalizedLimits.GetEnumerator()) {
        $providerSemaphores[$entry.Key] = [System.Threading.SemaphoreSlim]::new($entry.Value, $entry.Value)
    }

    $defaultSemaphore = [System.Threading.SemaphoreSlim]::new($DefaultConcurrency, $DefaultConcurrency)

    # Serial path: when MaxParallel<=1, execute in the CURRENT runspace (not
    # ForEach-Object -Parallel). Child parallel runspaces do not reliably
    # autoload modules (Test-Path/Invoke-PSRule/Get-Mg* "not recognized") in
    # some PowerShell 7.x environments; running in-process avoids that entirely.
    if ($MaxParallel -le 1) {
        # StrictMode-safe property read: tool specs may omit optional members
        # (Scope, Provider, Arguments), and Set-StrictMode -Version Latest throws
        # on a missing property rather than returning $null.
        $getProp = {
            param($obj, $name)
            if ($obj -and $obj.PSObject.Properties[$name]) { $obj.PSObject.Properties[$name].Value } else { $null }
        }
        $serialResults = foreach ($tool in $ToolSpecs) {
            $toolName = (& $getProp $tool 'Name') ?? (& $getProp $tool 'Tool') ?? (& $getProp $tool 'Source') ?? 'unknown'
            $provider = (& $getProp $tool 'Provider') ?? 'Default'
            $scope = (& $getProp $tool 'Scope') ?? ''
            $scriptBlock = & $getProp $tool 'ScriptBlock'
            $toolArguments = & $getProp $tool 'Arguments'
            $startTime = Get-Date
            $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
            $status = 'Success'
            $errorMessage = ''
            $output = $null
            try {
                if ($scriptBlock -is [scriptblock]) {
                    if ($toolArguments -is [hashtable]) {
                        $output = & $scriptBlock @toolArguments
                    } elseif ($toolArguments -is [object[]]) {
                        $output = & $scriptBlock @toolArguments
                    } elseif ($null -ne $toolArguments) {
                        $output = & $scriptBlock $toolArguments
                    } else {
                        $output = & $scriptBlock
                    }
                } else {
                    throw "Tool '$toolName' does not provide a ScriptBlock."
                }
            } catch {
                $status = 'Failed'
                $errorMessage = ($_ | Out-String).Trim()
            } finally {
                $stopwatch.Stop()
            }
            [PSCustomObject]@{
                Tool       = $toolName
                Provider   = $provider
                Scope      = $scope
                Status     = $status
                StartTime  = $startTime
                EndTime    = Get-Date
                DurationMs = [int]$stopwatch.ElapsedMilliseconds
                Result     = $output
                Error      = $errorMessage
            }
        }
        return @($serialResults)
    }

    # RunspacePool path: opt-in via -UseRunspacePool switch or env var.
    # Pre-provisions every worker with all shared modules via StartupScripts,
    # eliminating the autoload race that caused silent finding loss (#1218).
    $usePool = $UseRunspacePool.IsPresent -or ($env:AZURE_ANALYZER_USE_RUNSPACE_POOL -eq '1')
    if ($usePool) {
        return Invoke-RunspacePoolTools -ToolSpecs $ToolSpecs -MaxParallel $MaxParallel
    }

    # Legacy ForEach-Object -Parallel path. Retained for backward compatibility
    # but has known autoload races. Use -UseRunspacePool for safe parallelism.
    $results = $ToolSpecs | ForEach-Object -Parallel {
        $providerSemaphores = $using:providerSemaphores
        $defaultSemaphoreLocal = $using:defaultSemaphore
        $tool = $_
        $toolName = $tool.Name ?? $tool.Tool ?? $tool.Source ?? 'unknown'
        $provider = $tool.Provider ?? 'Default'
        $scope = $tool.Scope ?? ''
        $startTime = Get-Date
        $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        $status = 'Success'
        $errorMessage = ''
        $output = $null

        $semaphore = $providerSemaphores[$provider]
        if (-not $semaphore) {
            $semaphore = $defaultSemaphoreLocal
        }

        try {
            $null = $semaphore.Wait()
            if ($tool.ScriptBlock -is [scriptblock]) {
                $toolArguments = $tool.Arguments
                if ($toolArguments -is [hashtable]) {
                    $output = & $tool.ScriptBlock @toolArguments
                } elseif ($toolArguments -is [object[]]) {
                    $output = & $tool.ScriptBlock @toolArguments
                } elseif ($null -ne $toolArguments) {
                    $output = & $tool.ScriptBlock $toolArguments
                } else {
                    $output = & $tool.ScriptBlock
                }
            } else {
                throw "Tool '$toolName' does not provide a ScriptBlock."
            }
        } catch {
            $status = 'Failed'
            $errorMessage = ($_ | Out-String).Trim()
        } finally {
            if ($semaphore) {
                $null = $semaphore.Release()
            }
            $stopwatch.Stop()
        }

        $endTime = Get-Date

        [PSCustomObject]@{
            Tool       = $toolName
            Provider   = $provider
            Scope      = $scope
            Status     = $status
            StartTime  = $startTime
            EndTime    = $endTime
            DurationMs = [int]$stopwatch.ElapsedMilliseconds
            Result     = $output
            Error      = $errorMessage
        }
    } -ThrottleLimit $MaxParallel

    return @($results)
}