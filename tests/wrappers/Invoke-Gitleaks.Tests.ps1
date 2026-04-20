#Requires -Version 7.4
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

BeforeAll {
    $script:Here = Split-Path $PSCommandPath -Parent
    $script:RepoRoot = Resolve-Path (Join-Path $script:Here '..' '..')
    $script:Wrapper = Join-Path $script:RepoRoot 'modules' 'Invoke-Gitleaks.ps1'
}
$script:GitleaksInstalled = $null -ne (Microsoft.PowerShell.Core\Get-Command gitleaks -ErrorAction SilentlyContinue)

Describe 'Invoke-Gitleaks' {
    Context 'when gitleaks CLI is missing' {
        BeforeAll {
            if (-not $script:GitleaksInstalled) {
                $result = & $script:Wrapper
            }
        }

        It 'returns Status = Skipped' -Skip:$script:GitleaksInstalled {
            $result.Status | Should -Be 'Skipped'
        }

        It 'returns empty Findings' -Skip:$script:GitleaksInstalled {
            @($result.Findings).Count | Should -Be 0
        }

        It 'includes message about gitleaks not installed' -Skip:$script:GitleaksInstalled {
            $result.Message | Should -Match 'not installed'
        }

        It 'sets Source to gitleaks' -Skip:$script:GitleaksInstalled {
            $result.Source | Should -Be 'gitleaks'
        }

        It 'includes SchemaVersion 1.0 in the v1 envelope' -Skip:$script:GitleaksInstalled {
            $result.SchemaVersion | Should -Be '1.0'
        }
    }

    Context 'configuration path behavior' {
        BeforeEach {
            $script:TestRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("gitleaks-tests-" + [guid]::NewGuid().ToString('N'))
            $null = New-Item -ItemType Directory -Path $script:TestRoot -Force
            $script:RepoPath = Join-Path $script:TestRoot 'repo'
            $null = New-Item -ItemType Directory -Path $script:RepoPath -Force
            Set-Content -Path (Join-Path $script:RepoPath 'README.md') -Value 'fixture' -Encoding UTF8

            $global:CapturedArgs = @()
            function global:gitleaks {
                param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Args)
                $global:CapturedArgs = @($Args)
                $idx = [Array]::IndexOf($Args, '--report-path')
                if ($idx -ge 0) {
                    Set-Content -Path $Args[$idx + 1] -Value '[]' -Encoding UTF8
                }
                $global:LASTEXITCODE = 0
            }

        }

        AfterEach {
            Remove-Item Function:\gitleaks -ErrorAction SilentlyContinue
            Remove-Variable -Name CapturedArgs -Scope Global -ErrorAction SilentlyContinue
            if ($script:TestRoot -and (Test-Path $script:TestRoot)) {
                Remove-Item -Path $script:TestRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }

        It 'invokes gitleaks without --config when no config path is provided' {
            $result = & $script:Wrapper -RepoPath $script:RepoPath

            $result.Status | Should -Be 'Success'
            $global:CapturedArgs | Should -Contain '--report-path'
            $global:CapturedArgs | Should -Not -Contain '--config'
        }

        It 'passes --config when a valid config path is provided' {
            $configPath = Join-Path $script:TestRoot 'custom-rules.toml'
            Set-Content -Path $configPath -Value @'
[extend]
useDefault = true
'@ -Encoding UTF8

            $result = & $script:Wrapper -RepoPath $script:RepoPath -GitleaksConfigPath $configPath
            $resolvedConfigPath = (Resolve-Path $configPath).Path
            $configIndex = [Array]::IndexOf($global:CapturedArgs, '--config')

            $result.Status | Should -Be 'Success'
            $configIndex | Should -BeGreaterThan -1
            $global:CapturedArgs[$configIndex + 1] | Should -Be $resolvedConfigPath
        }

        It 'throws a clear error when config path does not exist' {
            $missingPath = Join-Path $script:TestRoot 'missing.toml'
            {
                & $script:Wrapper -RepoPath $script:RepoPath -GitleaksConfigPath $missingPath
            } | Should -Throw '*Gitleaks config file not found*'
        }

        It 'emits High finding when defaults are disabled without custom rules' {
            $configPath = Join-Path $script:TestRoot 'disable-defaults.toml'
            Set-Content -Path $configPath -Value @'
[extend]
useDefault = false
'@ -Encoding UTF8

            $result = & $script:Wrapper -RepoPath $script:RepoPath -GitleaksConfigPath $configPath
            $highFinding = @($result.Findings | Where-Object { $_.Title -eq 'Gitleaks pattern override disables all built-in rules' } | Select-Object -First 1)

            $result.Status | Should -Be 'Success'
            @($highFinding).Count | Should -Be 1
            $highFinding[0].Severity | Should -Be 'High'
        }

        It 'emits Info finding for custom config with sanitized path details' {
            $sensitiveName = 'allowlist-sig=abcdefghijklmnopqrstuvwxyz123456.toml'
            $configPath = Join-Path $script:TestRoot $sensitiveName
            Set-Content -Path $configPath -Value @'
[extend]
useDefault = true
'@ -Encoding UTF8

            $result = & $script:Wrapper -RepoPath $script:RepoPath -GitleaksConfigPath $configPath
            $infoFinding = @($result.Findings | Where-Object { $_.Title -eq 'Custom gitleaks config applied' } | Select-Object -First 1)

            @($infoFinding).Count | Should -Be 1
            $infoFinding[0].Severity | Should -Be 'Info'
            $infoFinding[0].Detail | Should -Match 'sig=\[REDACTED\]'
            $infoFinding[0].Detail | Should -Not -Match 'sig=abcdefghijklmnopqrstuvwxyz123456'
        }
    }
}
