#Requires -Version 7.4

<#
.SYNOPSIS
    Pester tests for modules/shared/CliTimeout.ps1.

.DESCRIPTION
    Validates Invoke-WithTimeout's two execution paths:
    1. CommandType=Application (real executable) -> System.Diagnostics.Process,
       hard timeout, sanitized stdout/stderr.
    2. CommandType=Function (Pester mock) -> call-operator fallback,
       sanitized output.

    Tests intentionally avoid long real-process sleeps (>2s) to stay fast.
#>

BeforeAll {
    . (Join-Path $PSScriptRoot '..\..\modules\shared\Sanitize.ps1')
    . (Join-Path $PSScriptRoot '..\..\modules\shared\CliTimeout.ps1')
}

Describe 'Invoke-WithTimeout (CliTimeout.ps1)' {

    Context 'PowerShell function fallback (test mock path)' {

        It 'returns ExitCode and Output from a function' {
            function script:Test-FakeCli { param([string]$arg) 'hello'; $global:LASTEXITCODE = 0 }
            try {
                $result = Invoke-WithTimeout -Command 'Test-FakeCli' -Arguments @('noop') -TimeoutSec 5
                $result.ExitCode | Should -Be 0
                $result.Output   | Should -Match 'hello'
                $result.Stdout   | Should -Match 'hello'
                $result.Stderr   | Should -Be ''
            } finally {
                Remove-Item function:Test-FakeCli -ErrorAction SilentlyContinue
            }
        }

        It 'sanitizes credential-shaped tokens in output (Bug fix: mock path now sanitizes)' {
            function script:Test-LeakyCli { param([string]$arg) 'header Authorization: Bearer ghp_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA' }
            try {
                $result = Invoke-WithTimeout -Command 'Test-LeakyCli' -Arguments @('noop') -TimeoutSec 5
                # The token should be redacted by Remove-Credentials
                $result.Output | Should -Not -Match 'ghp_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'
                $result.Stdout | Should -Not -Match 'ghp_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'
            } finally {
                Remove-Item function:Test-LeakyCli -ErrorAction SilentlyContinue
            }
        }

        It 'forwards positional Arguments to the function' {
            function script:Test-EchoCli { param([string]$first,[string]$second) "$first|$second"; $global:LASTEXITCODE = 0 }
            try {
                $result = Invoke-WithTimeout -Command 'Test-EchoCli' -Arguments @('alpha','beta') -TimeoutSec 5
                $result.Output | Should -Match 'alpha\|beta'
            } finally {
                Remove-Item function:Test-EchoCli -ErrorAction SilentlyContinue
            }
        }

        It 'propagates LASTEXITCODE from function failures' {
            function script:Test-FailingCli { param([string]$arg) 'oops'; $global:LASTEXITCODE = 7 }
            try {
                $result = Invoke-WithTimeout -Command 'Test-FailingCli' -Arguments @('noop') -TimeoutSec 5
                $result.ExitCode | Should -Be 7
            } finally {
                Remove-Item function:Test-FailingCli -ErrorAction SilentlyContinue
            }
        }
    }

    Context 'Real executable path (System.Diagnostics.Process)' {

        It 'returns ExitCode 0 and captured stdout for a fast process' {
            $pwshExe = (Get-Command pwsh -CommandType Application -ErrorAction SilentlyContinue).Source
            if (-not $pwshExe) { Set-ItResult -Skipped -Because 'pwsh not on PATH'; return }
            $result = Invoke-WithTimeout -Command 'pwsh' -Arguments @('-NoProfile', '-Command', 'Write-Output ready') -TimeoutSec 30
            $result.ExitCode | Should -Be 0
            $result.Stdout   | Should -Match 'ready'
        }

        It 'returns ExitCode -1 and timeout marker when the process exceeds TimeoutSec' {
            $pwshExe = (Get-Command pwsh -CommandType Application -ErrorAction SilentlyContinue).Source
            if (-not $pwshExe) { Set-ItResult -Skipped -Because 'pwsh not on PATH'; return }
            # Sleep 5s with a 1s timeout, expect the process to be killed.
            $result = Invoke-WithTimeout -Command 'pwsh' -Arguments @('-NoProfile', '-Command', 'Start-Sleep -Seconds 5') -TimeoutSec 1
            $result.ExitCode | Should -Be -1
            $result.Output   | Should -Match 'Timed out'
            $result.Stderr   | Should -Match 'Timed out'
        }

        It 'sanitizes credential-shaped tokens written to stdout by the process' {
            $pwshExe = (Get-Command pwsh -CommandType Application -ErrorAction SilentlyContinue).Source
            if (-not $pwshExe) { Set-ItResult -Skipped -Because 'pwsh not on PATH'; return }
            $result = Invoke-WithTimeout -Command 'pwsh' -Arguments @('-NoProfile', '-Command', "Write-Output 'Authorization: Bearer ghp_BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB'") -TimeoutSec 30
            $result.Stdout | Should -Not -Match 'ghp_BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB'
            $result.Output | Should -Not -Match 'ghp_BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB'
        }
    }
}
