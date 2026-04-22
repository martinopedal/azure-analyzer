#requires -Version 7.0
#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }

# Bottom-fix gate (round 2) — verifies the .copilot Frontier Fallback Chain
# policy is enforced inside the triage module:
#   * Roster only contains frontier models (no sonnet/haiku/mini/gpt-4.1/gpt-5.2/
#     gemini/opus-4.6).
#   * Get-FrontierFallbackChain returns rank-descending order.
#   * Invoke-ModelWithFallback walks the chain on transient failure and is
#     wrapped by Invoke-WithRetry.
#   * Errors are thrown as rich AzureAnalyzer.FindingError objects, never as
#     bare strings.

BeforeAll {
    $script:RepoRoot    = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..')).Path
    $script:ModulePath  = Join-Path $script:RepoRoot 'modules\shared\Triage\Invoke-CopilotTriage.ps1'
    $script:RankingPath = Join-Path $script:RepoRoot 'config\triage-model-ranking.json'
    . $script:ModulePath
}

Describe 'Triage Frontier Fallback Chain (bottom-fix #466)' {

    Context 'Roster contents' {
        It 'each tier roster contains only frontier models' {
            $banned = @(
                'claude-sonnet-4.6', 'claude-haiku-4.5', 'gpt-4.1',
                'gpt-5.2', 'gpt-5.2-codex', 'gemini-3-pro-preview',
                'claude-opus-4.6', 'gpt-5-mini', 'gpt-5.4-mini'
            )
            foreach ($tier in @('Pro', 'Business', 'Enterprise')) {
                $models = @(Get-AvailableModelsFromCopilotPlan -CopilotTier $tier)
                $models.Count | Should -BeGreaterThan 0
                foreach ($b in $banned) { $models | Should -Not -Contain $b }
            }
        }

        It 'Enterprise roster includes claude-opus-4.7 as the primary anchor' {
            $models = @(Get-AvailableModelsFromCopilotPlan -CopilotTier Enterprise)
            $models | Should -Contain 'claude-opus-4.7'
        }

        It 'Pro roster includes goldeneye as last-resort fallback' {
            $models = @(Get-AvailableModelsFromCopilotPlan -CopilotTier Pro)
            $models | Should -Contain 'goldeneye'
        }
    }

    Context 'Fallback chain ordering' {
        It 'returns chain in rank-descending order matching ranking config' {
            $ranking = Get-Content -LiteralPath $script:RankingPath -Raw -Encoding utf8 | ConvertFrom-Json
            $chain   = @(Get-FrontierFallbackChain `
                -AvailableModels @('goldeneye', 'gpt-5.3-codex', 'claude-opus-4.7', 'gpt-5.4', 'claude-opus-4.6-1m') `
                -RankingTable $ranking)
            $chain[0]  | Should -Be 'claude-opus-4.7'
            $chain[1]  | Should -Be 'claude-opus-4.6-1m'
            $chain[2]  | Should -Be 'gpt-5.4'
            $chain[3]  | Should -Be 'gpt-5.3-codex'
            $chain[-1] | Should -Be 'goldeneye'
        }

        It 'filters out models not present in the ranking config (frontier-only intersection)' {
            $ranking = Get-Content -LiteralPath $script:RankingPath -Raw -Encoding utf8 | ConvertFrom-Json
            $chain   = @(Get-FrontierFallbackChain `
                -AvailableModels @('claude-opus-4.7', 'claude-sonnet-4.6', 'gpt-4.1') `
                -RankingTable $ranking)
            $chain | Should -Contain 'claude-opus-4.7'
            $chain | Should -Not -Contain 'claude-sonnet-4.6'
            $chain | Should -Not -Contain 'gpt-4.1'
        }
    }

    Context 'Retry wrapping (Invoke-WithRetry from modules/shared/Retry.ps1)' {
        It 'each chain step is wrapped by Invoke-WithRetry (jittered backoff on transient failure)' {
            $perStepCalls = [System.Collections.Generic.List[string]]::new()
            $invoker = {
                param($model)
                $perStepCalls.Add($model)
                if ($perStepCalls.Count -lt 2) { throw '503 service unavailable, please retry' }
                return "ok-$model"
            }
            $result = Invoke-ModelWithFallback -ModelChain @('claude-opus-4.7') -Invoker $invoker
            $result | Should -Be 'ok-claude-opus-4.7'
            # Two invocations means Invoke-WithRetry retried within a single chain step.
            $perStepCalls.Count | Should -BeGreaterOrEqual 2
        }

        It 'walks to the next chain step when retries are exhausted on the current model' {
            $attempted = [System.Collections.Generic.List[string]]::new()
            $invoker = {
                param($model)
                $attempted.Add($model)
                if ($model -eq 'claude-opus-4.7') { throw '503 service unavailable' }
                return "ok-$model"
            }
            $result = Invoke-ModelWithFallback -ModelChain @('claude-opus-4.7', 'gpt-5.4') -Invoker $invoker
            $result | Should -Be 'ok-gpt-5.4'
            $attempted | Should -Contain 'claude-opus-4.7'
            $attempted | Should -Contain 'gpt-5.4'
        }
    }

    Context 'Rich error contract (no raw strings)' {
        It 'throws a New-FindingError-shaped object when the entire chain is exhausted' {
            $invoker = { param($m) throw '503 service unavailable' }
            $caught  = $null
            try {
                Invoke-ModelWithFallback -ModelChain @('claude-opus-4.7', 'gpt-5.4') -Invoker $invoker
            } catch {
                $caught = $_
            }
            $caught | Should -Not -BeNullOrEmpty
            # The thrown payload may be wrapped by PowerShell's ErrorRecord; the
            # underlying TargetObject (or message) must reference the rich
            # FindingError contract.
            $payload = if ($null -ne $caught.TargetObject) { $caught.TargetObject } else { $caught.Exception.Message }
            ($payload | Out-String) | Should -Match 'AllModelsFailed'
        }

        It 'New-FindingError emits the documented rich-error fields' {
            $err = New-FindingError -Source 'triage' -Category 'TestCat' -Reason 'why' `
                -Remediation 'how' -Details 'no secrets here'
            $err.PSObject.TypeNames | Should -Contain 'AzureAnalyzer.FindingError'
            $err.Source       | Should -Be 'triage'
            $err.Category     | Should -Be 'TestCat'
            $err.Reason       | Should -Be 'why'
            $err.Remediation  | Should -Be 'how'
            $err.Details      | Should -Be 'no secrets here'
            $err.TimestampUtc | Should -Match '^\d{4}-\d{2}-\d{2}T'
        }

        It 'New-FindingError scrubs Bearer tokens out of Details' {
            $err = New-FindingError -Source 'triage' -Category 'TestCat' -Reason 'why' `
                -Details 'Authorization: Bearer abc.def.ghi-jkl_mn'
            $err.Details | Should -Not -Match 'abc\.def\.ghi-jkl_mn'
            $err.Details | Should -Match '\[REDACTED\]'
        }
    }
}
