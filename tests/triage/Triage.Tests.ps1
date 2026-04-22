#requires -Version 7.4
#requires -Modules Pester

Set-StrictMode -Version Latest

BeforeAll {
    $script:ModulePath = Join-Path $PSScriptRoot '..' '..' 'modules' 'shared' 'Triage' 'Invoke-CopilotTriage.ps1'
    $script:RankingPath = Join-Path $PSScriptRoot '..' '..' 'config' 'triage-model-ranking.json'
    . $script:ModulePath
}

Describe 'LLM triage model selection (#433)' {
    Context 'Tier discovery and available models' {
        It 'falls back to -CopilotTier when gh copilot status is unavailable' {
            function global:gh { throw 'unsupported command' }
            try {
                $models = @(Get-AvailableModelsFromCopilotPlan -CopilotTier Business)
                $models | Should -Contain 'gpt-5.2-codex'
                $models | Should -Contain 'gemini-3-pro-preview'
            } finally {
                Remove-Item Function:\global:gh -ErrorAction SilentlyContinue
            }
        }

        It 'requires explicit tier when status is unavailable and no fallback is provided' {
            function global:gh { throw 'unsupported command' }
            try {
                { Get-AvailableModelsFromCopilotPlan } | Should -Throw '*Provide -CopilotTier*'
            } finally {
                Remove-Item Function:\global:gh -ErrorAction SilentlyContinue
            }
        }
    }

    Context 'Trio ranking and provider diversity' {
        It 'prefers top-ranked available models from ranking config' {
            $ranking = Get-Content -Path $script:RankingPath -Raw -Encoding utf8 | ConvertFrom-Json
            $trio = @(Select-TriageTrio -AvailableModels @(
                    'claude-sonnet-4.6',
                    'gpt-5.2',
                    'gemini-3-pro-preview',
                    'claude-haiku-4.5'
                ) -RankingTable $ranking)

            $trio.Count | Should -Be 3
            $trio | Should -Contain 'claude-sonnet-4.6'
            $trio | Should -Contain 'gpt-5.2'
            $trio | Should -Contain 'gemini-3-pro-preview'
        }

        It 'uses provider diversity as tie-break when total rank is equal' {
            $ranking = [pscustomobject]@{
                rankings = @(
                    [pscustomobject]@{ model = 'a-1'; rank = 100; provider = 'anthropic' },
                    [pscustomobject]@{ model = 'a-2'; rank = 90; provider = 'anthropic' },
                    [pscustomobject]@{ model = 'o-1'; rank = 90; provider = 'openai' },
                    [pscustomobject]@{ model = 'g-1'; rank = 90; provider = 'google' }
                )
            }
            $trio = @(Select-TriageTrio -AvailableModels @('a-1', 'a-2', 'o-1', 'g-1') -RankingTable $ranking)

            $trio | Should -Contain 'a-1'
            $trio | Should -Contain 'o-1'
            $trio | Should -Contain 'g-1'
            $trio | Should -Not -Contain 'a-2'
        }
    }

    Context 'Invoke-CopilotTriage mode behavior' {
        It 'warns when -SingleModel opts out of rubberduck' {
            function global:gh { throw 'unsupported command' }
            try {
                $warnings = $null
                $result = Invoke-CopilotTriage `
                    -Findings @([pscustomobject]@{ Id = 'f1'; Title = 'x' }) `
                    -CopilotTier Pro `
                    -SingleModel `
                    -WarningVariable warnings

                $result.Mode | Should -Be 'SingleModel'
                @($warnings).Count | Should -BeGreaterThan 0
                (@($warnings) -join ' ') | Should -Match 'opting out of default rubberduck consensus'
            } finally {
                Remove-Item Function:\global:gh -ErrorAction SilentlyContinue
            }
        }

        It 'refuses explicit model not in resolved tier roster' {
            function global:gh { throw 'unsupported command' }
            try {
                {
                    Invoke-CopilotTriage `
                        -Findings @([pscustomobject]@{ Id = 'f1'; Title = 'x' }) `
                        -CopilotTier Pro `
                        -ExplicitModel 'claude-opus-4.6'
                } | Should -Throw '*not available for this Copilot tier*'
            } finally {
                Remove-Item Function:\global:gh -ErrorAction SilentlyContinue
            }
        }

        It 'refuses rubberduck mode when fewer than three models are available' {
            function global:gh { "Plan: Pro`nModels: gpt-5.2, gpt-4.1" }
            try {
                {
                    Invoke-CopilotTriage -Findings @([pscustomobject]@{ Id = 'f1'; Title = 'x' })
                } | Should -Throw '*requires at least three available models*'
            } finally {
                Remove-Item Function:\global:gh -ErrorAction SilentlyContinue
            }
        }

        It 'allows single-model fallback when fewer than three models are available and -SingleModel is set' {
            function global:gh { "Plan: Pro`nModels: gpt-5.2, gpt-4.1" }
            try {
                $warnings = $null
                $result = Invoke-CopilotTriage `
                    -Findings @([pscustomobject]@{ Id = 'f1'; Title = 'x' }) `
                    -SingleModel `
                    -WarningVariable warnings
                $result.Mode | Should -Be 'SingleModel'
                $result.SelectedModels.Count | Should -Be 1
                @($warnings).Count | Should -BeGreaterThan 0
            } finally {
                Remove-Item Function:\global:gh -ErrorAction SilentlyContinue
            }
        }
    }
}
