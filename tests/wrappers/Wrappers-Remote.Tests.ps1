#Requires -Version 7.4
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

BeforeAll {
    $script:Here = Split-Path $PSCommandPath -Parent
    $script:RepoRoot = Resolve-Path (Join-Path $script:Here '..' '..')
}

Describe 'zizmor wrapper: remote/local routing' {
    BeforeAll {
        $script:wrapper = Join-Path $script:RepoRoot 'modules' 'Invoke-Zizmor.ps1'
    }
    It 'accepts -RemoteUrl parameter' {
        $paramInfo = (Get-Command $script:wrapper).Parameters
        $paramInfo.ContainsKey('RemoteUrl') | Should -BeTrue
    }
    It 'rejects non-allow-listed remote URL' {
        $result = & $script:wrapper -RemoteUrl 'https://evil.example.com/org/repo'
        $result.Source | Should -Be 'zizmor'
        $result.Status | Should -Match 'Skipped|Failed'
    }
}

Describe 'gitleaks wrapper: remote/local routing' {
    BeforeAll {
        $script:wrapper = Join-Path $script:RepoRoot 'modules' 'Invoke-Gitleaks.ps1'
    }
    It 'accepts -RemoteUrl parameter' {
        $paramInfo = (Get-Command $script:wrapper).Parameters
        $paramInfo.ContainsKey('RemoteUrl') | Should -BeTrue
    }
    It 'rejects non-allow-listed remote URL' {
        $result = & $script:wrapper -RemoteUrl 'https://attacker.example.net/x'
        $result.Source | Should -Be 'gitleaks'
        $result.Status | Should -Match 'Skipped|Failed'
    }
}

Describe 'trivy wrapper: remote/local routing' {
    BeforeAll {
        $script:wrapper = Join-Path $script:RepoRoot 'modules' 'Invoke-Trivy.ps1'
    }
    It 'accepts -RemoteUrl parameter' {
        $paramInfo = (Get-Command $script:wrapper).Parameters
        $paramInfo.ContainsKey('RemoteUrl') | Should -BeTrue
    }
    It 'rejects non-allow-listed remote URL' {
        $result = & $script:wrapper -RemoteUrl 'https://gitlab.com/org/repo'
        $result.Source | Should -Be 'trivy'
        $result.Status | Should -Match 'Skipped|Failed'
    }
}

Describe 'infracost wrapper: remote/local routing' {
    BeforeAll {
        $script:wrapper = Join-Path $script:RepoRoot 'modules' 'Invoke-Infracost.ps1'
    }
    It 'accepts -Repository parameter' {
        $paramInfo = (Get-Command $script:wrapper).Parameters
        $paramInfo.ContainsKey('Repository') | Should -BeTrue
    }
    It 'rejects non-allow-listed remote URL' {
        $result = & $script:wrapper -Repository 'https://evil.example.org/org/repo'
        $result.Source | Should -Be 'infracost'
        $result.Status | Should -Match 'Skipped|Failed'
    }
}

