#Requires -Version 7.4
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

BeforeAll {
    $script:Here = Split-Path $PSCommandPath -Parent
    $script:RepoRoot = Resolve-Path (Join-Path $script:Here '..' '..')
    . (Join-Path $script:RepoRoot 'modules' 'shared' 'RbacTier.ps1')
}

Describe 'RbacTier (modules/shared/RbacTier.ps1)' {
    BeforeEach {
        Reset-RbacTier
    }

    It 'defaults to Reader' {
        Get-RbacTier | Should -Be 'Reader'
    }

    It 'Set-RbacTier promotes the active tier' {
        Set-RbacTier -Tier 'ClusterUser'
        Get-RbacTier | Should -Be 'ClusterUser'
    }

    It 'rejects an unknown tier value' {
        { Set-RbacTier -Tier 'Owner' } | Should -Throw
    }

    It 'Reset-RbacTier returns to Reader' {
        Set-RbacTier -Tier 'ClusterUser'
        Reset-RbacTier
        Get-RbacTier | Should -Be 'Reader'
    }

    It 'Test-RbacTierSatisfies treats Reader as satisfying Reader' {
        (Test-RbacTierSatisfies -Required 'Reader') | Should -BeTrue
    }

    It 'Test-RbacTierSatisfies treats Reader as NOT satisfying ClusterUser' {
        (Test-RbacTierSatisfies -Required 'ClusterUser') | Should -BeFalse
    }

    It 'Test-RbacTierSatisfies treats ClusterUser as satisfying both tiers' {
        Set-RbacTier -Tier 'ClusterUser'
        (Test-RbacTierSatisfies -Required 'Reader')      | Should -BeTrue
        (Test-RbacTierSatisfies -Required 'ClusterUser') | Should -BeTrue
    }

    It 'Assert-RbacTier is a no-op when satisfied' {
        Set-RbacTier -Tier 'ClusterUser'
        { Assert-RbacTier -Required 'ClusterUser' -Capability 'k cap' } | Should -Not -Throw
    }

    It 'Assert-RbacTier throws [InsufficientRbac] with the opt-in flag in remediation' {
        $err = $null
        try {
            Assert-RbacTier -Required 'ClusterUser' -Capability 'Karpenter Provisioner inspection' -OptInFlag '-EnableElevatedRbac'
        } catch {
            $err = $_.Exception.Message
        }
        $err | Should -Not -BeNullOrEmpty
        $err | Should -Match '\[InsufficientRbac\]'
        $err | Should -Match '-EnableElevatedRbac'
        $err | Should -Match 'Karpenter Provisioner inspection'
        $err | Should -Match "tier 'ClusterUser'"
    }
}
