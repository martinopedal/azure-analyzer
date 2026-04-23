#Requires -Version 7.4
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

BeforeAll {
    $script:Here = Split-Path $PSCommandPath -Parent
    $script:RepoRoot = Resolve-Path (Join-Path $script:Here '..' '..')
    . (Join-Path $script:RepoRoot 'modules' 'Invoke-IdentityCorrelator.ps1')
}

Describe 'Invoke-IdentityCorrelation: error paths' {
    It 'loads Invoke-IdentityCorrelation via the wrapper entrypoint script' {
        Get-Command -Name 'Invoke-IdentityCorrelation' -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
    }

    Context 'when EntityStore is empty' {
        BeforeAll {
            $emptyStore = @()
            $result = Invoke-IdentityCorrelation -EntityStore $emptyStore -TenantId '00000000-0000-0000-0000-000000000000'
        }

        It 'returns empty findings' {
            @($result).Count | Should -Be 0
        }
    }

    Context 'when EntityStore contains no identity candidates' {
        BeforeAll {
            $store = @(
                [PSCustomObject]@{
                    EntityType = 'VirtualMachine'
                    EntityId = 'vm-123'
                    Platform = 'Azure'
                    Observations = @()
                }
            )
            $result = Invoke-IdentityCorrelation -EntityStore $store -TenantId '00000000-0000-0000-0000-000000000000'
        }

        It 'returns empty findings gracefully' {
            @($result).Count | Should -Be 0
        }
    }
}
