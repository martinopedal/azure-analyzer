Set-StrictMode -Version Latest

Describe 'WorkerPool module syntax' {
    It 'parses without syntax errors' {
        $path = Join-Path $PSScriptRoot '..\..\modules\shared\WorkerPool.ps1'
        $tokens = $null
        $errors = $null
        [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors) | Out-Null
        @($errors).Count | Should -Be 0
    }
}
