#requires -Version 7.0
#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }

<#
.SYNOPSIS
    Tests for Python triage subprocess timeout wrapper in modules/Invoke-CopilotTriage.ps1.
.DESCRIPTION
    Validates that the Python triage subprocess invocation is wrapped with Invoke-WithTimeout
    and emits TimeoutExceeded errors when the subprocess exceeds 300s.
#>

BeforeAll {
    $script:RepoRoot    = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
    $script:ModulePath  = Join-Path $script:RepoRoot 'modules\Invoke-CopilotTriage.ps1'
    $script:SharedDir   = Join-Path $script:RepoRoot 'modules\shared'
    
    # Pre-load shared dependencies so mocks work
    . (Join-Path $script:SharedDir 'Sanitize.ps1')
    . (Join-Path $script:SharedDir 'CliTimeout.ps1')
}

Describe 'Invoke-CopilotTriage Python subprocess timeout wrapper' -Tag 'AllowsWarning' {
    Context 'Python subprocess timeout handling' {
        It 'emits TimeoutExceeded error when Python subprocess exceeds 300s' {
            Mock Invoke-WithTimeout {
                param($Command, $Arguments, $TimeoutSec)
                if ($Command -match 'python' -and $TimeoutSec -eq 300) {
                    return [PSCustomObject]@{
                        ExitCode = -1
                        Output   = 'Timed out after 300 seconds'
                    }
                }
                throw "Unexpected Invoke-WithTimeout call: $Command"
            }
            Mock Test-Path { $true }
            Mock Get-Content { '{}' }
            Mock ConvertFrom-Json { [PSCustomObject]@{} }
            
            $env:COPILOT_GITHUB_TOKEN = 'ghp_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'
            try {
                $result = & $script:ModulePath -InputPath 'input.json' -OutputPath 'output.json'
                $result.Status | Should -Be 'Failed'
                $result.Message | Should -Match 'timed out'
                $result.Errors[0].Category | Should -Be 'TimeoutExceeded'
                $result.Errors[0].Reason | Should -Match 'Python triage subprocess timed out after 300 seconds'
            } finally {
                Remove-Item env:COPILOT_GITHUB_TOKEN -ErrorAction SilentlyContinue
            }
        }

        It 'uses 300s timeout for Python subprocess (standard CLI timeout)' {
            Mock Invoke-WithTimeout {
                param($Command, $Arguments, $TimeoutSec)
                $global:timeoutCaptured = $TimeoutSec
                return [PSCustomObject]@{
                    ExitCode = 0
                    Output   = ''
                }
            }
            Mock Test-Path { $true }
            Mock Get-Content { '{}' }
            Mock ConvertFrom-Json { [PSCustomObject]@{} }
            
            $env:COPILOT_GITHUB_TOKEN = 'ghp_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'
            try {
                $null = & $script:ModulePath -InputPath 'input.json' -OutputPath 'output.json'
                $global:timeoutCaptured | Should -Be 300
            } finally {
                Remove-Item env:COPILOT_GITHUB_TOKEN -ErrorAction SilentlyContinue
                Remove-Variable timeoutCaptured -Scope Global -ErrorAction SilentlyContinue
            }
        }

        It 'returns successful envelope when Python subprocess completes within timeout' {
            Mock Invoke-WithTimeout {
                param($Command, $Arguments, $TimeoutSec)
                return [PSCustomObject]@{
                    ExitCode = 0
                    Output   = 'Triage complete'
                }
            }
            Mock Test-Path {
                param($Path)
                if ($Path -match 'output\.json') { return $true }
                return $true
            }
            Mock Get-Content {
                param($Path)
                if ($Path -match 'output\.json') {
                    return '{"SchemaVersion":"1.0","Findings":[]}'
                }
                return '{}'
            }
            Mock ConvertFrom-Json {
                param([Parameter(ValueFromPipeline)]$InputObject)
                if ($InputObject -match 'SchemaVersion') {
                    return [PSCustomObject]@{ SchemaVersion='1.0'; Findings=@() }
                }
                return [PSCustomObject]@{}
            }
            
            $env:COPILOT_GITHUB_TOKEN = 'ghp_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'
            try {
                $result = & $script:ModulePath -InputPath 'input.json' -OutputPath 'output.json'
                $result.SchemaVersion | Should -Be '1.0'
            } finally {
                Remove-Item env:COPILOT_GITHUB_TOKEN -ErrorAction SilentlyContinue
            }
        }
    }

    Context 'Fallback stub compatibility' {
        It 'wrapper includes Invoke-WithTimeout fallback stub for test compatibility' {
            $content = Get-Content -LiteralPath $script:ModulePath -Raw
            $content | Should -Match 'function Invoke-WithTimeout'
            $content | Should -Match 'if \(-not \(Get-Command Invoke-WithTimeout'
        }
    }
}
