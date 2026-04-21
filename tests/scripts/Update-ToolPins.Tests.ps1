#requires -Version 7.0
#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }

Describe 'Update-ToolPins' {
    BeforeAll {
        $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
        $script:ScriptPath = Join-Path $script:RepoRoot 'tools\Update-ToolPins.ps1'
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

        function global:git {
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

        function global:gh {
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
            Remove-Item function:\global\git -ErrorAction SilentlyContinue
            Remove-Item function:\global\gh -ErrorAction SilentlyContinue
        }

        $global:GitCalls | Should -Contain 'checkout -B chore/bump-scorecard-1.1.0 origin/chore/bump-scorecard-1.1.0'
        $global:GitCalls | Should -Contain 'reset --hard origin/main'
        ($global:GitCalls | Where-Object { $_ -eq 'checkout -b chore/bump-scorecard-1.1.0' }).Count | Should -Be 0

        Remove-Variable -Name GitCalls, GhCalls -Scope Global -ErrorAction SilentlyContinue
    }
}
