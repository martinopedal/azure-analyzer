#Requires -Version 7.4
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

BeforeAll {
    $script:Here = Split-Path $PSCommandPath -Parent
    $script:RepoRoot = Resolve-Path (Join-Path $script:Here '..' '..')
    $script:Wrapper = Join-Path $script:RepoRoot 'modules' 'Invoke-ADORepoSecrets.ps1'
    $global:AdoMixedFixture = Get-Content (Join-Path $script:RepoRoot 'tests' 'fixtures' 'ado-mixed-access-projects.json') -Raw | ConvertFrom-Json -Depth 20
    . (Join-Path $script:RepoRoot 'modules' 'shared' 'Sanitize.ps1')
    . (Join-Path $script:RepoRoot 'modules' 'shared' 'Retry.ps1')
    . (Join-Path $script:RepoRoot 'modules' 'shared' 'RemoteClone.ps1')
    . (Join-Path $script:RepoRoot 'modules' 'shared' 'Installer.ps1')

    function New-TestHttpException {
        param(
            [int]$StatusCode,
            [string]$Message
        )
        $ex = [System.Exception]::new($Message)
        $ex | Add-Member -NotePropertyName Response -NotePropertyValue ([PSCustomObject]@{ StatusCode = $StatusCode }) -Force
        return $ex
    }
}

Describe 'Invoke-ADORepoSecrets' {
    BeforeEach {
        Remove-Item Env:\ADO_PAT_TOKEN -ErrorAction SilentlyContinue
        Remove-Item Env:\AZURE_DEVOPS_EXT_PAT -ErrorAction SilentlyContinue
        Remove-Item Env:\AZ_DEVOPS_PAT -ErrorAction SilentlyContinue
        Remove-Item Function:\gitleaks -ErrorAction SilentlyContinue
        Remove-Variable -Name GitleaksPayload -Scope Global -ErrorAction SilentlyContinue
    }

    Context 'when ADO PAT is missing' {
        BeforeAll {
            Mock Get-Command { [PSCustomObject]@{ Name = 'gitleaks' } } -ParameterFilter { $Name -eq 'gitleaks' }
            $result = & $script:Wrapper -AdoOrg 'contoso'
        }

        It 'returns Status = Skipped' {
            $result.Status | Should -Be 'Skipped'
            @($result.Findings).Count | Should -Be 0
        }
    }

    Context 'all repos accessible' {
        BeforeAll {
            $env:ADO_PAT_TOKEN = 'fake-token'
            Mock Get-Command {
                param([string]$Name)
                if ($Name -eq 'gitleaks') { return [PSCustomObject]@{ Name = 'gitleaks' } }
                if ($Name -eq 'Invoke-WithTimeout') { return $null }
                return $null
            }
            Mock Invoke-WebRequest {
                param([string]$Uri)
                if ($Uri -match '_apis/projects') {
                    $projects = @($global:AdoMixedFixture.projects | ForEach-Object { @{ name = $_.name; id = $_.id } })
                    return [PSCustomObject]@{ Content = (@{ value = $projects } | ConvertTo-Json -Depth 10); Headers = @{} }
                }

                if ($Uri -match '_apis/git/repositories') {
                    $projectName = if ($Uri -match '/payments/') { 'payments' } else { 'identity' }
                    $project = @($global:AdoMixedFixture.projects | Where-Object { $_.name -eq $projectName })[0]
                    $repos = @($project.repos | ForEach-Object { @{ name = $_.name; id = $_.id } })
                    return [PSCustomObject]@{ Content = (@{ value = $repos } | ConvertTo-Json -Depth 10); Headers = @{} }
                }
                throw "Unexpected URI: $Uri"
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
            $result = & $script:Wrapper -AdoOrg 'contoso'
        }

        AfterAll {
            Remove-Item Env:\ADO_PAT_TOKEN -ErrorAction SilentlyContinue
            Remove-Item Function:\gitleaks -ErrorAction SilentlyContinue
            Remove-Variable -Name GitleaksPayload -Scope Global -ErrorAction SilentlyContinue
        }

        It 'scans all repos with no per-repo skip findings' {
            $result.Status | Should -Be 'Success' -Because $result.Message
            @($result.Findings | Where-Object { $_.Title -in @('ADO repo inaccessible - skipped', 'ADO repo not found - skipped', 'ADO repo clone failed - skipped', 'ADO repo clone timed out - skipped') }).Count | Should -Be 0
            @($result.Findings | Where-Object { $_.Title -like 'ADO scan completed:*3/3*' }).Count | Should -Be 1
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
                    default { throw "Unexpected URI: $Uri" }
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

    Context 'one repo returns 403 while others are scanned' {
        BeforeAll {
            $env:ADO_PAT_TOKEN = 'fake-token'
            Mock Get-Command {
                param([string]$Name)
                if ($Name -eq 'gitleaks') { return [PSCustomObject]@{ Name = 'gitleaks' } }
                if ($Name -eq 'Invoke-WithTimeout') { return $null }
                return $null
            }
            Mock Invoke-WebRequest {
                param([string]$Uri)
                if ($Uri -match '_apis/projects') {
                    $projects = @($global:AdoMixedFixture.projects | ForEach-Object { @{ name = $_.name; id = $_.id } })
                    return [PSCustomObject]@{ Content = (@{ value = $projects } | ConvertTo-Json -Depth 10); Headers = @{} }
                }

                if ($Uri -match '_apis/git/repositories') {
                    $projectName = if ($Uri -match '/payments/') { 'payments' } else { 'identity' }
                    $project = @($global:AdoMixedFixture.projects | Where-Object { $_.name -eq $projectName })[0]
                    $repos = @($project.repos | ForEach-Object { @{ name = $_.name; id = $_.id } })
                    return [PSCustomObject]@{ Content = (@{ value = $repos } | ConvertTo-Json -Depth 10); Headers = @{} }
                }
                throw "Unexpected URI: $Uri"
            }
            Mock Invoke-RemoteRepoClone {
                if ($RepoUrl -match 'payments-admin') {
                    throw (New-TestHttpException -StatusCode 403 -Message 'Forbidden for private repo')
                }
                [PSCustomObject]@{ Path = 'C:\repos\fake'; Cleanup = ({}) }
            }
            $global:GitleaksPayload = '[]'
            function global:gitleaks {
                param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Args)
                $idx = [Array]::IndexOf($Args, '--report-path')
                if ($idx -ge 0) {
                    Set-Content -Path $Args[$idx + 1] -Value $global:GitleaksPayload -Encoding UTF8
                }
                $global:LASTEXITCODE = 0
            }
            $result = & $script:Wrapper -AdoOrg 'contoso'
        }

        AfterAll {
            Remove-Item Env:\ADO_PAT_TOKEN -ErrorAction SilentlyContinue
            Remove-Item Function:\gitleaks -ErrorAction SilentlyContinue
            Remove-Variable -Name GitleaksPayload -Scope Global -ErrorAction SilentlyContinue
        }

        It 'skips the inaccessible repo and completes successfully' {
            $result.Status | Should -Be 'Success' -Because $result.Message
            @($result.Findings | Where-Object { $_.Title -eq 'ADO repo inaccessible - skipped' -and $_.Severity -eq 'Info' }).Count | Should -Be 1
            @($result.Findings | Where-Object { $_.Title -like 'ADO scan completed:*2/3*' }).Count | Should -Be 1
        }
    }

    Context 'all repos are inaccessible' {
        BeforeAll {
            $env:ADO_PAT_TOKEN = 'fake-token'
            Mock Get-Command {
                param([string]$Name)
                if ($Name -eq 'gitleaks') { return [PSCustomObject]@{ Name = 'gitleaks' } }
                if ($Name -eq 'Invoke-WithTimeout') { return $null }
                return $null
            }
            Mock Invoke-WebRequest {
                param([string]$Uri)
                if ($Uri -match '_apis/projects') {
                    $projects = @($global:AdoMixedFixture.projects | ForEach-Object { @{ name = $_.name; id = $_.id } })
                    return [PSCustomObject]@{ Content = (@{ value = $projects } | ConvertTo-Json -Depth 10); Headers = @{} }
                }

                if ($Uri -match '_apis/git/repositories') {
                    $projectName = if ($Uri -match '/payments/') { 'payments' } else { 'identity' }
                    $project = @($global:AdoMixedFixture.projects | Where-Object { $_.name -eq $projectName })[0]
                    $repos = @($project.repos | ForEach-Object { @{ name = $_.name; id = $_.id } })
                    return [PSCustomObject]@{ Content = (@{ value = $repos } | ConvertTo-Json -Depth 10); Headers = @{} }
                }
                throw "Unexpected URI: $Uri"
            }
            Mock Invoke-RemoteRepoClone { throw (New-TestHttpException -StatusCode 403 -Message 'Forbidden for private repo') }
            $result = & $script:Wrapper -AdoOrg 'contoso'
        }

        AfterAll {
            Remove-Item Env:\ADO_PAT_TOKEN -ErrorAction SilentlyContinue
        }

        It 'emits Info findings for each inaccessible repo and remains successful' {
            $result.Status | Should -Be 'Success' -Because $result.Message
            @($result.Findings | Where-Object { $_.Title -eq 'ADO repo inaccessible - skipped' }).Count | Should -Be 3
            @($result.Findings | Where-Object { $_.Title -like 'ADO scan completed:*0/3*' }).Count | Should -Be 1
        }
    }

    Context 'error output is sanitized before writing to disk' {
        BeforeAll {
            $env:ADO_PAT_TOKEN = 'fake-token'
            $outputFile = Join-Path $script:Here "ado-secrets-sanitize-$([guid]::NewGuid().ToString('N')).json"
            Mock Get-Command {
                param([string]$Name)
                if ($Name -eq 'gitleaks') { return [PSCustomObject]@{ Name = 'gitleaks' } }
                if ($Name -eq 'Invoke-WithTimeout') { return $null }
                return $null
            }
            Mock Remove-Credentials {
                param([string]$Text)
                if ($null -eq $Text) { return $Text }
                return ($Text -replace 'sensitive-token', '***')
            }
            Mock Invoke-WebRequest {
                param([string]$Uri)
                if ($Uri -match '_apis/projects') {
                    return [PSCustomObject]@{ Content = '{"value":[{"name":"payments","id":"proj-1"}]}'; Headers = @{} }
                }
                if ($Uri -match '_apis/git/repositories') {
                    return [PSCustomObject]@{ Content = '{"value":[{"name":"payments-api","id":"repo-1"}]}'; Headers = @{} }
                }
                throw "Unexpected URI: $Uri"
            }
            Mock Invoke-RemoteRepoClone {
                throw ([System.TimeoutException]::new('clone timed out for https://dev.azure.com/contoso/payments/_git/payments-api?sensitive-token=abc'))
            }

            $result = & $script:Wrapper -AdoOrg 'contoso' -OutputPath $outputFile
            $saved = Get-Content -Path $outputFile -Raw
            Remove-Item -Path $outputFile -Force -ErrorAction SilentlyContinue
        }

        AfterAll {
            Remove-Item Env:\ADO_PAT_TOKEN -ErrorAction SilentlyContinue
        }

        It 'writes sanitized output' {
            $result.Status | Should -Be 'Success'
            $saved | Should -Not -Match 'sensitive-token'
        }
    }

    Context 'when AdoServerUrl targets Azure DevOps Server' {
        BeforeAll {
            $env:ADO_PAT_TOKEN = 'fake-token'
            Mock Get-Command {
                param([string]$Name)
                if ($Name -eq 'gitleaks') { return [PSCustomObject]@{ Name = 'gitleaks' } }
                if ($Name -eq 'Invoke-WithTimeout') { return $null }
                return $null
            }
            function global:gitleaks { $global:LASTEXITCODE = 0 }
            Mock Invoke-RemoteRepoClone { throw 'clone should not be called for disallowed host' }
            Mock Invoke-WebRequest {
                param([string]$Uri)
                $body = switch -Regex ($Uri) {
                    '_apis/projects' { '{"value":[{"name":"payments","id":"proj-1"}]}' }
                    '_apis/git/repositories' { '{"value":[{"name":"payments-api","id":"repo-1","remoteUrl":"https://ado.contoso.local/tfs/DefaultCollection/payments/_git/payments-api"}]}' }
                    default { throw "Unexpected URI: $Uri" }
                }
                [PSCustomObject]@{ Content = $body; Headers = @{} }
            }
            $script:OnPremServerResult = & $script:Wrapper -AdoOrg 'contoso' -AdoServerUrl 'https://ado.contoso.local/tfs/DefaultCollection'
        }

        AfterAll {
            Remove-Item Function:\gitleaks -ErrorAction SilentlyContinue
            Remove-Item Env:\ADO_PAT_TOKEN -ErrorAction SilentlyContinue
        }

        It 'uses api-version 6.0 and returns allow-list skip finding' {
            Assert-MockCalled Invoke-WebRequest -Scope Context -Times 1 -ParameterFilter { $Uri -match '_apis/projects\?api-version=6\.0' }
            Assert-MockCalled Invoke-WebRequest -Scope Context -Times 1 -ParameterFilter { $Uri -match '_apis/git/repositories\?api-version=6\.0' }
            $script:OnPremServerResult.Status | Should -Be 'PartialSuccess'
            $skipFindings = @($script:OnPremServerResult.Findings | Where-Object { $_.PSObject.Properties.Name -contains 'SecretType' -and $_.SecretType -eq 'scan-skipped-host-not-allow-listed' })
            $skipFindings.Count | Should -Be 1
            $skipFindings[0].Severity | Should -Be 'Info'
        }
    }

    Context 'when AdoOrganizationUrl is custom HTTPS host' {
        BeforeAll {
            $env:ADO_PAT_TOKEN = 'fake-token'
            Mock Get-Command {
                param([string]$Name)
                if ($Name -eq 'gitleaks') { return [PSCustomObject]@{ Name = 'gitleaks' } }
                if ($Name -eq 'Invoke-WithTimeout') { return $null }
                return $null
            }
            function global:gitleaks { $global:LASTEXITCODE = 0 }
            Mock Invoke-RemoteRepoClone { throw 'clone should not be called for disallowed host' }
            Mock Invoke-WebRequest {
                param([string]$Uri)
                $body = switch -Regex ($Uri) {
                    '_apis/projects' { '{"value":[{"name":"payments","id":"proj-1"}]}' }
                    '_apis/git/repositories' { '{"value":[{"name":"payments-api","id":"repo-1"}]}' }
                    default { throw "Unexpected URI: $Uri" }
                }
                [PSCustomObject]@{ Content = $body; Headers = @{} }
            }
            $script:OnPremOrgResult = & $script:Wrapper -AdoOrg 'contoso' -AdoOrganizationUrl 'https://ado.contoso.local/tfs/DefaultCollection'
        }

        AfterAll {
            Remove-Item Function:\gitleaks -ErrorAction SilentlyContinue
            Remove-Item Env:\ADO_PAT_TOKEN -ErrorAction SilentlyContinue
        }

        It 'treats URL as on-prem and queries collection API with api-version 6.0' {
            Assert-MockCalled Invoke-WebRequest -Scope Context -Times 1 -ParameterFilter { $Uri -match '^https://ado\.contoso\.local/tfs/DefaultCollection/_apis/projects\?api-version=6\.0' }
            Assert-MockCalled Invoke-WebRequest -Scope Context -Times 1 -ParameterFilter { $Uri -match '^https://ado\.contoso\.local/tfs/DefaultCollection/payments/_apis/git/repositories\?api-version=6\.0' }
            $script:OnPremOrgResult.Status | Should -Be 'PartialSuccess'
            $skipFindings = @($script:OnPremOrgResult.Findings | Where-Object { $_.PSObject.Properties.Name -contains 'SecretType' -and $_.SecretType -eq 'scan-skipped-host-not-allow-listed' })
            $skipFindings[0].Severity | Should -Be 'Info'
        }
    }

    AfterAll {
        Remove-Variable -Name AdoMixedFixture -Scope Global -ErrorAction SilentlyContinue
    }
}
