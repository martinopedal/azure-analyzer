#requires -Version 7.0
#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }

BeforeAll {
    $script:RepoRoot    = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..')).Path
    $script:ModulePath  = Join-Path $script:RepoRoot 'modules\shared\Triage\Invoke-CopilotTriage.ps1'
    $script:RankingPath = Join-Path $script:RepoRoot 'config\triage-model-ranking.json'
    . $script:ModulePath
}

Describe 'Triage fallback chain and rich errors' {
    Context 'Fallback chain ordering' {
        It 'returns chain in rank-descending order from ranking config intersection' {
            $ranking = Get-Content -LiteralPath $script:RankingPath -Raw -Encoding utf8 | ConvertFrom-Json
            $chain   = @(Get-FrontierFallbackChain `
                -AvailableModels @('gemini-3-pro-preview', 'claude-sonnet-4.6', 'gpt-5.2', 'gpt-4.1') `
                -RankingTable $ranking)
            $chain[0] | Should -Be 'claude-sonnet-4.6'
            $chain[-1] | Should -Be 'gpt-4.1'
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
            $result = Invoke-ModelWithFallback -ModelChain @('claude-sonnet-4.6') -Invoker $invoker
            $result | Should -Be 'ok-claude-sonnet-4.6'
            $perStepCalls.Count | Should -BeGreaterOrEqual 2
        }
    }

    Context 'Rich error contract (no raw strings)' {
        It 'throws a New-FindingError-shaped object when the entire chain is exhausted' {
            $invoker = { param($m) throw '503 service unavailable' }
            $caught  = $null
            try {
                Invoke-ModelWithFallback -ModelChain @('claude-sonnet-4.6', 'gpt-5.2') -Invoker $invoker
            } catch {
                $caught = $_
            }
            $caught | Should -Not -BeNullOrEmpty
            $payload = if ($null -ne $caught.TargetObject) { $caught.TargetObject } else { $caught.Exception.Message }
            ($payload | Out-String) | Should -Match 'AllModelsFailed'
        }

        It 'New-TriageError emits the documented rich-error fields' {
            $err = New-TriageError -Category 'TestCat' -Reason 'why' `
                -Remediation 'how' -Details 'no secrets here'
            $err.PSObject.TypeNames | Should -Contain 'AzureAnalyzer.FindingError'
            $err.Source       | Should -Be 'triage'
            $err.Category     | Should -Be 'TestCat'
            $err.Reason       | Should -Be 'why'
            $err.Remediation  | Should -Be 'how'
            $err.Details      | Should -Be 'no secrets here'
            $err.TimestampUtc | Should -Match '^\d{4}-\d{2}-\d{2}T'
        }
    }
}
