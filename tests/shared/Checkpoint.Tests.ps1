Set-StrictMode -Version Latest

BeforeAll {
    . "$PSScriptRoot\..\..\modules\shared\Checkpoint.ps1"
}

Describe 'Get-CheckpointKey' {
    It 'uses identity-correlator key for identity scope by default' {
        $key = Get-CheckpointKey -ScopeType Identity
        $key | Should -Be 'identity-correlator'
    }

    It 'sanitizes path-like values in scope keys' {
        $key = Get-CheckpointKey -ScopeType Repository -RepoSlug 'owner/..\repo'
        $key | Should -Be 'repo-owner___repo'
    }
}
