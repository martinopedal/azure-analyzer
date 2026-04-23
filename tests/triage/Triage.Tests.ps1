#requires -Version 7.4
#requires -Modules Pester

Set-StrictMode -Version Latest

BeforeAll {
    $script:ModulePath = Join-Path $PSScriptRoot '..' '..' 'modules' 'shared' 'Triage' 'Invoke-CopilotTriage.ps1'
    $script:RankingPath = Join-Path $PSScriptRoot '..' '..' 'config' 'triage-model-ranking.json'
    . $script:ModulePath
}

Describe 'LLM triage model selection (#433)' {
    Context 'Tier and model discovery' {
        It 'discovers available models from gh copilot models list' {
            function global:gh {
                param([Parameter(ValueFromRemainingArguments = $true)][string[]] $Args)
                $cmd = ($Args -join ' ')
                $global:LASTEXITCODE = 0
                if ($cmd -eq 'copilot status') { return "Plan: Business`nUser: octocat" }
                if ($cmd -eq 'copilot models list --json id') {
                    return '[{"id":"claude-sonnet-4.6"},{"id":"gpt-5.2"},{"id":"gemini-3-pro-preview"}]'
                }
                throw "unexpected gh call: $cmd"
            }
            try {
                $discovery = Get-AvailableModelsFromCopilotPlan
                $discovery.Tier | Should -Be 'Business'
                $models = @($discovery.Models)
                $models | Should -Contain 'claude-sonnet-4.6'
                $models | Should -Contain 'gpt-5.2'
                $models | Should -Contain 'gemini-3-pro-preview'
            } finally {
                Remove-Item Function:\global:gh -ErrorAction SilentlyContinue
            }
        }

        It 'requires explicit tier when gh copilot status is unavailable' {
            function global:gh { throw 'unsupported command' }
            try {
                { Get-AvailableModelsFromCopilotPlan } | Should -Throw
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
                    'gpt-4.1'
                ) -RankingTable $ranking)

            $trio.Count | Should -Be 3
            $trio | Should -Contain 'claude-sonnet-4.6'
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

    Context 'Fallback chain' {
        It 'returns ranked available models in descending order' {
            $ranking = Get-Content -Path $script:RankingPath -Raw -Encoding utf8 | ConvertFrom-Json
            $chain = @(Get-FrontierFallbackChain -AvailableModels @('claude-sonnet-4.6', 'gpt-5.2', 'gpt-4.1') -RankingTable $ranking)
            $chain[0] | Should -Be 'claude-sonnet-4.6'
            $chain[-1] | Should -Be 'gpt-4.1'
        }
    }

    Context 'Invoke-CopilotTriage mode behavior' {
        It 'warns when -SingleModel opts out of rubberduck' {
            function global:gh {
                param([Parameter(ValueFromRemainingArguments = $true)][string[]] $Args)
                $cmd = ($Args -join ' ')
                $global:LASTEXITCODE = 0
                if ($cmd -eq 'copilot models list --json id') { return '[{"id":"claude-sonnet-4.6"},{"id":"gpt-5.2"},{"id":"gemini-3-pro-preview"}]' }
                throw "unexpected gh call: $cmd"
            }
            try {
                $warnings = $null
                $result = Invoke-CopilotTriage `
                    -Findings @([pscustomobject]@{ Id = 'f1'; Title = 'x' }) `
                    -CopilotTier Pro `
                    -SingleModel `
                    -WarningVariable warnings

                $result.Mode | Should -Be 'SingleModel'
                $result.SchemaVersion | Should -Be '1.0'
                @($warnings).Count | Should -BeGreaterThan 0
                (@($warnings) -join ' ') | Should -Match 'opting out of default rubberduck consensus'
            } finally {
                Remove-Item Function:\global:gh -ErrorAction SilentlyContinue
            }
        }

        It 'refuses explicit model not in resolved roster' {
            function global:gh {
                param([Parameter(ValueFromRemainingArguments = $true)][string[]] $Args)
                $cmd = ($Args -join ' ')
                $global:LASTEXITCODE = 0
                if ($cmd -eq 'copilot models list --json id') { return '[{"id":"claude-sonnet-4.6"},{"id":"gpt-5.2"},{"id":"gemini-3-pro-preview"}]' }
                throw "unexpected gh call: $cmd"
            }
            try {
                {
                    Invoke-CopilotTriage `
                        -Findings @([pscustomobject]@{ Id = 'f1'; Title = 'x' }) `
                        -CopilotTier Pro `
                        -TriageModel 'Explicit:claude-opus-4.7'
                } | Should -Throw
            } finally {
                Remove-Item Function:\global:gh -ErrorAction SilentlyContinue
            }
        }

        It 'supports explicit model when present in roster' {
            function global:gh {
                param([Parameter(ValueFromRemainingArguments = $true)][string[]] $Args)
                $cmd = ($Args -join ' ')
                $global:LASTEXITCODE = 0
                if ($cmd -eq 'copilot models list --json id') { return '[{"id":"claude-sonnet-4.6"},{"id":"gpt-5.2"},{"id":"gemini-3-pro-preview"}]' }
                throw "unexpected gh call: $cmd"
            }
            try {
                $result = Invoke-CopilotTriage `
                    -Findings @([pscustomobject]@{ Id = 'f1'; Title = 'x' }) `
                    -CopilotTier Pro `
                    -TriageModel 'Explicit:gpt-5.2'
                $result.Mode | Should -Be 'SingleModel'
                $result.SelectedModels.Count | Should -Be 1
                $result.SelectedModels[0] | Should -Be 'gpt-5.2'
            } finally {
                Remove-Item Function:\global:gh -ErrorAction SilentlyContinue
            }
        }

        It 'requires -SingleModel when roster has fewer than three models' {
            function global:gh {
                param([Parameter(ValueFromRemainingArguments = $true)][string[]] $Args)
                $cmd = ($Args -join ' ')
                $global:LASTEXITCODE = 0
                if ($cmd -eq 'copilot models list --json id') { return '[{"id":"gpt-5-mini"},{"id":"gpt-4.1"}]' }
                throw "unexpected gh call: $cmd"
            }
            try {
                { Invoke-CopilotTriage -Findings @([pscustomobject]@{ Id = 'f1'; Title = 'x' }) -CopilotTier Pro } | Should -Throw
            } finally {
                Remove-Item Function:\global:gh -ErrorAction SilentlyContinue
            }
        }

        It 'supports -SingleModel when roster has fewer than three models' {
            function global:gh {
                param([Parameter(ValueFromRemainingArguments = $true)][string[]] $Args)
                $cmd = ($Args -join ' ')
                $global:LASTEXITCODE = 0
                if ($cmd -eq 'copilot models list --json id') { return '[{"id":"gpt-5-mini"},{"id":"gpt-4.1"}]' }
                throw "unexpected gh call: $cmd"
            }
            try {
                $result = Invoke-CopilotTriage -Findings @([pscustomobject]@{ Id = 'f1'; Title = 'x' }) -CopilotTier Pro -SingleModel
                $result.Mode | Should -Be 'SingleModel'
                $result.SelectedModels.Count | Should -Be 1
            } finally {
                Remove-Item Function:\global:gh -ErrorAction SilentlyContinue
            }
        }

        It 'selects rubberduck trio when exactly three models are available' {
            function global:gh {
                param([Parameter(ValueFromRemainingArguments = $true)][string[]] $Args)
                $cmd = ($Args -join ' ')
                $global:LASTEXITCODE = 0
                if ($cmd -eq 'copilot models list --json id') { return '[{"id":"claude-sonnet-4.6"},{"id":"gpt-5.2"},{"id":"gemini-3-pro-preview"}]' }
                throw "unexpected gh call: $cmd"
            }
            try {
                $result = Invoke-CopilotTriage -Findings @([pscustomobject]@{ Id = 'f1'; Title = 'x' }) -CopilotTier Business
                $result.Mode | Should -Be 'Rubberduck'
                $result.SelectedModels.Count | Should -Be 3
            } finally {
                Remove-Item Function:\global:gh -ErrorAction SilentlyContinue
            }
        }

        It 'emits versioned schema with FallbackChain and GeneratedAt' {
            function global:gh {
                param([Parameter(ValueFromRemainingArguments = $true)][string[]] $Args)
                $cmd = ($Args -join ' ')
                $global:LASTEXITCODE = 0
                if ($cmd -eq 'copilot models list --json id') { return '[{"id":"claude-sonnet-4.6"},{"id":"gpt-5.2"},{"id":"gemini-3-pro-preview"}]' }
                throw "unexpected gh call: $cmd"
            }
            try {
                $result = Invoke-CopilotTriage -Findings @([pscustomobject]@{ Id = 'f1'; Title = 'x' }) -CopilotTier Business
                $result.SchemaVersion | Should -Be '1.0'
                $result.Mode | Should -Be 'Rubberduck'
                $result.SelectedModels.Count | Should -Be 3
                $result.FallbackChain.Count | Should -BeGreaterOrEqual 3
                $result.GeneratedAt | Should -Match '^\d{4}-\d{2}-\d{2}T'
            } finally {
                Remove-Item Function:\global:gh -ErrorAction SilentlyContinue
            }
        }
    }

    Context 'Prompt-injection mitigation' {
        It 'projects findings to allow-listed fields only' {
            function global:gh {
                param([Parameter(ValueFromRemainingArguments = $true)][string[]] $Args)
                $cmd = ($Args -join ' ')
                $global:LASTEXITCODE = 0
                if ($cmd -eq 'copilot models list --json id') { return '[{"id":"claude-sonnet-4.6"},{"id":"gpt-5.2"},{"id":"gemini-3-pro-preview"}]' }
                throw "unexpected gh call: $cmd"
            }
            try {
                $finding = [pscustomobject]@{
                    Id              = 'f1'
                    Title           = 'safe'
                    SecretMaterial  = 'should-not-appear-in-prompt'
                    ArbitraryField  = 'also-not'
                }
                $result = Invoke-CopilotTriage -Findings @($finding) -CopilotTier Pro -SingleModel
                $result.Prompt | Should -Not -Match 'should-not-appear-in-prompt'
                $result.Prompt | Should -Not -Match 'ArbitraryField'
                $result.Prompt | Should -Match 'safe'
            } finally {
                Remove-Item Function:\global:gh -ErrorAction SilentlyContinue
            }
        }
    }

    Context 'Prompt projection truncation' {
        It 'truncates long allow-listed field values to MaxPromptFieldChars including suffix length' {
            $suffix = '...[TRUNCATED]'
            $longTitle = ('A' * ($script:MaxPromptFieldChars + 25))
            $finding = [pscustomobject]@{
                Id    = 'f-long'
                Title = $longTitle
            }
            $projection = @(ConvertTo-SafeFindingProjection -Findings @($finding))
            $projection[0].Title.Length | Should -Be $script:MaxPromptFieldChars
            $projection[0].Title | Should -Be ((('A' * ($script:MaxPromptFieldChars - $suffix.Length))) + $suffix)
            $projection[0].Title | Should -Match '\.\.\.\[TRUNCATED\]$'
            $projection[0].Title | Should -Not -Be $longTitle
        }
    }
}
