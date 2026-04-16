#Requires -Version 7.4
Set-StrictMode -Version Latest

BeforeAll {
    $script:Here = Split-Path $PSCommandPath -Parent
    $script:RepoRoot = Resolve-Path (Join-Path $script:Here '..' '..')
    . (Join-Path $script:RepoRoot 'modules' 'shared' 'Sanitize.ps1')
    . (Join-Path $script:RepoRoot 'modules' 'shared' 'Retry.ps1')
    . (Join-Path $script:RepoRoot 'modules' 'shared' 'RemoteClone.ps1')
}

Describe 'Test-RemoteRepoUrl' {
    It 'accepts github.com HTTPS' {
        Test-RemoteRepoUrl -Url 'https://github.com/org/repo' | Should -BeTrue
    }
    It 'accepts dev.azure.com HTTPS' {
        Test-RemoteRepoUrl -Url 'https://dev.azure.com/org/proj/_git/repo' | Should -BeTrue
    }
    It 'accepts *.visualstudio.com HTTPS' {
        Test-RemoteRepoUrl -Url 'https://contoso.visualstudio.com/proj/_git/repo' | Should -BeTrue
    }
    It 'accepts *.ghe.com HTTPS' {
        Test-RemoteRepoUrl -Url 'https://corp.ghe.com/org/repo' | Should -BeTrue
    }
    It 'rejects http://' {
        Test-RemoteRepoUrl -Url 'http://github.com/org/repo' | Should -BeFalse
    }
    It 'rejects git@ ssh form' {
        Test-RemoteRepoUrl -Url 'git@github.com:org/repo.git' | Should -BeFalse
    }
    It 'rejects file:// URLs' {
        Test-RemoteRepoUrl -Url 'file:///tmp/repo' | Should -BeFalse
    }
    It 'rejects non-allow-listed hosts' {
        Test-RemoteRepoUrl -Url 'https://gitlab.com/org/repo' | Should -BeFalse
        Test-RemoteRepoUrl -Url 'https://bitbucket.org/org/repo' | Should -BeFalse
        Test-RemoteRepoUrl -Url 'https://evil.example.com/repo' | Should -BeFalse
    }
}

Describe 'Resolve-ScanTargetUrl' {
    It 'returns AdoRepoUrl verbatim when allow-listed' {
        $r = Resolve-ScanTargetUrl -AdoRepoUrl 'https://dev.azure.com/org/proj/_git/repo'
        $r | Should -Be 'https://dev.azure.com/org/proj/_git/repo'
    }
    It 'returns $null for AdoRepoUrl on disallowed host' {
        $r = Resolve-ScanTargetUrl -AdoRepoUrl 'https://attacker.example.com/x'
        $r | Should -BeNullOrEmpty
    }
    It 'normalizes owner/repo to https github.com' {
        $r = Resolve-ScanTargetUrl -Repository 'martinopedal/azure-analyzer'
        $r | Should -Be 'https://github.com/martinopedal/azure-analyzer'
    }
    It 'uses GitHubHost override' {
        $r = Resolve-ScanTargetUrl -Repository 'org/repo' -GitHubHost 'corp.ghe.com'
        $r | Should -Be 'https://corp.ghe.com/org/repo'
    }
    It 'accepts a full HTTPS URL under -Repository' {
        $r = Resolve-ScanTargetUrl -Repository 'https://github.com/org/repo'
        $r | Should -Be 'https://github.com/org/repo'
    }
    It 'returns $null for garbage owner/repo' {
        $r = Resolve-ScanTargetUrl -Repository 'bad@thing%$'
        $r | Should -BeNullOrEmpty
    }
    It 'returns $null with neither input' {
        $r = Resolve-ScanTargetUrl
        $r | Should -BeNullOrEmpty
    }
    It 'prefers AdoRepoUrl over Repository' {
        $r = Resolve-ScanTargetUrl -AdoRepoUrl 'https://dev.azure.com/a/b/_git/c' -Repository 'org/repo'
        $r | Should -Be 'https://dev.azure.com/a/b/_git/c'
    }
}

Describe 'ConvertTo-AuthenticatedRemoteUrl' {
    It 'injects token into HTTPS URL' {
        $r = ConvertTo-AuthenticatedRemoteUrl -Url 'https://github.com/org/repo' -Token 'abc123'
        $r | Should -Match 'https://x-access-token:abc123@github.com/org/repo$'
    }
    It 'URL-encodes special characters in token' {
        $r = ConvertTo-AuthenticatedRemoteUrl -Url 'https://github.com/org/repo' -Token 'a:b@c'
        $r | Should -Not -Match '[:@]b[:@]'  # colons/ats escaped
        $r | Should -Match 'a%3Ab%40c'
    }
    It 'does not double-inject if auth already present' {
        $r = ConvertTo-AuthenticatedRemoteUrl -Url 'https://user:pass@github.com/repo' -Token 'abc'
        $r | Should -Be 'https://user:pass@github.com/repo'
    }
    It 'returns URL unchanged when no token' {
        $r = ConvertTo-AuthenticatedRemoteUrl -Url 'https://github.com/org/repo' -Token ''
        $r | Should -Be 'https://github.com/org/repo'
    }
}

Describe 'Resolve-RemoteRepoToken' {
    BeforeEach {
        $script:savedGitHub   = $env:GITHUB_TOKEN
        $script:savedGh       = $env:GH_TOKEN
        $script:savedAdo      = $env:AZURE_DEVOPS_EXT_PAT
        $script:savedSysToken = $env:SYSTEM_ACCESSTOKEN
        $env:GITHUB_TOKEN = $null; $env:GH_TOKEN = $null
        $env:AZURE_DEVOPS_EXT_PAT = $null; $env:SYSTEM_ACCESSTOKEN = $null
    }
    AfterEach {
        $env:GITHUB_TOKEN = $script:savedGitHub
        $env:GH_TOKEN = $script:savedGh
        $env:AZURE_DEVOPS_EXT_PAT = $script:savedAdo
        $env:SYSTEM_ACCESSTOKEN = $script:savedSysToken
    }
    It 'returns explicit token verbatim' {
        Resolve-RemoteRepoToken -Url 'https://github.com/a/b' -Token 'explicit' |
            Should -Be 'explicit'
    }
    It 'picks GITHUB_TOKEN for github.com' {
        $env:GITHUB_TOKEN = 'ghtok'
        Resolve-RemoteRepoToken -Url 'https://github.com/a/b' | Should -Be 'ghtok'
    }
    It 'picks AZURE_DEVOPS_EXT_PAT for dev.azure.com' {
        $env:AZURE_DEVOPS_EXT_PAT = 'adopat'
        Resolve-RemoteRepoToken -Url 'https://dev.azure.com/a/b/_git/c' |
            Should -Be 'adopat'
    }
    It 'returns empty string when nothing configured' {
        Resolve-RemoteRepoToken -Url 'https://github.com/a/b' | Should -Be ''
    }
}
