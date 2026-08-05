Set-StrictMode -Version Latest

BeforeAll {
    . "$PSScriptRoot\..\..\modules\shared\WorkerPool.ps1"
    . "$PSScriptRoot\..\..\modules\shared\Schema.ps1"
    . "$PSScriptRoot\..\..\modules\shared\Canonicalize.ps1"
    . "$PSScriptRoot\..\..\modules\shared\Sanitize.ps1"
    . "$PSScriptRoot\..\..\modules\shared\Suppression.ps1"
}

Describe 'WorkerPool module syntax' {
    It 'parses without syntax errors' {
        $path = Join-Path $PSScriptRoot '..\..\modules\shared\WorkerPool.ps1'
        $tokens = $null
        $errors = $null
        [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors) | Out-Null
        @($errors).Count | Should -Be 0
    }
}

Describe 'Invoke-ParallelTools' {
    It 'executes tool scriptblocks in parallel and returns results' {
        $tools = @(
            [PSCustomObject]@{
                Name        = 'tool-a'
                Provider    = 'CLI'
                ScriptBlock = { 'result-a' }
                Arguments   = $null
            },
            [PSCustomObject]@{
                Name        = 'tool-b'
                Provider    = 'CLI'
                ScriptBlock = { 'result-b' }
                Arguments   = $null
            }
        )
        $results = Invoke-ParallelTools -ToolSpecs $tools -MaxParallel 2
        @($results).Count | Should -Be 2
        $results | ForEach-Object { $_.Status | Should -Be 'Success' }
        ($results | Where-Object { $_.Tool -eq 'tool-a' }).Result | Should -Be 'result-a'
    }

    It 'captures tool failures without crashing the pool' {
        $tools = @(
            [PSCustomObject]@{
                Name        = 'good-tool'
                Provider    = 'CLI'
                ScriptBlock = { 'ok' }
                Arguments   = $null
            },
            [PSCustomObject]@{
                Name        = 'bad-tool'
                Provider    = 'CLI'
                ScriptBlock = { throw 'Simulated failure' }
                Arguments   = $null
            }
        )
        $results = Invoke-ParallelTools -ToolSpecs $tools -MaxParallel 2
        @($results).Count | Should -Be 2
        ($results | Where-Object { $_.Tool -eq 'good-tool' }).Status | Should -Be 'Success'
        ($results | Where-Object { $_.Tool -eq 'bad-tool' }).Status | Should -Be 'Failed'
    }

    It 'runs serially in-process when MaxParallel is 1 (module-autoload race workaround)' {
        # In the serial path the scriptblock executes in the CURRENT runspace, so a
        # function defined here is visible to it. Under ForEach-Object -Parallel it would
        # not be, which is exactly the autoload race this path exists to avoid.
        function Get-LocalRunspaceMarker { 'in-process' }
        $tools = @(
            [PSCustomObject]@{
                Name        = 'serial-a'
                Provider    = 'CLI'
                ScriptBlock = { Get-LocalRunspaceMarker }
                Arguments   = $null
            },
            [PSCustomObject]@{
                Name        = 'serial-b'
                Provider    = 'CLI'
                ScriptBlock = { throw 'boom' }
                Arguments   = $null
            }
        )
        $results = Invoke-ParallelTools -ToolSpecs $tools -MaxParallel 1
        @($results).Count | Should -Be 2
        ($results | Where-Object { $_.Tool -eq 'serial-a' }).Status | Should -Be 'Success'
        ($results | Where-Object { $_.Tool -eq 'serial-a' }).Result | Should -Be 'in-process'
        ($results | Where-Object { $_.Tool -eq 'serial-b' }).Status | Should -Be 'Failed'
    }

    It 'serial and parallel paths emit an identical result-object contract' {
        # The serial path mirrors the parallel result object by hand, so the two
        # shapes can drift silently. Downstream the orchestrator reads Tool,
        # Status, Result and Error off both, and a missing member would surface
        # as a StrictMode failure mid-scan rather than here. Pin the contract.
        $spec = {
            param($name)
            [PSCustomObject]@{
                Name        = $name
                Provider    = 'CLI'
                Scope       = 'subscription'
                ScriptBlock = { 'ok' }
                Arguments   = $null
            }
        }

        $serial = @(Invoke-ParallelTools -ToolSpecs @((& $spec 'parity')) -MaxParallel 1)
        $parallel = @(Invoke-ParallelTools -ToolSpecs @((& $spec 'parity')) -MaxParallel 2)

        $serialProps = @($serial[0].PSObject.Properties.Name | Sort-Object)
        $parallelProps = @($parallel[0].PSObject.Properties.Name | Sort-Object)

        $serialProps | Should -Be $parallelProps
        $serialProps | Should -Be @('DurationMs', 'EndTime', 'Error', 'Provider', 'Result', 'Scope', 'StartTime', 'Status', 'Tool')

        # and the values agree for the members the orchestrator actually reads
        $serial[0].Tool     | Should -Be $parallel[0].Tool
        $serial[0].Provider | Should -Be $parallel[0].Provider
        $serial[0].Scope    | Should -Be $parallel[0].Scope
        $serial[0].Status   | Should -Be $parallel[0].Status
        $serial[0].Result   | Should -Be $parallel[0].Result
    }

    It 'serial path tolerates tool specs that omit optional members under StrictMode' {
        # Set-StrictMode -Version Latest is active in the current runspace but does
        # NOT propagate into ForEach-Object -Parallel child runspaces, so the serial
        # path needs explicit PSObject.Properties reads where the parallel path can
        # get away with $tool.Scope on a missing member.
        Set-StrictMode -Version Latest
        $minimal = [PSCustomObject]@{
            Name        = 'minimal'
            ScriptBlock = { 'fine' }
        }
        $results = @(Invoke-ParallelTools -ToolSpecs @($minimal) -MaxParallel 1)
        $results.Count | Should -Be 1
        $results[0].Status   | Should -Be 'Success'
        $results[0].Result   | Should -Be 'fine'
        $results[0].Provider | Should -Be 'Default'
        $results[0].Scope    | Should -Be ''
    }
}

Describe 'New-WorkerSessionState' {
    It 'returns an InitialSessionState' {
        $iss = New-WorkerSessionState -SharedModulesPath (Join-Path $PSScriptRoot '..\..\modules\shared')
        $iss | Should -BeOfType ([System.Management.Automation.Runspaces.InitialSessionState])
    }

    It 'adds startup scripts for shared modules' {
        $sharedPath = Join-Path $PSScriptRoot '..\..\modules\shared'
        $iss = New-WorkerSessionState -SharedModulesPath $sharedPath
        # At least Schema.ps1 and Canonicalize.ps1 should be present.
        $scripts = @($iss.StartupScripts)
        $scripts | Should -Contain (Resolve-Path (Join-Path $sharedPath 'Schema.ps1')).Path
        $scripts | Should -Contain (Resolve-Path (Join-Path $sharedPath 'Canonicalize.ps1')).Path
    }

    It 'does not include WorkerPool.ps1 in startup scripts (avoids recursion)' {
        $sharedPath = Join-Path $PSScriptRoot '..\..\modules\shared'
        $iss = New-WorkerSessionState -SharedModulesPath $sharedPath
        $scripts = @($iss.StartupScripts)
        $scripts | Should -Not -Contain (Resolve-Path (Join-Path $sharedPath 'WorkerPool.ps1')).Path
    }

    It 'injects ErrorActionPreference variable' {
        $iss = New-WorkerSessionState -SharedModulesPath (Join-Path $PSScriptRoot '..\..\modules\shared')
        $vars = @($iss.Variables | Where-Object { $_.Name -eq 'ErrorActionPreference' })
        $vars.Count | Should -BeGreaterThan 0
    }

    It 'honours caller-supplied OrchestratorPreferences over defaults' {
        $iss = New-WorkerSessionState `
            -SharedModulesPath (Join-Path $PSScriptRoot '..\..\modules\shared') `
            -OrchestratorPreferences @{ ErrorActionPreference = 'Continue' }
        $eap = $iss.Variables | Where-Object { $_.Name -eq 'ErrorActionPreference' } | Select-Object -First 1
        $eap.Value | Should -Be 'Continue'
    }
}

Describe 'Invoke-RunspacePoolTools - parallel correctness' {
    # These tests exercise the RunspacePool path directly to verify that
    # (a) results from all tools are returned (no silent dropping), and
    # (b) PSCustomObject properties survive the runspace boundary.

    It 'returns exactly one result per tool spec (no silent finding loss)' {
        # The original autoload-race bug caused silent finding drops.
        # Assert on COUNT as well as Status -- a missing result is a data loss.
        $toolCount = 5
        $tools = 1..$toolCount | ForEach-Object {
            $n = $_
            [PSCustomObject]@{
                Name        = "pool-tool-$n"
                Provider    = 'CLI'
                ScriptBlock = [scriptblock]::Create("'result-$n'")
                Arguments   = $null
            }
        }
        $results = Invoke-RunspacePoolTools -ToolSpecs $tools -MaxParallel 3 `
            -SharedModulesPath (Join-Path $PSScriptRoot '..\..\modules\shared')

        @($results).Count | Should -Be $toolCount -Because 'every tool must produce exactly one result'
        $results | ForEach-Object { $_.Status | Should -Be 'Success' }
    }

    It 'isolates tool failures -- successful tools still return results' {
        $tools = @(
            [PSCustomObject]@{
                Name        = 'good'
                Provider    = 'CLI'
                ScriptBlock = { 'ok' }
                Arguments   = $null
            },
            [PSCustomObject]@{
                Name        = 'bad'
                Provider    = 'CLI'
                ScriptBlock = { throw 'pool-failure' }
                Arguments   = $null
            }
        )
        $results = Invoke-RunspacePoolTools -ToolSpecs $tools -MaxParallel 2 `
            -SharedModulesPath (Join-Path $PSScriptRoot '..\..\modules\shared')

        @($results).Count | Should -Be 2
        ($results | Where-Object { $_.Tool -eq 'good' }).Status | Should -Be 'Success'
        ($results | Where-Object { $_.Tool -eq 'bad' }).Status  | Should -Be 'Failed'
    }

    It 'worker can call Schema.ps1 New-FindingRow without autoload race' {
        # This is the core regression test for #1225. Schema.ps1 is pre-loaded
        # via StartupScripts so New-FindingRow is available in the worker
        # without the orchestrator having to put it in $using: scope.
        # If the autoload race were to recur, New-FindingRow would throw
        # "not recognized" and the tool would return Status=Failed.
        $tools = @(
            [PSCustomObject]@{
                Name        = 'schema-worker-1'
                Provider    = 'CLI'
                ScriptBlock = {
                    $finding = New-FindingRow `
                        -Id           ([guid]::NewGuid().ToString()) `
                        -ProvenanceRunId ([guid]::NewGuid().ToString()) `
                        -Source       'test-tool' `
                        -Severity     'Info' `
                        -EntityType   'Subscription' `
                        -EntityId     '00000000-0000-0000-0000-000000000001' `
                        -Title        'Runspace pool schema test 1' `
                        -Compliant    $false
                    $finding
                }
                Arguments   = $null
            },
            [PSCustomObject]@{
                Name        = 'schema-worker-2'
                Provider    = 'CLI'
                ScriptBlock = {
                    $finding = New-FindingRow `
                        -Id           ([guid]::NewGuid().ToString()) `
                        -ProvenanceRunId ([guid]::NewGuid().ToString()) `
                        -Source       'test-tool' `
                        -Severity     'High' `
                        -EntityType   'Subscription' `
                        -EntityId     '00000000-0000-0000-0000-000000000002' `
                        -Title        'Runspace pool schema test 2' `
                        -Compliant    $false
                    $finding
                }
                Arguments   = $null
            }
        )

        $results = Invoke-RunspacePoolTools -ToolSpecs $tools -MaxParallel 2 `
            -SharedModulesPath (Join-Path $PSScriptRoot '..\..\modules\shared')

        # Assert count: a race-induced command-not-found error would set
        # Status=Failed and empty Result, silently dropping the finding.
        @($results).Count | Should -Be 2 -Because 'both workers must produce a result'
        $results | ForEach-Object {
            $_.Status | Should -Be 'Success' -Because "worker $($_.Tool) must not fail with command-not-recognized"
        }

        # Assert finding properties survive the runspace boundary.
        # PSCustomObject properties can be flattened by some serialisation paths.
        foreach ($r in $results) {
            $findings = @($r.Result)
            $findings.Count | Should -BeGreaterThan 0 -Because 'finding must not be lost in transit'
            $finding = $findings[0]
            $finding.Source      | Should -Be 'test-tool'
            $finding.Compliant   | Should -Be $false
            # Suppressed and FindingKey are set by Apply-Suppression; here we just
            # verify the properties were preserved (not undefined) when present.
            $finding.PSObject.Properties['Title']    | Should -Not -BeNullOrEmpty
            $finding.PSObject.Properties['Severity'] | Should -Not -BeNullOrEmpty
        }
    }

    It 'RunspacePool result object shape matches serial path contract' {
        # Verify the pool path emits the same nine-field contract as the serial path.
        $spec = [PSCustomObject]@{
            Name        = 'contract-check'
            Provider    = 'CLI'
            Scope       = 'subscription'
            ScriptBlock = { 'value' }
            Arguments   = $null
        }
        $poolResult = @(Invoke-RunspacePoolTools -ToolSpecs @($spec) -MaxParallel 1 `
            -SharedModulesPath (Join-Path $PSScriptRoot '..\..\modules\shared'))
        $serialResult = @(Invoke-ParallelTools -ToolSpecs @($spec) -MaxParallel 1)

        $poolProps   = @($poolResult[0].PSObject.Properties.Name | Sort-Object)
        $serialProps = @($serialResult[0].PSObject.Properties.Name | Sort-Object)
        $poolProps | Should -Be $serialProps
        $poolProps | Should -Be @('DurationMs', 'EndTime', 'Error', 'Provider', 'Result', 'Scope', 'StartTime', 'Status', 'Tool')
    }

    It 'Invoke-ParallelTools with -UseRunspacePool routes to the pool path' {
        $tools = @(
            [PSCustomObject]@{
                Name        = 'rp-routed'
                Provider    = 'CLI'
                ScriptBlock = { 'via-pool' }
                Arguments   = $null
            }
        )
        $results = Invoke-ParallelTools -ToolSpecs $tools -MaxParallel 2 -UseRunspacePool
        @($results).Count | Should -Be 1
        $results[0].Status | Should -Be 'Success'
        # Result is wrapped in an array by the pool path
        @($results[0].Result)[0] | Should -Be 'via-pool'
    }

    It 'AZURE_ANALYZER_USE_RUNSPACE_POOL env var activates pool path' {
        try {
            $env:AZURE_ANALYZER_USE_RUNSPACE_POOL = '1'
            $tools = @(
                [PSCustomObject]@{
                    Name        = 'env-routed'
                    Provider    = 'CLI'
                    ScriptBlock = { 'via-env' }
                    Arguments   = $null
                }
            )
            $results = Invoke-ParallelTools -ToolSpecs $tools -MaxParallel 2
            @($results).Count | Should -Be 1
            $results[0].Status | Should -Be 'Success'
        } finally {
            Remove-Item Env:\AZURE_ANALYZER_USE_RUNSPACE_POOL -ErrorAction SilentlyContinue
        }
    }

    It 'AZURE_ANALYZER_MAX_PARALLEL=1 forces serial even with -UseRunspacePool' {
        # The #1218 env gate takes precedence over -UseRunspacePool.
        try {
            $env:AZURE_ANALYZER_MAX_PARALLEL = '1'
            function Get-SerialMarkerForPoolTest { 'in-process-marker' }
            $tools = @(
                [PSCustomObject]@{
                    Name        = 'forced-serial'
                    Provider    = 'CLI'
                    ScriptBlock = { Get-SerialMarkerForPoolTest }
                    Arguments   = $null
                }
            )
            # With MaxParallel forced to 1, the serial in-process path runs.
            # Get-SerialMarkerForPoolTest is defined in this runspace and would
            # not be visible in a real worker runspace.
            $results = Invoke-ParallelTools -ToolSpecs $tools -MaxParallel 2 -UseRunspacePool
            @($results).Count | Should -Be 1
            $results[0].Status | Should -Be 'Success'
            $results[0].Result | Should -Be 'in-process-marker'
        } finally {
            $env:AZURE_ANALYZER_MAX_PARALLEL = $null
            Remove-Item Env:\AZURE_ANALYZER_MAX_PARALLEL -ErrorAction SilentlyContinue
        }
    }
}