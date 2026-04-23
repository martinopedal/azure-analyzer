#Requires -Version 7.4
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# See tests/wrappers/Invoke-AlzQueries.Tests.ps1 header -- single-file run guard.
$env:AZURE_ANALYZER_TEST_PRIOR_SUPPRESS = if ($null -eq $env:AZURE_ANALYZER_SUPPRESS_TOOL_MISSING_WARNINGS) { '__unset__' } else { $env:AZURE_ANALYZER_SUPPRESS_TOOL_MISSING_WARNINGS }
$env:AZURE_ANALYZER_SUPPRESS_TOOL_MISSING_WARNINGS = '1'

BeforeAll {
    $script:Here = Split-Path $PSCommandPath -Parent
    $script:RepoRoot = Resolve-Path (Join-Path $script:Here '..' '..')
    $script:Wrapper = Join-Path $script:RepoRoot 'modules' 'Invoke-Gitleaks.ps1'
    $script:Normalizer = Join-Path $script:RepoRoot 'modules' 'normalizers' 'Normalize-Gitleaks.ps1'
    $script:CliFixture = Join-Path $script:RepoRoot 'tests' 'fixtures' 'gitleaks-cli-report.json'
}

AfterAll {
    if ($env:AZURE_ANALYZER_TEST_PRIOR_SUPPRESS -eq '__unset__') {
        Remove-Item Env:AZURE_ANALYZER_SUPPRESS_TOOL_MISSING_WARNINGS -ErrorAction SilentlyContinue
    } else {
        $env:AZURE_ANALYZER_SUPPRESS_TOOL_MISSING_WARNINGS = $env:AZURE_ANALYZER_TEST_PRIOR_SUPPRESS
    }
    Remove-Item Env:AZURE_ANALYZER_TEST_PRIOR_SUPPRESS -ErrorAction SilentlyContinue
}
Describe 'Invoke-Gitleaks' {
    # Contract tests for the "missing tool" path. Previously gated by
    # -Skip:$script:GitleaksInstalled, which silently skipped 5 assertions on
    # any developer machine where gitleaks was on PATH. Mock Get-Command so
    # the wrapper always follows the Test-GitleaksInstalled -> $false branch,
    # making the contract environment-invariant (no silent skips when the
    # real binary happens to be installed locally).
    Context 'when gitleaks CLI is missing' {
        BeforeAll {
            Mock Get-Command { return $null } -ParameterFilter { $Name -eq 'gitleaks' }
            $result = & $script:Wrapper
        }

        It 'returns Status = Skipped' {
            $result.Status | Should -Be 'Skipped'
        }

        It 'returns empty Findings' {
            @($result.Findings).Count | Should -Be 0
        }

        It 'includes message about gitleaks not installed' {
            $result.Message | Should -Match 'not installed'
        }

        It 'sets Source to gitleaks' {
            $result.Source | Should -Be 'gitleaks'
        }

        It 'includes SchemaVersion 1.0 in the v1 envelope' {
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
            $null = git -C $script:RepoPath init 2>$null
            $null = git -C $script:RepoPath remote add origin https://github.com/test-org/test-repo.git 2>$null

            $global:CapturedArgs = @()
            $global:MockGitleaksReport = '[]'
            function global:gitleaks {
                param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Args)
                if (@($Args).Count -eq 1 -and $Args[0] -eq 'version') {
                    $global:LASTEXITCODE = 0
                    return 'gitleaks version 8.24.2'
                }
                $global:CapturedArgs = @($Args)
                $idx = [Array]::IndexOf($Args, '--report-path')
                if ($idx -ge 0) {
                    Set-Content -Path $Args[$idx + 1] -Value $global:MockGitleaksReport -Encoding UTF8
                }
                $global:LASTEXITCODE = 0
            }

        }

        AfterEach {
            Remove-Item Function:\gitleaks -ErrorAction SilentlyContinue
            Remove-Variable -Name CapturedArgs -Scope Global -ErrorAction SilentlyContinue
            Remove-Variable -Name MockGitleaksReport -Scope Global -ErrorAction SilentlyContinue
            if ($script:TestRoot -and (Test-Path $script:TestRoot)) {
                Remove-Item -Path $script:TestRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }

        It 'invokes gitleaks without --config when no config path is provided' {
            $result = & $script:Wrapper -RepoPath $script:RepoPath

            $result.Status | Should -Be 'Success'
            ,$result.Findings | Should -Not -Be $null
            @($result.Findings).Count | Should -Be 0
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
            } | Should -Throw '*wrapper:gitleaks*NotFound*Gitleaks config file not found*'
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

        It 'emits Schema 2.2 gitleaks metadata and tool version' {
            $global:MockGitleaksReport = @'
[
  {
    "RuleID": "aws-access-key-id",
    "Description": "AWS Access Key",
    "File": ".github/workflows/deploy.yml",
    "StartLine": 12,
    "Commit": "1234567890abcdef",
    "Fingerprint": "1234567890abcdef:.github/workflows/deploy.yml:aws-access-key-id:12",
    "Tags": ["secret","aws","key"]
  }
]
'@

            $result = & $script:Wrapper -RepoPath $script:RepoPath
            $first = @($result.Findings)[0]

            $result.ToolVersion | Should -Be '8.24.2'
            $result.RepositoryEntityId | Should -Be 'github.com/test-org/test-repo'
            $first.RuleId | Should -Be 'aws-access-key-id'
            $first.Pillar | Should -Be 'Security'
            $first.Severity | Should -Be 'Critical'
            $first.DeepLinkUrl | Should -Match 'gitleaks.toml'
            $first.BaselineTags | Should -Contain 'gitleaks:rule:aws-access-key-id'
            @($first.EvidenceUris).Count | Should -Be 2
            $first.EvidenceUris[1] | Should -Match '#L12'
            $first.EntityRefs | Should -Contain 'workflow:test-org/test-repo/.github/workflows/deploy.yml'
            $first.ToolVersion | Should -Be '8.24.2'
            @($first.RemediationSnippets).Count | Should -BeGreaterThan 1
        }
    }
}

Describe 'Invoke-Gitleaks: E2E wrapper to normalizer (#661)' {
    BeforeAll {
        . $script:Normalizer
        $global:GitleaksCliFixturePath = $script:CliFixture
    }

    BeforeEach {
        $global:CapturedGitleaksArgs = @()
        function global:gitleaks {
            param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Args)
            if (@($Args).Count -eq 1 -and $Args[0] -eq 'version') {
                $global:LASTEXITCODE = 0
                return 'gitleaks version 8.24.2'
            }

            $global:CapturedGitleaksArgs = @($Args)
            $reportPathIndex = [Array]::IndexOf($Args, '--report-path')
            if ($reportPathIndex -ge 0 -and ($reportPathIndex + 1) -lt $Args.Count) {
                Copy-Item -Path $global:GitleaksCliFixturePath -Destination $Args[$reportPathIndex + 1] -Force
            }
            $global:LASTEXITCODE = 0
        }
    }

    AfterEach {
        Remove-Item Function:\global:gitleaks -ErrorAction SilentlyContinue
        Remove-Variable -Name CapturedGitleaksArgs -Scope Global -ErrorAction SilentlyContinue
    }

    AfterAll {
        Remove-Variable -Name GitleaksCliFixturePath -Scope Global -ErrorAction SilentlyContinue
    }

    It 'emits a v1 envelope and normalizes into valid FindingRows' {
        Mock Get-Command {
            param($Name)
            if ($Name -eq 'gitleaks') { return [pscustomobject]@{ Name = 'gitleaks' } }
            if ($Name -eq 'git') { return [pscustomobject]@{ Name = 'git' } }
            return $null
        } -ParameterFilter { $Name -eq 'gitleaks' -or $Name -eq 'git' }

        $result = & $script:Wrapper -RepoPath $script:RepoRoot
        $result.Status | Should -Be 'Success'
        $result.SchemaVersion | Should -Be '1.0'
        $global:CapturedGitleaksArgs | Should -Contain '--report-path'
        @($result.Findings).Count | Should -BeGreaterThan 0

        $rows = Normalize-Gitleaks -ToolResult $result
        @($rows).Count | Should -Be (@($result.Findings).Count)
        $first = @($rows)[0]
        $first | Should -Not -BeNullOrEmpty
        $first.SchemaVersion | Should -Be '2.2'
        $first.Source | Should -Be 'gitleaks'
        $first.EntityType | Should -Be 'Repository'
        $first.Provenance.RunId | Should -Not -BeNullOrEmpty
    }
}
