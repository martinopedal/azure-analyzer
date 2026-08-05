#requires -Version 7.0
#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }

Describe 'Update-ToolPins' {
    BeforeAll {
        $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
        $script:ScriptPath = Join-Path $script:RepoRoot 'tools\Update-ToolPins.ps1'
        $script:_origGitCalls = Get-Variable -Name GitCalls -Scope Global -ErrorAction SilentlyContinue
        $script:_origGhCalls = Get-Variable -Name GhCalls -Scope Global -ErrorAction SilentlyContinue
        $script:_origPwshCalls = Get-Variable -Name PwshCalls -Scope Global -ErrorAction SilentlyContinue
        $script:_origLastExit = $global:LASTEXITCODE
    }

    AfterAll {
        Remove-Variable -Name GitCalls, GhCalls, PwshCalls -Scope Global -ErrorAction SilentlyContinue
        if ($script:_origGitCalls)  { Set-Variable -Name GitCalls  -Scope Global -Value $script:_origGitCalls.Value }
        if ($script:_origGhCalls)   { Set-Variable -Name GhCalls   -Scope Global -Value $script:_origGhCalls.Value }
        if ($script:_origPwshCalls) { Set-Variable -Name PwshCalls -Scope Global -Value $script:_origPwshCalls.Value }
        $global:LASTEXITCODE = $script:_origLastExit
    }

    It 'script file exists' {
        Test-Path -LiteralPath $script:ScriptPath | Should -BeTrue
    }

    It 'exits cleanly with no git activity when all pins are up to date (idempotent)' {
        $manifestPath = Join-Path $TestDrive 'manifest-noop.json'
        @'
{
  "tools": [
    {
      "name": "scorecard",
      "upstream": {
        "releaseApi": "https://api.github.com/repos/ossf/scorecard/releases/latest",
        "pinType": "semver",
        "currentPin": "1.1.0"
      }
    }
  ]
}
'@ | Set-Content -LiteralPath $manifestPath -Encoding utf8 -NoNewline

        $global:GitCalls = New-Object System.Collections.Generic.List[string]
        $global:GhCalls  = New-Object System.Collections.Generic.List[string]

        function git {
            param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Args)
            $global:GitCalls.Add(($Args -join ' ')) | Out-Null
            $global:LASTEXITCODE = 0
        }

        function gh {
            param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Args)
            $global:GhCalls.Add(($Args -join ' ')) | Out-Null
            $global:LASTEXITCODE = 0
        }

        Mock Invoke-RestMethod {
            return [pscustomobject]@{ tag_name = 'v1.1.0'; body = ''; html_url = 'https://example.com' }
        }

        Push-Location $TestDrive
        try {
            & $script:ScriptPath -ManifestPath $manifestPath
        } finally {
            Pop-Location
            Remove-Item function:\git -ErrorAction SilentlyContinue
            Remove-Item function:\gh  -ErrorAction SilentlyContinue
        }

        # No branch, commit, or PR when nothing changed
        $global:GitCalls | Where-Object { $_ -like 'checkout*' } | Should -BeNullOrEmpty
        $global:GhCalls  | Where-Object { $_ -like 'pr create*' } | Should -BeNullOrEmpty
    }

    It 'creates one batched branch and one PR for multiple pin changes' {
        $manifestPath = Join-Path $TestDrive 'manifest-batch.json'
        @'
{
  "tools": [
    {
      "name": "scorecard",
      "upstream": {
        "releaseApi": "https://api.github.com/repos/ossf/scorecard/releases/latest",
        "pinType": "semver",
        "currentPin": "1.0.0"
      }
    },
    {
      "name": "zizmor",
      "upstream": {
        "releaseApi": "https://api.github.com/repos/woodruffw/zizmor/releases/latest",
        "pinType": "semver",
        "currentPin": "0.9.0"
      }
    }
  ]
}
'@ | Set-Content -LiteralPath $manifestPath -Encoding utf8 -NoNewline

        $global:GitCalls  = New-Object System.Collections.Generic.List[string]
        $global:GhCalls   = New-Object System.Collections.Generic.List[string]
        $global:PwshCalls = New-Object System.Collections.Generic.List[string]

        function git {
            param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Args)
            $cmd = ($Args -join ' ')
            $global:GitCalls.Add($cmd) | Out-Null
            switch -Regex ($cmd) {
                '^ls-remote --heads origin' { $global:LASTEXITCODE = 0; return @() }
                '^show-ref --verify --quiet' { $global:LASTEXITCODE = 1; return @() }
                default { $global:LASTEXITCODE = 0; return @() }
            }
        }

        function gh {
            param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Args)
            $cmd = ($Args -join ' ')
            $global:GhCalls.Add($cmd) | Out-Null
            if ($cmd -like 'pr list *') {
                $global:LASTEXITCODE = 0
                return ''  # no existing PR
            }
            $global:LASTEXITCODE = 0
            return 'https://github.com/martinopedal/azure-analyzer/pull/999'
        }

        function pwsh {
            param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Args)
            $global:PwshCalls.Add(($Args -join ' ')) | Out-Null
            $global:LASTEXITCODE = 0
            return @()
        }

        Mock Invoke-RestMethod {
            return [pscustomobject]@{ tag_name = 'v2.0.0'; body = 'minor improvements'; html_url = 'https://example.com/release' }
        }

        Push-Location $TestDrive
        try {
            & $script:ScriptPath -ManifestPath $manifestPath
        } finally {
            Pop-Location
            Remove-Item function:\git   -ErrorAction SilentlyContinue
            Remove-Item function:\gh    -ErrorAction SilentlyContinue
            Remove-Item function:\pwsh  -ErrorAction SilentlyContinue
        }

        # Exactly one branch created (batched)
        $branchCreates = $global:GitCalls | Where-Object { $_ -like 'checkout -b chore/bump-tool-pins-*' }
        $branchCreates.Count | Should -Be 1

        # Exactly one commit
        $commits = $global:GitCalls | Where-Object { $_ -like 'commit *' }
        $commits.Count | Should -Be 1

        # Exactly one PR created
        $prCreates = $global:GhCalls | Where-Object { $_ -like 'pr create *' }
        $prCreates.Count | Should -Be 1

        # Branch name matches expected pattern
        @($branchCreates)[0] | Should -Match 'chore/bump-tool-pins-\d{8}'
    }

    It 'reuses an existing remote batch branch and resets to origin/main (idempotent path)' {
        $manifestPath = Join-Path $TestDrive 'manifest-reuse.json'
        @'
{
  "tools": [
    {
      "name": "scorecard",
      "upstream": {
        "releaseApi": "https://api.github.com/repos/ossf/scorecard/releases/latest",
        "pinType": "semver",
        "currentPin": "1.0.0"
      }
    }
  ]
}
'@ | Set-Content -LiteralPath $manifestPath -Encoding utf8 -NoNewline

        $global:GitCalls  = New-Object System.Collections.Generic.List[string]
        $global:GhCalls   = New-Object System.Collections.Generic.List[string]
        $global:PwshCalls = New-Object System.Collections.Generic.List[string]
        $global:ExpectedBranch = "chore/bump-tool-pins-$(Get-Date -Format 'yyyyMMdd')"

        function git {
            param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Args)
            $cmd = ($Args -join ' ')
            $global:GitCalls.Add($cmd) | Out-Null
            switch -Regex ($cmd) {
                '^fetch origin main$'          { $global:LASTEXITCODE = 0; return @() }
                '^ls-remote --heads origin chore/bump-tool-pins-\d+$' {
                    $global:LASTEXITCODE = 0
                    return @("abc123 refs/heads/$($global:ExpectedBranch)")
                }
                '^show-ref --verify --quiet refs/heads/chore/bump-tool-pins-\d+$' {
                    $global:LASTEXITCODE = 1
                    return @()
                }
                default { $global:LASTEXITCODE = 0; return @() }
            }
        }

        function gh {
            param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Args)
            $cmd = ($Args -join ' ')
            $global:GhCalls.Add($cmd) | Out-Null
            if ($cmd -like 'pr list *') { $global:LASTEXITCODE = 0; return '341' }
            $global:LASTEXITCODE = 0
            return @()
        }

        function pwsh {
            param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Args)
            $global:PwshCalls.Add(($Args -join ' ')) | Out-Null
            $global:LASTEXITCODE = 0
            return @()
        }

        Mock Invoke-RestMethod {
            return [pscustomobject]@{ tag_name = 'v1.1.0'; body = 'minor improvements'; html_url = 'https://example.com' }
        }

        Push-Location $TestDrive
        try {
            & $script:ScriptPath -ManifestPath $manifestPath
        } finally {
            Pop-Location
            Remove-Item function:\git   -ErrorAction SilentlyContinue
            Remove-Item function:\gh    -ErrorAction SilentlyContinue
            Remove-Item function:\pwsh  -ErrorAction SilentlyContinue
        }

        $global:GitCalls | Should -Contain "checkout -B $($global:ExpectedBranch) origin/$($global:ExpectedBranch)"
        $global:GitCalls | Should -Contain 'reset --hard origin/main'
        ($global:GitCalls | Where-Object { $_ -eq "checkout -b $($global:ExpectedBranch)" }).Count | Should -Be 0
    }

    It 'invokes Generate-ToolCatalog, Generate-PermissionsIndex, AND Generate-ReadmeFacts once for the whole batch' {
        $manifestPath = Join-Path $TestDrive 'manifest-trifecta.json'
        @'
{
  "tools": [
    {
      "name": "scorecard",
      "upstream": {
        "releaseApi": "https://api.github.com/repos/ossf/scorecard/releases/latest",
        "pinType": "semver",
        "currentPin": "1.0.0"
      }
    },
    {
      "name": "zizmor",
      "upstream": {
        "releaseApi": "https://api.github.com/repos/woodruffw/zizmor/releases/latest",
        "pinType": "semver",
        "currentPin": "0.9.0"
      }
    }
  ]
}
'@ | Set-Content -LiteralPath $manifestPath -Encoding utf8 -NoNewline

        $global:GitCalls  = New-Object System.Collections.Generic.List[string]
        $global:GhCalls   = New-Object System.Collections.Generic.List[string]
        $global:PwshCalls = New-Object System.Collections.Generic.List[string]

        function git {
            param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Args)
            $cmd = ($Args -join ' ')
            $global:GitCalls.Add($cmd) | Out-Null
            switch -Regex ($cmd) {
                '^ls-remote --heads origin' { $global:LASTEXITCODE = 0; return @() }
                '^show-ref --verify --quiet' { $global:LASTEXITCODE = 1; return @() }
                default { $global:LASTEXITCODE = 0; return @() }
            }
        }

        function gh {
            param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Args)
            $cmd = ($Args -join ' ')
            $global:GhCalls.Add($cmd) | Out-Null
            if ($cmd -like 'pr list *') { $global:LASTEXITCODE = 0; return '' }
            $global:LASTEXITCODE = 0
            return 'https://github.com/martinopedal/azure-analyzer/pull/999'
        }

        function pwsh {
            param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Args)
            $global:PwshCalls.Add(($Args -join ' ')) | Out-Null
            $global:LASTEXITCODE = 0
            return @()
        }

        Mock Invoke-RestMethod {
            return [pscustomobject]@{ tag_name = 'v2.0.0'; body = 'minor'; html_url = 'https://example.com' }
        }

        Push-Location $TestDrive
        try {
            & $script:ScriptPath -ManifestPath $manifestPath
        } finally {
            Pop-Location
            Remove-Item function:\git   -ErrorAction SilentlyContinue
            Remove-Item function:\gh    -ErrorAction SilentlyContinue
            Remove-Item function:\pwsh  -ErrorAction SilentlyContinue
        }

        # Each generator called exactly ONCE regardless of how many tools changed
        ($global:PwshCalls | Where-Object { $_ -match 'Generate-ToolCatalog\.ps1' }).Count     | Should -Be 1
        ($global:PwshCalls | Where-Object { $_ -match 'Generate-PermissionsIndex\.ps1' }).Count | Should -Be 1
        ($global:PwshCalls | Where-Object { $_ -match 'Generate-ReadmeFacts\.ps1' }).Count      | Should -Be 1

        $stagedFiles = ($global:GitCalls | Where-Object { $_ -like 'add *' }) -join ' '
        $stagedFiles | Should -Match 'tool-catalog\.md'
        $stagedFiles | Should -Match 'PERMISSIONS\.md'
        $stagedFiles | Should -Match 'README\.md'
    }

    It 'applies breaking-change label when any tool in the batch trips the heuristic' {
        $manifestPath = Join-Path $TestDrive 'manifest-breaking.json'
        @'
{
  "tools": [
    {
      "name": "trivy",
      "upstream": {
        "releaseApi": "https://api.github.com/repos/aquasecurity/trivy/releases/latest",
        "pinType": "semver",
        "currentPin": "0.50.0"
      }
    }
  ]
}
'@ | Set-Content -LiteralPath $manifestPath -Encoding utf8 -NoNewline

        $global:GitCalls = New-Object System.Collections.Generic.List[string]
        $global:GhCalls  = New-Object System.Collections.Generic.List[string]

        function git {
            param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Args)
            $global:GitCalls.Add(($Args -join ' ')) | Out-Null
            switch -Regex ($Args -join ' ') {
                '^ls-remote' { $global:LASTEXITCODE = 0; return @() }
                '^show-ref'  { $global:LASTEXITCODE = 1; return @() }
                default      { $global:LASTEXITCODE = 0; return @() }
            }
        }

        function gh {
            param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Args)
            $global:GhCalls.Add(($Args -join ' ')) | Out-Null
            if (($Args -join ' ') -like 'pr list *') { $global:LASTEXITCODE = 0; return '' }
            $global:LASTEXITCODE = 0
            return 'https://github.com/martinopedal/azure-analyzer/pull/888'
        }

        function pwsh {
            param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Args)
            $global:LASTEXITCODE = 0
        }

        Mock Invoke-RestMethod {
            return [pscustomobject]@{
                tag_name = 'v0.60.0'
                body = 'BREAKING: removed flag --exit-code-skip-update'
                html_url = 'https://example.com'
            }
        }

        Push-Location $TestDrive
        try {
            & $script:ScriptPath -ManifestPath $manifestPath
        } finally {
            Pop-Location
            Remove-Item function:\git  -ErrorAction SilentlyContinue
            Remove-Item function:\gh   -ErrorAction SilentlyContinue
            Remove-Item function:\pwsh -ErrorAction SilentlyContinue
        }

        $labelCall = $global:GhCalls | Where-Object { $_ -match 'needs-copilot-iteration' }
        $labelCall | Should -Not -BeNullOrEmpty -Because 'breaking-change tool must trigger the needs-copilot-iteration label'
    }

    It '-DryRun reports bumps but does NOT touch git or open a PR' {
        $manifestPath = Join-Path $TestDrive 'manifest-dryrun.json'
        @'
{
  "tools": [
    {
      "name": "scorecard",
      "upstream": {
        "releaseApi": "https://api.github.com/repos/ossf/scorecard/releases/latest",
        "pinType": "semver",
        "currentPin": "1.0.0"
      }
    }
  ]
}
'@ | Set-Content -LiteralPath $manifestPath -Encoding utf8 -NoNewline

        $global:GitCalls = New-Object System.Collections.Generic.List[string]
        $global:GhCalls  = New-Object System.Collections.Generic.List[string]

        function git {
            param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Args)
            $global:GitCalls.Add(($Args -join ' ')) | Out-Null
            $global:LASTEXITCODE = 0
        }

        function gh {
            param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Args)
            $global:GhCalls.Add(($Args -join ' ')) | Out-Null
            $global:LASTEXITCODE = 0
        }

        Mock Invoke-RestMethod {
            return [pscustomobject]@{ tag_name = 'v2.0.0'; body = ''; html_url = 'https://example.com' }
        }

        Push-Location $TestDrive
        try {
            & $script:ScriptPath -ManifestPath $manifestPath -DryRun
        } finally {
            Pop-Location
            Remove-Item function:\git -ErrorAction SilentlyContinue
            Remove-Item function:\gh  -ErrorAction SilentlyContinue
        }

        $global:GitCalls | Where-Object { $_ -like 'checkout*' } | Should -BeNullOrEmpty
        $global:GhCalls  | Where-Object { $_ -like 'pr create*' } | Should -BeNullOrEmpty
    }
}
