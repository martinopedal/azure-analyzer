#requires -Version 7.4
#requires -Modules Pester

Set-StrictMode -Version Latest

BeforeAll {
    $script:ModulePath = Join-Path $PSScriptRoot '..' '..' 'modules' 'shared' 'Triage' 'Invoke-CopilotTriage.ps1'
    $script:RankingPath = Join-Path $PSScriptRoot '..' '..' 'config' 'triage-model-ranking.json'
    . $script:ModulePath
}

Describe 'LLM triage model selection (#433, frontier-only)' {
    Context 'Tier discovery and available models' {
        It 'falls back to -CopilotTier when gh copilot status is unavailable' {
            function global:gh { throw 'unsupported command' }
            try {
                $models = @(Get-AvailableModelsFromCopilotPlan -CopilotTier Business)
                $models | Should -Contain 'claude-opus-4.7'
                $models | Should -Contain 'gpt-5.4'
                $models | Should -Contain 'goldeneye'
            } finally {
                Remove-Item Function:\global:gh -ErrorAction SilentlyContinue
            }
        }

        It 'requires explicit tier when status is unavailable and no fallback is provided' {
            function global:gh { throw 'unsupported command' }
            try {
                { Get-AvailableModelsFromCopilotPlan } | Should -Throw
            } finally {
                Remove-Item Function:\global:gh -ErrorAction SilentlyContinue
            }
        }

        It 'roster contains only frontier models (no sonnet/haiku/mini/gpt-4.1/gpt-5.2/gemini/opus-4.6)' {
            function global:gh { throw 'unsupported command' }
            try {
                $banned = @('claude-sonnet-4.6', 'claude-haiku-4.5', 'gpt-4.1', 'gpt-5.2', 'gpt-5.2-codex', 'gemini-3-pro-preview', 'claude-opus-4.6', 'gpt-5-mini', 'gpt-5.4-mini')
                foreach ($tier in @('Pro', 'Business', 'Enterprise')) {
                    $models = @(Get-AvailableModelsFromCopilotPlan -CopilotTier $tier)
                    foreach ($b in $banned) { $models | Should -Not -Contain $b }
                }
            } finally {
                Remove-Item Function:\global:gh -ErrorAction SilentlyContinue
            }
        }
    }

    Context 'Trio ranking and provider diversity' {
        It 'prefers top-ranked available models from ranking config' {
            $ranking = Get-Content -Path $script:RankingPath -Raw -Encoding utf8 | ConvertFrom-Json
            $trio = @(Select-TriageTrio -AvailableModels @(
                    'claude-opus-4.7',
                    'claude-opus-4.6-1m',
                    'gpt-5.4',
                    'gpt-5.3-codex',
                    'goldeneye'
                ) -RankingTable $ranking)

            $trio.Count | Should -Be 3
            $trio | Should -Contain 'claude-opus-4.7'
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

    Context 'Frontier fallback chain' {
        It 'returns models in rank-descending order' {
            $ranking = Get-Content -Path $script:RankingPath -Raw -Encoding utf8 | ConvertFrom-Json
            $chain = @(Get-FrontierFallbackChain -AvailableModels @('goldeneye', 'claude-opus-4.7', 'gpt-5.4') -RankingTable $ranking)
            $chain[0] | Should -Be 'claude-opus-4.7'
            $chain[-1] | Should -Be 'goldeneye'
        }

        It 'walks chain on transient failure and returns first success' {
            $attempted = [System.Collections.Generic.List[string]]::new()
            $invoker = {
                param($m)
                $attempted.Add($m)
                if ($m -eq 'claude-opus-4.7') { throw '503 service unavailable' }
                return "ok-$m"
            }
            $result = Invoke-ModelWithFallback -ModelChain @('claude-opus-4.7', 'gpt-5.4') -Invoker $invoker
            $result | Should -Be 'ok-gpt-5.4'
            $attempted | Should -Contain 'claude-opus-4.7'
            $attempted | Should -Contain 'gpt-5.4'
        }

        It 'throws AllModelsFailed when entire chain is exhausted' {
            $invoker = { param($m) throw '503 service unavailable' }
            { Invoke-ModelWithFallback -ModelChain @('claude-opus-4.7', 'gpt-5.4') -Invoker $invoker } | Should -Throw
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
                $result.SchemaVersion | Should -Be '1.0'
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
                        -ExplicitModel 'claude-sonnet-4.6'
                } | Should -Throw
            } finally {
                Remove-Item Function:\global:gh -ErrorAction SilentlyContinue
            }
        }

        It 'allows single-model fallback when fewer than three models are available and -SingleModel is set' {
            function global:gh { throw 'unsupported command' }
            try {
                $warnings = $null
                $result = Invoke-CopilotTriage `
                    -Findings @([pscustomobject]@{ Id = 'f1'; Title = 'x' }) `
                    -CopilotTier Pro `
                    -SingleModel `
                    -WarningVariable warnings
                $result.Mode | Should -Be 'SingleModel'
                $result.SelectedModels.Count | Should -Be 1
                $result.FallbackChain.Count | Should -BeGreaterThan 0
                @($warnings).Count | Should -BeGreaterThan 0
            } finally {
                Remove-Item Function:\global:gh -ErrorAction SilentlyContinue
            }
        }

        It 'emits versioned schema with FallbackChain and GeneratedAt' {
            function global:gh { throw 'unsupported command' }
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
            function global:gh { throw 'unsupported command' }
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

        It 'truncates long allow-listed field values to MaxPromptFieldChars' {
            function global:gh { throw 'unsupported command' }
            try {
                $longTitle = ('A' * 5000)
                $finding = [pscustomobject]@{ Id = 'f1'; Title = $longTitle }
                $result = Invoke-CopilotTriage -Findings @($finding) -CopilotTier Pro -SingleModel
                $result.Prompt | Should -Match '\[TRUNCATED\]'
                $result.Prompt.Length | Should -BeLessThan 5000
            } finally {
                Remove-Item Function:\global:gh -ErrorAction SilentlyContinue
            }
        }
    }
}
