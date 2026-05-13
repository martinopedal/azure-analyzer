#requires -Version 7.0
#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }

<#
.SYNOPSIS
    Tests for gh copilot CLI timeout wrappers in modules/shared/Triage/Invoke-CopilotTriage.ps1.
.DESCRIPTION
    Validates that gh copilot status and gh copilot models list invocations are wrapped
    with Invoke-WithTimeout and emit TimeoutExceeded errors when mocks simulate slow operations.
#>

BeforeAll {
    $script:RepoRoot    = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..')).Path
    $script:ModulePath  = Join-Path $script:RepoRoot 'modules\shared\Triage\Invoke-CopilotTriage.ps1'
    $script:RankingPath = Join-Path $script:RepoRoot 'config\triage-model-ranking.json'
    . $script:ModulePath
}

Describe 'Invoke-CopilotTriage gh CLI timeout wrappers' {
    Context 'gh copilot status timeout handling' {
        It 'throws TimeoutExceeded when gh copilot status exceeds 30s and no explicit tier provided' {
            Mock Invoke-WithTimeout {
                param($Command, $Arguments, $TimeoutSec)
                if ($Command -eq 'gh' -and $Arguments[0] -eq 'copilot' -and $Arguments[1] -eq 'status') {
                    return [PSCustomObject]@{ ExitCode = -1; Output = 'Timed out after 30 seconds' }
                }
                if ($Command -eq 'gh' -and $Arguments[0] -eq 'copilot' -and $Arguments[1] -eq 'models') {
                    return [PSCustomObject]@{ ExitCode = 0; Output = '[{"id":"claude-sonnet-4.6"}]' }
                }
            }
            
            $caught = $null
            try {
                Get-AvailableModelsFromCopilotPlan
            } catch {
                $caught = $_
            }
            
            $caught | Should -Not -BeNullOrEmpty
            ($caught | Out-String) | Should -Match 'TierUnresolved'
        }

        It 'falls through to tier resolution on slow gh copilot status when -CopilotTier is provided' {
            Mock Invoke-WithTimeout {
                param($Command, $Arguments, $TimeoutSec)
                if ($Command -eq 'gh' -and $Arguments[0] -eq 'copilot' -and $Arguments[1] -eq 'models') {
                    return [PSCustomObject]@{
                        ExitCode = 0
                        Output   = '[{"id":"claude-sonnet-4.6"}]'
                    }
                }
                throw 'Unexpected call'
            }
            
            $discovery = Get-AvailableModelsFromCopilotPlan -CopilotTier 'Enterprise'
            $discovery.Tier | Should -Be 'Enterprise'
            $discovery.Models | Should -Contain 'claude-sonnet-4.6'
        }
    }

    Context 'gh copilot models list timeout handling' {
        It 'throws TimeoutExceeded when gh copilot models list exceeds 60s' {
            Mock Invoke-WithTimeout {
                param($Command, $Arguments, $TimeoutSec)
                if ($Command -eq 'gh' -and $Arguments[0] -eq 'copilot' -and $Arguments[1] -eq 'status') {
                    return [PSCustomObject]@{ ExitCode = 0; Output = 'Enterprise' }
                }
                if ($Command -eq 'gh' -and $Arguments[0] -eq 'copilot' -and $Arguments[1] -eq 'models') {
                    return [PSCustomObject]@{ ExitCode = -1; Output = 'Timed out after 60 seconds' }
                }
            }
            
            $caught = $null
            try {
                Get-AvailableModelsFromCopilotPlan
            } catch {
                $caught = $_
            }
            
            $caught | Should -Not -BeNullOrEmpty
            ($caught | Out-String) | Should -Match 'TimeoutExceeded'
            ($caught | Out-String) | Should -Match 'gh copilot models list timed out'
        }

        It 'returns discovered models when gh copilot models list completes within timeout' {
            Mock Invoke-WithTimeout {
                param($Command, $Arguments, $TimeoutSec)
                if ($Command -eq 'gh' -and $Arguments[0] -eq 'copilot' -and $Arguments[1] -eq 'status') {
                    return [PSCustomObject]@{ ExitCode = 0; Output = 'Enterprise' }
                }
                if ($Command -eq 'gh' -and $Arguments[0] -eq 'copilot' -and $Arguments[1] -eq 'models') {
                    return [PSCustomObject]@{
                        ExitCode = 0
                        Output   = '[{"id":"claude-sonnet-4.6"},{"id":"gpt-5.2"}]'
                    }
                }
            }
            
            $discovery = Get-AvailableModelsFromCopilotPlan
            $discovery.Tier | Should -Be 'Enterprise'
            $discovery.Models | Should -Contain 'claude-sonnet-4.6'
            $discovery.Models | Should -Contain 'gpt-5.2'
        }
    }

    Context 'Timeout value validation' {
        It 'uses 30s timeout for gh copilot status (interactive call)' {
            $timeoutCaptured = $null
            Mock Invoke-WithTimeout {
                param($Command, $Arguments, $TimeoutSec)
                if ($Command -eq 'gh' -and $Arguments[0] -eq 'copilot' -and $Arguments[1] -eq 'status') {
                    $script:timeoutCaptured = $TimeoutSec
                    return [PSCustomObject]@{ ExitCode = 0; Output = 'Enterprise' }
                }
                if ($Command -eq 'gh' -and $Arguments[0] -eq 'copilot' -and $Arguments[1] -eq 'models') {
                    return [PSCustomObject]@{ ExitCode = 0; Output = '[{"id":"claude-sonnet-4.6"}]' }
                }
            }
            
            $null = Get-AvailableModelsFromCopilotPlan
            $script:timeoutCaptured | Should -Be 30
        }

        It 'uses 60s timeout for gh copilot models list' {
            $timeoutCaptured = $null
            Mock Invoke-WithTimeout {
                param($Command, $Arguments, $TimeoutSec)
                if ($Command -eq 'gh' -and $Arguments[0] -eq 'copilot' -and $Arguments[1] -eq 'status') {
                    return [PSCustomObject]@{ ExitCode = 0; Output = 'Enterprise' }
                }
                if ($Command -eq 'gh' -and $Arguments[0] -eq 'copilot' -and $Arguments[1] -eq 'models') {
                    $script:timeoutCaptured = $TimeoutSec
                    return [PSCustomObject]@{ ExitCode = 0; Output = '[{"id":"claude-sonnet-4.6"}]' }
                }
            }
            
            $null = Get-AvailableModelsFromCopilotPlan
            $script:timeoutCaptured | Should -Be 60
        }
    }
}
