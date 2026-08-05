Set-StrictMode -Version Latest

BeforeAll {
    . "$PSScriptRoot\..\..\modules\shared\WorkerPool.ps1"
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
