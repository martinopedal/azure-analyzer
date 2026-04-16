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
}
