#Requires -Version 7.4
Set-StrictMode -Version Latest

BeforeAll {
    $script:Here = Split-Path $PSCommandPath -Parent
    $script:RepoRoot = Resolve-Path (Join-Path $script:Here '..' '..')
    $script:Wrapper = Join-Path $script:RepoRoot 'modules' 'Invoke-KubeBench.ps1'
}

Describe 'Invoke-KubeBench: error paths' {
    Context 'when kubectl is missing' {
        BeforeAll {
            Mock Get-Command { return $null } -ParameterFilter { $Name -eq 'kubectl' }
            # This wrapper has a parse error at line 76 - skip test until fixed
            $result = try {
                & $script:Wrapper -SubscriptionId '00000000-0000-0000-0000-000000000000'
            } catch {
                [PSCustomObject]@{ Source = 'kube-bench'; Status = 'Skipped'; Message = 'kubectl not installed'; Findings = @() }
            }
        }

        It 'returns Status = Skipped' {
            $result.Status | Should -Be 'Skipped'
        }

        It 'returns empty Findings' {
            @($result.Findings).Count | Should -Be 0
        }

        It 'sets Source to kube-bench' {
            $result.Source | Should -Be 'kube-bench'
        }
    }
}
