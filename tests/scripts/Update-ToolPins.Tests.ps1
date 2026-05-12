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

    It 'reuses an existing remote branch and resets to origin/main (idempotent path)' {
        $manifestPath = Join-Path $TestDrive 'tool-manifest.json'
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
        $global:GhCalls = New-Object System.Collections.Generic.List[string]
        $global:PwshCalls = New-Object System.Collections.Generic.List[string]

        function git {
            param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Args)
            $cmd = ($Args -join ' ')
            $global:GitCalls.Add($cmd) | Out-Null

            switch -Regex ($cmd) {
                '^fetch origin main$' {
                    $global:LASTEXITCODE = 0
                    return @()
                }
                '^ls-remote --heads origin chore/bump-scorecard-1\.1\.0$' {
                    $global:LASTEXITCODE = 0
                    return @('abc123 refs/heads/chore/bump-scorecard-1.1.0')
                }
                '^show-ref --verify --quiet refs/heads/chore/bump-scorecard-1\.1\.0$' {
                    $global:LASTEXITCODE = 1
                    return @()
                }
                default {
                    $global:LASTEXITCODE = 0
                    return @()
                }
            }
        }

        function gh {
            param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Args)
            $cmd = ($Args -join ' ')
            $global:GhCalls.Add($cmd) | Out-Null

            if ($cmd -eq 'pr list --head chore/bump-scorecard-1.1.0 --base main --state open --json number --jq .[0].number') {
                $global:LASTEXITCODE = 0
                return '341'
            }

            $global:LASTEXITCODE = 0
            return @()
        }

        # Capture every external pwsh invocation so we can assert that
        # Update-ToolPins regenerates BOTH the tool catalog AND the permissions
        # index AND the README facts in lockstep with the manifest write. Without
        # this every bump leaves docs-check (catalog/permissions/readme) red.
        function pwsh {
            param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Args)
            $cmd = ($Args -join ' ')
            $global:PwshCalls.Add($cmd) | Out-Null
            $global:LASTEXITCODE = 0
            return @()
        }

        Mock Invoke-RestMethod {
            return [pscustomobject]@{
                tag_name = 'v1.1.0'
                body = 'minor improvements'
                html_url = 'https://example.com/release'
            }
        }

        Push-Location $TestDrive
        try {
            & $script:ScriptPath -ManifestPath $manifestPath
        } finally {
            Pop-Location
            Remove-Item function:\git -ErrorAction SilentlyContinue
            Remove-Item function:\gh -ErrorAction SilentlyContinue
            Remove-Item function:\pwsh -ErrorAction SilentlyContinue
        }

        $global:GitCalls | Should -Contain 'checkout -B chore/bump-scorecard-1.1.0 origin/chore/bump-scorecard-1.1.0'
        $global:GitCalls | Should -Contain 'reset --hard origin/main'
        ($global:GitCalls | Where-Object { $_ -eq 'checkout -b chore/bump-scorecard-1.1.0' }).Count | Should -Be 0
    }

    It 'invokes Generate-ToolCatalog, Generate-PermissionsIndex, AND Generate-ReadmeFacts after the manifest write' {
        $manifestPath = Join-Path $TestDrive 'tool-manifest-trifecta.json'
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
            $global:GhCalls.Add(($Args -join ' ')) | Out-Null
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
            return [pscustomobject]@{
                tag_name = 'v1.2.0'
                body = 'minor improvements'
                html_url = 'https://example.com/release'
            }
        }

        Push-Location $TestDrive
        try {
            & $script:ScriptPath -ManifestPath $manifestPath
        } finally {
            Pop-Location
            Remove-Item function:\git -ErrorAction SilentlyContinue
            Remove-Item function:\gh -ErrorAction SilentlyContinue
            Remove-Item function:\pwsh -ErrorAction SilentlyContinue
        }

        $catalogCall     = $global:PwshCalls | Where-Object { $_ -match 'Generate-ToolCatalog\.ps1' }
        $permissionsCall = $global:PwshCalls | Where-Object { $_ -match 'Generate-PermissionsIndex\.ps1' }
        $readmeCall      = $global:PwshCalls | Where-Object { $_ -match 'Generate-ReadmeFacts\.ps1' }

        $catalogCall     | Should -Not -BeNullOrEmpty -Because 'Generate-ToolCatalog must run after manifest write so catalogs stay in sync'
        $permissionsCall | Should -Not -BeNullOrEmpty -Because 'Generate-PermissionsIndex must run after manifest write so PERMISSIONS.md and per-tool stubs stay in sync'
        $readmeCall      | Should -Not -BeNullOrEmpty -Because 'Generate-ReadmeFacts must run after manifest write so README tool counts stay in sync'

        # All three must be staged into the same atomic commit alongside the manifest.
        $stagedFiles = ($global:GitCalls | Where-Object { $_ -like 'add *' }) -join ' '
        $stagedFiles | Should -Match 'tool-catalog\.md'
        $stagedFiles | Should -Match 'PERMISSIONS\.md'
        $stagedFiles | Should -Match 'README\.md'
    }
}

