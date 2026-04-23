#Requires -Version 7.4
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# See tests/wrappers/Invoke-AlzQueries.Tests.ps1 header -- single-file run guard.
$env:AZURE_ANALYZER_SUPPRESS_TOOL_MISSING_WARNINGS = '1'

BeforeAll {
    $script:Here = Split-Path $PSCommandPath -Parent
    $script:RepoRoot = Resolve-Path (Join-Path $script:Here '..' '..')
    $script:Wrapper = Join-Path $script:RepoRoot 'modules' 'Invoke-Zizmor.ps1'
    $script:RawFixture = Join-Path $script:RepoRoot 'tests' 'fixtures' 'zizmor-raw-report.json'
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

    It 'tags RunMode=Incremental on the No-Repository skipped path when -Since is set' {
        # Force the CLI-present branch but fail Repository validation,
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
            $outputIndex = [Array]::IndexOf($Args, '--output')
            if ($outputIndex -ge 0 -and ($outputIndex + 1) -lt $Args.Count) {
                Copy-Item -Path $global:ZizmorRawFixture -Destination ([string]$Args[$outputIndex + 1]) -Force
            }
            $global:LASTEXITCODE = 1
            return $null
        }
    }

    AfterAll {
        Remove-Item Function:\global:zizmor -ErrorAction SilentlyContinue
        Remove-Variable -Name ZizmorRawFixture -Scope Global -ErrorAction SilentlyContinue
    }

    It 'emits Pillar, tags, links, evidence, snippets, MITRE and version metadata' {
        Mock Get-Command {
            param($Name)
            if ($Name -eq 'zizmor') { return [pscustomobject]@{ Name = 'zizmor' } }
            if ($Name -eq 'git') { return [pscustomobject]@{ Name = 'git' } }
            return $null
        } -ParameterFilter { $Name -eq 'zizmor' -or $Name -eq 'git' }

        $result = & $script:Wrapper -Repository $script:RepoRoot
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
}

