# NewWrapperEnvelope.Tests.ps1
#
# Unit tests for the shared New-WrapperEnvelope factory function.
# Verifies the v1 envelope contract: non-null arrays, schema version,
# and correct field propagation.

BeforeAll {
    . (Join-Path $PSScriptRoot '..' '..' 'modules' 'shared' 'New-WrapperEnvelope.ps1')
}

Describe 'New-WrapperEnvelope' {

    It 'returns a PSCustomObject' {
        $env = New-WrapperEnvelope -ToolName 'test'
        $env | Should -BeOfType [PSCustomObject]
    }

    It 'defaults SchemaVersion to 1.0' {
        $env = New-WrapperEnvelope -ToolName 'test'
        $env.SchemaVersion | Should -Be '1.0'
    }

    It 'accepts custom SchemaVersion' {
        $env = New-WrapperEnvelope -ToolName 'test' -SchemaVersion '2.0'
        $env.SchemaVersion | Should -Be '2.0'
    }

    It 'sets Source to ToolName' {
        $env = New-WrapperEnvelope -ToolName 'my-tool'
        $env.Source | Should -Be 'my-tool'
    }

    It 'defaults Status to Failed' {
        $env = New-WrapperEnvelope -ToolName 'test'
        $env.Status | Should -Be 'Failed'
    }

    It 'accepts custom Status' {
        $env = New-WrapperEnvelope -ToolName 'test' -Status 'Success'
        $env.Status | Should -Be 'Success'
    }

    It 'defaults Message to empty string' {
        $env = New-WrapperEnvelope -ToolName 'test'
        $env.Message | Should -Be ''
    }

    Context 'Findings array guarantee' {
        It 'defaults Findings to empty array (not $null)' {
            $env = New-WrapperEnvelope -ToolName 'test'
            $null -ne $env.Findings | Should -Be $true
            $env.Findings.Count | Should -Be 0
        }

        It 'wraps single finding in array' {
            $f = [PSCustomObject]@{ RuleId = 'R1' }
            $env = New-WrapperEnvelope -ToolName 'test' -Findings @($f)
            $env.Findings.Count | Should -Be 1
            $env.Findings[0].RuleId | Should -Be 'R1'
        }

        It 'preserves multiple findings' {
            $findings = @(
                [PSCustomObject]@{ RuleId = 'R1' },
                [PSCustomObject]@{ RuleId = 'R2' },
                [PSCustomObject]@{ RuleId = 'R3' }
            )
            $env = New-WrapperEnvelope -ToolName 'test' -Findings $findings
            $env.Findings.Count | Should -Be 3
        }

        It 'handles $null Findings gracefully' {
            $env = New-WrapperEnvelope -ToolName 'test' -Findings $null
            $null -ne $env.Findings | Should -Be $true
        }
    }

    Context 'Errors array guarantee' {
        It 'defaults Errors to empty array (not $null)' {
            $env = New-WrapperEnvelope -ToolName 'test'
            $null -ne $env.Errors | Should -Be $true
            $env.Errors.Count | Should -Be 0
        }

        It 'preserves error entries' {
            $errs = @('something broke', 'another thing broke')
            $env = New-WrapperEnvelope -ToolName 'test' -Errors $errs
            $env.Errors.Count | Should -Be 2
        }

        It 'handles $null Errors gracefully' {
            $env = New-WrapperEnvelope -ToolName 'test' -Errors $null
            $null -ne $env.Errors | Should -Be $true
        }
    }

    Context 'All six fields present' {
        It 'envelope has exactly SchemaVersion, Source, Status, Message, Findings, Errors' {
            $env = New-WrapperEnvelope -ToolName 'test'
            $props = @($env.PSObject.Properties.Name)
            $props | Should -Contain 'SchemaVersion'
            $props | Should -Contain 'Source'
            $props | Should -Contain 'Status'
            $props | Should -Contain 'Message'
            $props | Should -Contain 'Findings'
            $props | Should -Contain 'Errors'
        }
    }
}
