#Requires -Version 7.4
Set-StrictMode -Version Latest

BeforeAll {
    $script:Here = Split-Path $PSCommandPath -Parent
    $script:RepoRoot = Resolve-Path (Join-Path $script:Here '..' '..')
    $script:wrapper = Join-Path $script:RepoRoot 'modules' 'Invoke-Scorecard.ps1'
}

Describe 'scorecard wrapper: GH_HOST handling' {
    BeforeEach {
        $global:seenGhHost = $null
        function global:scorecard {
            $global:seenGhHost = $env:GH_HOST
            return '{"repo":{"name":"org/repo"},"checks":[]}'
        }
    }

    AfterEach {
        Remove-Item Function:\global:scorecard -ErrorAction SilentlyContinue
        Remove-Variable -Name seenGhHost -Scope Global -ErrorAction SilentlyContinue
    }

    It 'sets GH_HOST to github.com during scorecard invocation and restores original value afterward' {
        $original = 'already.set.host'
        $env:GH_HOST = $original

        $result = & $script:wrapper -Repository 'github.com/org/repo'

        $result.Status | Should -Be 'Success'
        $global:seenGhHost | Should -Be 'github.com'
        $env:GH_HOST | Should -Be $original
    }

    It 'uses an explicit enterprise GitHub host and restores GH_HOST when initially unset' {
        Remove-Item Env:\GH_HOST -ErrorAction SilentlyContinue

        $result = & $script:wrapper -Repository 'company.ghe.com/org/repo' -GitHubHost 'company.ghe.com'

        $result.Status | Should -Be 'Success'
        $global:seenGhHost | Should -Be 'company.ghe.com'
        Test-Path Env:\GH_HOST | Should -BeFalse
    }
}
