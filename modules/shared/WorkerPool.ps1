#Requires -Version 7.4
<#
.SYNOPSIS
    Runs tool scriptblocks with bounded, per-provider parallelism.
.DESCRIPTION
    Executes tool scriptblocks using PowerShell 7 parallel pipelines with a
    configurable per-provider concurrency cap. Each tool runs in its own
    try/catch so failures are isolated and do not halt the batch.
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
#>
[CmdletBinding()]
param ()

Set-StrictMode -Version Latest

function Invoke-ParallelTools {
    <#
    .SYNOPSIS
        Executes tool scriptblocks with bounded concurrency.
    .DESCRIPTION
        Uses ForEach-Object -Parallel with a global throttle limit and
        per-provider semaphores to keep concurrency within configured caps.
        Each tool returns a result object with timing metadata and error state.
    .PARAMETER ToolSpecs
        Tool specification objects describing what to run.
    .PARAMETER ProviderConcurrencyLimits
        Hashtable of provider names to concurrency limits.
    .PARAMETER DefaultConcurrency
        Fallback concurrency limit for unrecognized providers.
    .PARAMETER MaxParallel
        Global throttle limit for the parallel pipeline.
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
        [int] $MaxParallel = 0
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

    $providerSemaphores = @{}
    foreach ($entry in $normalizedLimits.GetEnumerator()) {
        $providerSemaphores[$entry.Key] = [System.Threading.SemaphoreSlim]::new($entry.Value, $entry.Value)
    }

    $defaultSemaphore = [System.Threading.SemaphoreSlim]::new($DefaultConcurrency, $DefaultConcurrency)

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
