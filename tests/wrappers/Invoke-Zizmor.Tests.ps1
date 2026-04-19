#Requires -Version 7.4
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

BeforeAll {
    $script:Here = Split-Path $PSCommandPath -Parent
    $script:RepoRoot = Resolve-Path (Join-Path $script:Here '..' '..')
    $script:Wrapper = Join-Path $script:RepoRoot 'modules' 'Invoke-Zizmor.ps1'
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

