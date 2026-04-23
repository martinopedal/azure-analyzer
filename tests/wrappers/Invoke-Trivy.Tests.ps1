#Requires -Version 7.4
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# See tests/wrappers/Invoke-AlzQueries.Tests.ps1 header -- single-file run guard.
$env:AZURE_ANALYZER_SUPPRESS_TOOL_MISSING_WARNINGS = '1'

BeforeAll {
    $script:Here = Split-Path $PSCommandPath -Parent
    $script:RepoRoot = Resolve-Path (Join-Path $script:Here '..' '..')
    $script:Wrapper = Join-Path $script:RepoRoot 'modules' 'Invoke-Trivy.ps1'
    $script:Normalizer = Join-Path $script:RepoRoot 'modules' 'normalizers' 'Normalize-Trivy.ps1'
    $script:CliFixture = Join-Path $script:RepoRoot 'tests' 'fixtures' 'trivy-cli-report.json'
}

Describe 'Invoke-Trivy: error paths' {
    Context 'when trivy CLI is missing' {
        BeforeAll {
            Mock Get-Command { return $null } -ParameterFilter { $Name -eq 'trivy' }
            $result = & $script:Wrapper
        }

        It 'returns Status = Skipped' {
            $result.Status | Should -Be 'Skipped'
        }

        It 'returns empty Findings' {
            @($result.Findings).Count | Should -Be 0
        }

        It 'includes message about trivy not installed' {
            $result.Message | Should -Match 'not installed'
        }

        It 'sets Source to trivy' {
            $result.Source | Should -Be 'trivy'
        }

        It 'includes SchemaVersion 1.0 in the v1 envelope' {
            $result.SchemaVersion | Should -Be '1.0'
        }
    }
}

Describe 'Invoke-Trivy: Schema 2.2 enrichment' {
    BeforeAll {
        $fixturePath = Join-Path $script:RepoRoot 'tests' 'fixtures' 'trivy-cli-report.json'
        $fixtureJson = Get-Content -Path $fixturePath -Raw

        function global:trivy {
            param([Parameter(ValueFromRemainingArguments = $true)] [string[]] $Args)
            if ($Args.Count -gt 0 -and $Args[0] -eq '--version') {
                "Version: 0.56.2"
                return
            }

            $outputIndex = [array]::IndexOf($Args, '--output')
            if ($outputIndex -lt 0 -or $outputIndex + 1 -ge $Args.Count) {
                throw "Expected --output argument in trivy invocation. Args: $($Args -join ' ')"
            }
            $outputPath = $Args[$outputIndex + 1]
            Set-Content -Path $outputPath -Value $fixtureJson -Encoding UTF8
            $global:LASTEXITCODE = 0
        }
    }

    AfterAll {
        Remove-Item Function:\global:trivy -ErrorAction SilentlyContinue
    }

    It 'emits one finding per CVE and misconfiguration with 2.2 fields present' {
        $result = & $script:Wrapper -RepoPath '.'
        $result.Status | Should -Be 'Success'
        @($result.Findings).Count | Should -Be 2

        $vuln = @($result.Findings | Where-Object { $_.Title -match 'CVE-2023-12345' })[0]
        $vuln.Pillar | Should -Be 'Security'
        $vuln.Impact | Should -Be 'High'
        $vuln.Effort | Should -Be 'Low'
        $vuln.ScoreDelta | Should -Be 9.8
        $vuln.ToolVersion | Should -Match '0.56.2'
        @($vuln.Frameworks).Count | Should -BeGreaterThan 0
        @($vuln.EvidenceUris).Count | Should -BeGreaterThan 0
        @($vuln.RemediationSnippets).Count | Should -Be 1
        $vuln.RemediationSnippets[0].before | Should -Be 'openssl:1.1.1k'
        $vuln.RemediationSnippets[0].after | Should -Be 'openssl:1.1.1w'
        $vuln.BaselineTags | Should -Contain 'CIS-DI-5.1'
    }

    It 'supports legacy -ScanPath alias' {
        $result = & $script:Wrapper -ScanPath '.'
        $result.Status | Should -Be 'Success'
    }
}

Describe 'Invoke-Trivy: E2E wrapper to normalizer (#662)' {
    BeforeAll {
        . $script:Normalizer
        $global:TrivyE2EFixtureJson = Get-Content -Path $script:CliFixture -Raw
    }

    BeforeEach {
        $global:CapturedTrivyArgs = @()
        function global:trivy {
            param([Parameter(ValueFromRemainingArguments = $true)] [string[]] $Args)
            if ($Args.Count -gt 0 -and $Args[0] -eq '--version') {
                $global:LASTEXITCODE = 0
                return 'Version: 0.56.2'
            }

            $global:CapturedTrivyArgs = @($Args)
            $outputIndex = [array]::IndexOf($Args, '--output')
            if ($outputIndex -lt 0 -or $outputIndex + 1 -ge $Args.Count) {
                throw "Expected --output argument in trivy invocation. Args: $($Args -join ' ')"
            }
            Set-Content -Path $Args[$outputIndex + 1] -Value $global:TrivyE2EFixtureJson -Encoding UTF8
            $global:LASTEXITCODE = 0
        }
    }

    AfterEach {
        Remove-Item Function:\global:trivy -ErrorAction SilentlyContinue
        Remove-Variable -Name CapturedTrivyArgs -Scope Global -ErrorAction SilentlyContinue
    }

    AfterAll {
        Remove-Variable -Name TrivyE2EFixtureJson -Scope Global -ErrorAction SilentlyContinue
    }

    It 'emits a v1 envelope and normalizes into valid FindingRows' {
        Mock Get-Command { return [pscustomobject]@{ Name = 'trivy' } } -ParameterFilter { $Name -eq 'trivy' }

        $result = & $script:Wrapper -RepoPath '.'
        $result.Status | Should -Be 'Success'
        $result.SchemaVersion | Should -Be '1.0'
        $global:CapturedTrivyArgs | Should -Contain '--output'
        @($result.Findings).Count | Should -BeGreaterThan 0

        $rows = Normalize-Trivy -ToolResult $result
        @($rows).Count | Should -BeGreaterThan 0
        $first = @($rows)[0]
        $first | Should -Not -BeNullOrEmpty
        $first.SchemaVersion | Should -Be '2.2'
        $first.Source | Should -Be 'trivy'
        $first.EntityType | Should -Be 'Repository'
        $first.Provenance.RunId | Should -Not -BeNullOrEmpty
    }
}
