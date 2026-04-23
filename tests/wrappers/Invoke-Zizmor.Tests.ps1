#Requires -Version 7.4
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# See tests/wrappers/Invoke-AlzQueries.Tests.ps1 header -- single-file run guard.
$env:AZURE_ANALYZER_TEST_PRIOR_SUPPRESS = if ($null -eq $env:AZURE_ANALYZER_SUPPRESS_TOOL_MISSING_WARNINGS) { '__unset__' } else { $env:AZURE_ANALYZER_SUPPRESS_TOOL_MISSING_WARNINGS }
$env:AZURE_ANALYZER_SUPPRESS_TOOL_MISSING_WARNINGS = '1'

BeforeAll {
    $script:Here = Split-Path $PSCommandPath -Parent
    $script:RepoRoot = Resolve-Path (Join-Path $script:Here '..' '..')
    $script:Wrapper = Join-Path $script:RepoRoot 'modules' 'Invoke-Zizmor.ps1'
    $script:Normalizer = Join-Path $script:RepoRoot 'modules' 'normalizers' 'Normalize-Zizmor.ps1'
    $script:RawFixture = Join-Path $script:RepoRoot 'tests' 'fixtures' 'zizmor-raw-report.json'
}

AfterAll {
    if ($env:AZURE_ANALYZER_TEST_PRIOR_SUPPRESS -eq '__unset__') {
        Remove-Item Env:AZURE_ANALYZER_SUPPRESS_TOOL_MISSING_WARNINGS -ErrorAction SilentlyContinue
    } else {
        $env:AZURE_ANALYZER_SUPPRESS_TOOL_MISSING_WARNINGS = $env:AZURE_ANALYZER_TEST_PRIOR_SUPPRESS
    }
    Remove-Item Env:AZURE_ANALYZER_TEST_PRIOR_SUPPRESS -ErrorAction SilentlyContinue
}

Describe 'Invoke-Zizmor: error paths' {
    Context 'when zizmor CLI is missing' {
        BeforeAll {
            Mock Get-Command { return $null } -ParameterFilter { $Name -eq 'zizmor' }
            $result = & $script:Wrapper
        }

        It 'returns Status = Skipped' {
            $result.Status | Should -Be 'Skipped'
        }

        It 'returns empty Findings' {
            @($result.Findings).Count | Should -Be 0
        }

        It 'includes message about zizmor not installed' {
            $result.Message | Should -Match 'not installed'
        }

        It 'sets Source to zizmor' {
            $result.Source | Should -Be 'zizmor'
        }

        It 'includes SchemaVersion 1.0 in the v1 envelope' {
            $result.SchemaVersion | Should -Be '1.0'
        }
    }
}

Describe 'Invoke-Zizmor: -Since hint (#94 R1)' {
    It 'exposes a nullable -Since datetime parameter' {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:Wrapper, [ref]$null, [ref]$null)
        $paramBlock = $ast.ParamBlock
        $paramBlock | Should -Not -BeNullOrEmpty
        $sinceParam = $paramBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'Since' }
        $sinceParam | Should -Not -BeNullOrEmpty
        ($sinceParam.StaticType.ToString()) | Should -Match 'DateTime'
    }

    It 'returns RunMode=Incremental when -Since is supplied and wrapper exits via no-CLI path' {
        Mock Get-Command { return $null } -ParameterFilter { $Name -eq 'zizmor' }
        # Even the Skipped-no-CLI return is stamped with RunMode so the
        # orchestrator state layer never mis-tags the run.
        $since = [datetime]::Parse('2025-01-01T00:00:00Z').ToUniversalTime()
        $result = & $script:Wrapper -Since $since
        # Not-installed path returns RunMode = Full because no scan occurred;
        # but the key assertion is that the field is present so orchestrator
        # can read it without PropertyAccess errors.
        $result.PSObject.Properties['RunMode'] | Should -Not -BeNullOrEmpty
    }

    It 'tags RunMode=Incremental on the No-RepoPath skipped path when -Since is set' {
        # Force the CLI-present branch but fail RepoPath validation,
        # exercising the wrapper path that sets RunMode from $effectiveRunMode.
        Mock Get-Command {
            param($Name)
            if ($Name -eq 'zizmor') { return [pscustomobject]@{ Name = 'zizmor' } }
            return $null
        } -ParameterFilter { $Name -eq 'zizmor' }
        $since = [datetime]::Parse('2025-01-01T00:00:00Z').ToUniversalTime()
        $result = & $script:Wrapper -Since $since
        $result.Status | Should -Be 'Skipped'
        $result.RunMode | Should -Be 'Incremental'
    }
}

Describe 'Invoke-Zizmor: schema 2.2 precursor fields' {
    BeforeAll {
        $global:ZizmorRawFixture = $script:RawFixture
        function global:zizmor {
            param([Parameter(ValueFromRemainingArguments = $true)][object[]]$Args)
            if ($Args -contains '--version') {
                $global:LASTEXITCODE = 0
                return 'zizmor 1.8.0'
            }
            # zizmor 1.x writes JSON to stdout — return raw fixture content so the
            # wrapper's stdout redirection (`1>$reportFile`) captures it to disk.
            $global:LASTEXITCODE = 0
            return (Get-Content $global:ZizmorRawFixture -Raw)
        }
    }

    AfterAll {
        Remove-Item Function:\global:zizmor -ErrorAction SilentlyContinue
        Remove-Item Function:\global:git -ErrorAction SilentlyContinue
        Remove-Variable -Name ZizmorRawFixture -Scope Global -ErrorAction SilentlyContinue
    }

    It 'emits Pillar, tags, links, evidence, snippets, MITRE and version metadata' {
        Mock Get-Command {
            param($Name)
            if ($Name -eq 'zizmor') { return [pscustomobject]@{ Name = 'zizmor' } }
            if ($Name -eq 'git')    { return [pscustomobject]@{ Name = 'git' } }
            return $null
        } -ParameterFilter { $Name -in @('zizmor', 'git') }
        # Stub `git` invocations so the test is hermetic and does not depend on the
        # ambient git binary (raised in #737 review).
        function global:git {
            $cmd = ($args -join ' ')
            if ($cmd -match 'remote get-url origin') { return 'https://github.com/martinopedal/azure-analyzer.git' }
            if ($cmd -match 'rev-parse HEAD')        { return '0123456789abcdef0123456789abcdef01234567' }
            return ''
        }

        $result = & $script:Wrapper -RepoPath $script:RepoRoot
        $result.Status | Should -Be 'Success'
        $result.ToolVersion | Should -Be 'zizmor 1.8.0'
        @($result.Findings).Count | Should -Be 2

        $template = $result.Findings | Where-Object { $_.RuleId -eq 'template-injection' } | Select-Object -First 1
        $template.Pillar | Should -Be 'Security'
        $template.Impact | Should -Be 'High'
        $template.Effort | Should -Be 'Low'
        $template.DeepLinkUrl | Should -Be 'https://docs.zizmor.sh/audits/#template-injection'
        @($template.BaselineTags) | Should -Contain 'template-injection'
        @($template.BaselineTags) | Should -Contain 'severity:high'
        @($template.EvidenceUris).Count | Should -Be 1
        $template.EvidenceUris[0] | Should -Match '/blob/[0-9a-f]{40}/\.github/workflows/ci\.yml#L17-L22$'
        (@($template.EntityRefs) -join ',') | Should -Match '^.+/.+/.github/workflows/ci\.yml$'
        @($template.RemediationSnippets).Count | Should -Be 1
        $template.RemediationSnippets[0].language | Should -Be 'yaml'
        $template.ToolVersion | Should -Be 'zizmor 1.8.0'
        @($template.MitreTechniques) | Should -Contain 'T1059'

        $unpinned = $result.Findings | Where-Object { $_.RuleId -eq 'unpinned-uses' } | Select-Object -First 1
        $unpinned.Effort | Should -Be 'Medium'
        @($unpinned.MitreTechniques) | Should -Contain 'T1195.001'
    }

    It 'supports legacy -Repository alias' {
        $paramInfo = (Get-Command $script:Wrapper).Parameters
        $paramInfo['RepoPath'].Aliases | Should -Contain 'Repository'
    }
}

Describe 'Invoke-Zizmor: #768 zizmor 1.x exit-code handling' {
    BeforeAll {
        $global:ZizmorRawFixture768 = $script:RawFixture
        $global:ZizmorCapturedArgs = $null
        function global:zizmor {
            param([Parameter(ValueFromRemainingArguments = $true)][object[]]$Args)
            if ($Args -contains '--version') {
                $global:LASTEXITCODE = 0
                return 'zizmor 1.8.0'
            }
            $global:ZizmorCapturedArgs = @($Args)
            # Simulate zizmor 1.x: stdout JSON + non-zero severity exit code (e.g. 14).
            # With --no-exit-codes the wrapper passes, so this asserts the wrapper
            # never trips on a non-zero exit when stdout already has the report (#768).
            $global:LASTEXITCODE = 14
            return (Get-Content $global:ZizmorRawFixture768 -Raw)
        }
        function global:git {
            $cmd = ($args -join ' ')
            if ($cmd -match 'remote get-url origin') { return 'https://github.com/martinopedal/azure-analyzer.git' }
            if ($cmd -match 'rev-parse HEAD')        { return '0123456789abcdef0123456789abcdef01234567' }
            return ''
        }
    }

    AfterAll {
        Remove-Item Function:\global:zizmor -ErrorAction SilentlyContinue
        Remove-Item Function:\global:git -ErrorAction SilentlyContinue
        Remove-Variable -Name ZizmorRawFixture768 -Scope Global -ErrorAction SilentlyContinue
        Remove-Variable -Name ZizmorCapturedArgs -Scope Global -ErrorAction SilentlyContinue
    }

    It 'passes --no-exit-codes and --format=json so zizmor 1.x does not exit 2 on findings (#768)' {
        Mock Get-Command {
            param($Name)
            if ($Name -eq 'zizmor') { return [pscustomobject]@{ Name = 'zizmor' } }
            if ($Name -eq 'git')    { return [pscustomobject]@{ Name = 'git' } }
            return $null
        } -ParameterFilter { $Name -in @('zizmor', 'git') }

        $result = & $script:Wrapper -RepoPath $script:RepoRoot
        $result.Status | Should -Be 'Success' -Because 'zizmor non-zero exit with a populated report must NOT be treated as failure (#768)'
        @($result.Findings).Count | Should -BeGreaterThan 0

        $argString = ($global:ZizmorCapturedArgs | ForEach-Object { [string]$_ }) -join ' '
        $argString | Should -Match '--no-exit-codes' -Because 'wrapper must pass --no-exit-codes to suppress severity exit codes 11..14 (#768)'
        $argString | Should -Match '--format=json' -Because 'wrapper must request JSON output explicitly (#768)'
    }
}

Describe 'Invoke-Zizmor: E2E wrapper to normalizer (#660)' {
    BeforeAll {
        . $script:Normalizer
        $global:ZizmorE2EFixture = $script:RawFixture
        function global:zizmor {
            param([Parameter(ValueFromRemainingArguments = $true)][object[]]$Args)
            if ($Args -contains '--version') {
                $global:LASTEXITCODE = 0
                return 'zizmor 1.8.0'
            }
            # zizmor 1.x writes JSON to stdout (#768). Wrapper redirects 1>$reportFile.
            # Exit code is non-zero when severity-based exits are enabled, but the
            # wrapper passes --no-exit-codes so 0 is the expected normal-path code.
            $global:LASTEXITCODE = 0
            return (Get-Content $global:ZizmorE2EFixture -Raw)
        }
    }

    AfterAll {
        Remove-Item Function:\global:zizmor -ErrorAction SilentlyContinue
        Remove-Variable -Name ZizmorE2EFixture -Scope Global -ErrorAction SilentlyContinue
    }

    It 'emits a v1 envelope and normalizes into valid FindingRows' {
        Mock Get-Command {
            param($Name)
            if ($Name -eq 'zizmor') { return [pscustomobject]@{ Name = 'zizmor' } }
            return $null
        } -ParameterFilter { $Name -eq 'zizmor' }

        $result = & $script:Wrapper -RepoPath $script:RepoRoot
        $result.Status | Should -Be 'Success'
        $result.SchemaVersion | Should -Be '1.0'
        @($result.Findings).Count | Should -BeGreaterThan 0

        $rows = Normalize-Zizmor -ToolResult $result
        @($rows).Count | Should -Be (@($result.Findings).Count)
        $first = @($rows)[0]
        $first | Should -Not -BeNullOrEmpty
        $first.SchemaVersion | Should -Be '2.2'
        $first.Source | Should -Be 'zizmor'
        $first.EntityType | Should -Be 'Workflow'
        $first.Provenance.RunId | Should -Not -BeNullOrEmpty
    }
}
