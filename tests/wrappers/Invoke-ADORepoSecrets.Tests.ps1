#Requires -Version 7.4
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

BeforeAll {
    $script:Here = Split-Path $PSCommandPath -Parent
    $script:RepoRoot = Resolve-Path (Join-Path $script:Here '..' '..')
    $script:Wrapper = Join-Path $script:RepoRoot 'modules' 'Invoke-ADORepoSecrets.ps1'
    . (Join-Path $script:RepoRoot 'modules' 'shared' 'Sanitize.ps1')
    . (Join-Path $script:RepoRoot 'modules' 'shared' 'Retry.ps1')
    . (Join-Path $script:RepoRoot 'modules' 'shared' 'RemoteClone.ps1')
    . (Join-Path $script:RepoRoot 'modules' 'shared' 'Installer.ps1')
}

Describe 'Invoke-ADORepoSecrets' {
    Context 'when ADO PAT is missing' {
        BeforeAll {
            Remove-Item Env:\ADO_PAT_TOKEN -ErrorAction SilentlyContinue
            Remove-Item Env:\AZURE_DEVOPS_EXT_PAT -ErrorAction SilentlyContinue
            Remove-Item Env:\AZ_DEVOPS_PAT -ErrorAction SilentlyContinue
            Mock Get-Command { [PSCustomObject]@{ Name = 'gitleaks' } } -ParameterFilter { $Name -eq 'gitleaks' }
            $result = & $script:Wrapper -AdoOrg 'contoso'
        }

        It 'returns Status = Skipped' {
            $result.Status | Should -Be 'Skipped'
            @($result.Findings).Count | Should -Be 0
        }
    }

    Context 'when repos have no secret findings' {
        BeforeAll {
            $env:ADO_PAT_TOKEN = 'fake-token'
            Mock Get-Command {
                if ($Name -eq 'gitleaks') { return [PSCustomObject]@{ Name = 'gitleaks' } }
                if ($Name -eq 'Invoke-WithTimeout') { return $null }
                return $null
            }
            Mock Invoke-RemoteRepoClone { [PSCustomObject]@{ Path = 'C:\repos\fake'; Cleanup = ({}) } }
            $global:GitleaksPayload = '[]'
            function global:gitleaks {
                param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Args)
                $idx = [Array]::IndexOf($Args, '--report-path')
                if ($idx -ge 0) {
                    Set-Content -Path $Args[$idx + 1] -Value $global:GitleaksPayload -Encoding UTF8
                }
                $global:LASTEXITCODE = 0
            }
            Mock Invoke-WebRequest {
                param([string]$Uri)
                $body = switch -Regex ($Uri) {
                    '_apis/projects' { '{"value":[{"name":"payments","id":"proj-1"}]}' }
                    '_apis/git/repositories' { '{"value":[{"name":"payments-api","id":"repo-1"}]}' }
                    default { throw \"Unexpected URI: $Uri\" }
                }
                [PSCustomObject]@{ Content = $body; Headers = @{} }
            }
            $result = & $script:Wrapper -AdoOrg 'contoso'
        }

        AfterAll {
            Remove-Item Function:\gitleaks -ErrorAction SilentlyContinue
            Remove-Variable -Name GitleaksPayload -Scope Global -ErrorAction SilentlyContinue
            Remove-Item Env:\ADO_PAT_TOKEN -ErrorAction SilentlyContinue
        }

        It 'returns Success with zero findings' {
            $result.Status | Should -Be 'Success'
            @($result.Findings).Count | Should -Be 0
        }
    }

    Context 'when custom gitleaks config is provided' {
        BeforeAll {
            $env:ADO_PAT_TOKEN = 'fake-token'
            $script:ConfigRoot = Join-Path ([System.IO.Path]::GetTempPath()) "ado-gitleaks-config-$([guid]::NewGuid().ToString('N'))"
            $null = New-Item -ItemType Directory -Path $script:ConfigRoot -Force
            $script:ConfigPath = Join-Path $script:ConfigRoot 'ado-allowlist.toml'
            Set-Content -Path $script:ConfigPath -Value @'
[extend]
useDefault = true
'@ -Encoding UTF8

            Mock Get-Command {
                if ($Name -eq 'gitleaks') { return [PSCustomObject]@{ Name = 'gitleaks' } }
                if ($Name -eq 'Invoke-WithTimeout') { return $null }
                return $null
            }
            Mock Invoke-RemoteRepoClone { [PSCustomObject]@{ Path = 'C:\repos\fake'; Cleanup = ({}) } }
            $global:CapturedGitleaksArgs = @()
            function global:gitleaks {
                param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Args)
                $global:CapturedGitleaksArgs = @($Args)
                $idx = [Array]::IndexOf($Args, '--report-path')
                if ($idx -ge 0) {
                    Set-Content -Path $Args[$idx + 1] -Value '[]' -Encoding UTF8
                }
                $global:LASTEXITCODE = 0
            }
            Mock Invoke-WebRequest {
                param([string]$Uri)
                $body = switch -Regex ($Uri) {
                    '_apis/projects' { '{"value":[{"name":"payments","id":"proj-1"}]}' }
                    '_apis/git/repositories' { '{"value":[{"name":"payments-api","id":"repo-1"}]}' }
                    default { throw \"Unexpected URI: $Uri\" }
                }
                [PSCustomObject]@{ Content = $body; Headers = @{} }
            }
            $result = & $script:Wrapper -AdoOrg 'contoso' -GitleaksConfigPath $script:ConfigPath
        }

        AfterAll {
            Remove-Item Function:\gitleaks -ErrorAction SilentlyContinue
            Remove-Variable -Name CapturedGitleaksArgs -Scope Global -ErrorAction SilentlyContinue
            Remove-Item Env:\ADO_PAT_TOKEN -ErrorAction SilentlyContinue
            if ($script:ConfigRoot -and (Test-Path $script:ConfigRoot)) {
                Remove-Item -Path $script:ConfigRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }

        It 'forwards --config to gitleaks invocation' {
            $configIndex = [Array]::IndexOf($global:CapturedGitleaksArgs, '--config')
            $configIndex | Should -BeGreaterThan -1
            $global:CapturedGitleaksArgs[$configIndex + 1] | Should -Be ((Resolve-Path $script:ConfigPath).Path)
        }

        It 'emits info finding for the applied config' {
            $infoFinding = @($result.Findings | Where-Object { $_.Title -eq 'Custom gitleaks config applied' } | Select-Object -First 1)
            @($infoFinding).Count | Should -Be 1
            $infoFinding[0].Severity | Should -Be 'Info'
        }
    }

    Context 'when gitleaks finds multiple secrets' {
        BeforeAll {
            $env:ADO_PAT_TOKEN = 'fake-token'
            $outputFile = Join-Path ([System.IO.Path]::GetTempPath()) "ado-secrets-$([guid]::NewGuid().ToString('N')).json"
            Mock Get-Command {
                if ($Name -eq 'gitleaks') { return [PSCustomObject]@{ Name = 'gitleaks' } }
                if ($Name -eq 'Invoke-WithTimeout') { return $null }
                return $null
            }
            Mock Invoke-RemoteRepoClone { [PSCustomObject]@{ Path = 'C:\repos\fake'; Cleanup = ({}) } }
            $global:GitleaksPayload = @(
                @{ RuleID='github-pat'; Description='GitHub PAT'; File='src/appsettings.json'; StartLine=7; Commit='aaaaaaaa11111111'; Fingerprint='fp-1'; Tags=@('secret') },
                @{ RuleID='azure-client-secret'; Description='Azure Secret'; File='infra/main.tf'; StartLine=19; Commit='bbbbbbbb22222222'; Fingerprint='fp-2'; Tags=@('secret') }
            ) | ConvertTo-Json -Depth 10
            function global:gitleaks {
                param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Args)
                $idx = [Array]::IndexOf($Args, '--report-path')
                if ($idx -ge 0) {
                    Set-Content -Path $Args[$idx + 1] -Value $global:GitleaksPayload -Encoding UTF8
                }
                $global:LASTEXITCODE = 0
            }
            Mock Invoke-WebRequest {
                param([string]$Uri)
                $body = switch -Regex ($Uri) {
                    '_apis/projects' { '{"value":[{"name":"payments","id":"proj-1"}]}' }
                    '_apis/git/repositories' { '{"value":[{"name":"payments-api","id":"repo-1"}]}' }
                    default { throw \"Unexpected URI: $Uri\" }
                }
                [PSCustomObject]@{ Content = $body; Headers = @{} }
            }
            $result = & $script:Wrapper -AdoOrg 'contoso' -OutputPath $outputFile
            $saved = @()
            if (Test-Path $outputFile) {
                $saved = Get-Content -Path $outputFile -Raw | ConvertFrom-Json
            }
            Remove-Item -Path $outputFile -Force -ErrorAction SilentlyContinue
        }

        AfterAll {
            Remove-Item Function:\gitleaks -ErrorAction SilentlyContinue
            Remove-Variable -Name GitleaksPayload -Scope Global -ErrorAction SilentlyContinue
            Remove-Item Env:\ADO_PAT_TOKEN -ErrorAction SilentlyContinue
        }

        It 'returns secret findings including commit/file/type metadata' {
            $result.Status | Should -Be 'Success'
            @($result.Findings).Count | Should -Be 2
            $result.Findings[0].CommitSha | Should -Not -BeNullOrEmpty
            $result.Findings[0].FilePath | Should -Match 'src/appsettings.json'
            $result.Findings[0].SecretType | Should -Be 'github-pat'
        }

        It 'writes downstream findings file when OutputPath is provided' {
            @($saved).Count | Should -Be 2
            $saved[0].CommitSha | Should -Not -BeNullOrEmpty
        }
    }
}
