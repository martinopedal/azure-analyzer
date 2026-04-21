#Requires -Version 7.4
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

BeforeAll {
    $script:Here = Split-Path $PSCommandPath -Parent
    $script:RepoRoot = Resolve-Path (Join-Path $script:Here '..' '..')
    $script:wrapper = Join-Path $script:RepoRoot 'modules' 'Invoke-Scorecard.ps1'
    $global:scorecardCliFixtureRaw = Get-Content (Join-Path $script:RepoRoot 'tests\fixtures\scorecard-cli-output.json') -Raw
}

AfterAll {
    Remove-Variable -Name scorecardCliFixtureRaw -Scope Global -ErrorAction SilentlyContinue
}

Describe 'scorecard wrapper: GH_HOST handling' {
    BeforeEach {
        $global:seenGhHost = $null
        function global:scorecard {
            param (
                [Parameter(ValueFromRemainingArguments = $true)]
                [string[]] $Args
            )
            $global:seenGhHost = $env:GH_HOST
            if ($Args -contains '--version') {
                return 'scorecard version: v4.13.0'
            }
            return $global:scorecardCliFixtureRaw
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

    It 'includes SchemaVersion 1.0 in the v1 envelope' {
        Remove-Item Env:\GH_HOST -ErrorAction SilentlyContinue
        $result = & $script:wrapper -Repository 'github.com/org/repo'
        $result.SchemaVersion | Should -Be '1.0'
    }

    It 'emits Schema 2.2 ETL seed fields in each finding' {
        Remove-Item Env:\GH_HOST -ErrorAction SilentlyContinue
        $result = & $script:wrapper -Repository 'github.com/test-org/test-repo'
        @($result.Findings).Count | Should -Be 5

        $branchProtection = @($result.Findings | Where-Object { $_.Title -eq 'Branch-Protection' })[0]
        $branchProtection.Pillar | Should -Be 'Security'
        $branchProtection.ToolVersion | Should -Match 'v4\.13\.0'
        $branchProtection.BaselineTags | Should -Contain 'v4.13.0'
        $branchProtection.DeepLinkUrl | Should -Be 'https://github.com/ossf/scorecard/blob/main/docs/checks.md#branch-protection'
        $branchProtection.Frameworks[0].Name | Should -Be 'OpenSSF Scorecard'
        $branchProtection.Frameworks[1].Name | Should -Be 'SLSA'
        @($branchProtection.RemediationSnippets).Count | Should -BeGreaterThan 0
        $snippet = @($branchProtection.RemediationSnippets)[0]
        $snippetText = if ($snippet -is [System.Collections.IDictionary]) { [string]$snippet['Content'] } else { [string]$snippet.Content }
        $snippetText | Should -Match 'Enable branch protection'
    }

    It 'maps score values to the locked severity ladder' {
        Remove-Item Env:\GH_HOST -ErrorAction SilentlyContinue
        $result = & $script:wrapper -Repository 'github.com/test-org/test-repo'
        $byTitle = @{}
        foreach ($f in $result.Findings) { $byTitle[$f.Title] = $f }

        $byTitle['Branch-Protection'].Severity | Should -Be 'Critical'
        $byTitle['SAST'].Severity | Should -Be 'High'
        $byTitle['Pinned-Dependencies'].Severity | Should -Be 'Low'
        $byTitle['Code-Review'].Severity | Should -Be 'Info'
        $byTitle['Token-Permissions'].Severity | Should -Be 'Info'
    }
}

