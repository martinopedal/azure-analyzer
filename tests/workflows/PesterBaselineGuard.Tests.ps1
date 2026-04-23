Describe 'CI Pester baseline guard (regression for #471)' {
    BeforeAll {
        $script:CiPath = Join-Path $PSScriptRoot '..' '..' '.github' 'workflows' 'ci.yml'
        $script:CiRaw  = Get-Content -Raw -Path $script:CiPath
    }

    It 'sets PesterConfiguration.Run.PassThru = $true so $result is populated' {
        # Without PassThru, Invoke-Pester returns $null, TotalCount becomes 0,
        # and the baseline-compare step rejects the run as "TotalCount=0 (no tests executed)".
        # See run https://github.com/martinopedal/azure-analyzer/actions/runs/24776045890.
        $script:CiRaw | Should -Match '\$config\.Run\.PassThru\s*=\s*\$true'
    }

    It 'guards against null Pester result before recording the count' {
        $script:CiRaw | Should -Match '\$null\s+-eq\s+\$result'
        $script:CiRaw | Should -Match 'Invoke-Pester returned null'
    }

    It 'refuses to upload a baseline with TotalCount<=0' {
        $script:CiRaw | Should -Match '\[int\]\$current\.TotalCount\s+-le\s+0'
        $script:CiRaw | Should -Match 'Refusing to upload as baseline'
    }

    It 'compares current TotalCount against the previous main baseline' {
        $script:CiRaw | Should -Match '\[int\]\$current\.TotalCount\s+-lt\s+\[int\]\$baseline\.TotalCount'
    }

    It 'enforces hardcoded TotalCount floor of 1630 (PR #937 baseline)' {
        $script:CiRaw | Should -Match '\$MinTotal\s*=\s*1630'
        $script:CiRaw | Should -Match '\[int\]\$current\.TotalCount\s+-lt\s+\$MinTotal'
    }

    It 'enforces hardcoded PassedCount floor of 1595 (PR #937 baseline)' {
        # Lowered from 1602 to 1595 in PR #937 (removed auto-approve-bot-runs.yml
        # workflow + its 7-test guard file AutoApproveBotRuns.Tests.ps1).
        $script:CiRaw | Should -Match '\$MinPassed\s*=\s*1595'
        $script:CiRaw | Should -Match '\[int\]\$current\.PassedCount\s+-lt\s+\$MinPassed'
    }
}
