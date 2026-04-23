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
        $env = New-WrapperEnvelope -Source 'test'
        $env | Should -BeOfType [PSCustomObject]
    }

    It 'defaults SchemaVersion to 1.0' {
        $env = New-WrapperEnvelope -Source 'test'
        $env.SchemaVersion | Should -Be '1.0'
    }

    It 'sets Source field' {
        $env = New-WrapperEnvelope -Source 'my-tool'
        $env.Source | Should -Be 'my-tool'
    }

    It 'defaults Status to Failed' {
        $env = New-WrapperEnvelope -Source 'test'
        $env.Status | Should -Be 'Failed'
    }

    It 'accepts custom Status' {
        $env = New-WrapperEnvelope -Source 'test' -Status 'Success'
        $env.Status | Should -Be 'Success'
    }

    It 'defaults Message to empty string' {
        $env = New-WrapperEnvelope -Source 'test'
        $env.Message | Should -Be ''
    }

    Context 'Findings array guarantee' {
        It 'defaults Findings to empty array (not $null)' {
            $env = New-WrapperEnvelope -Source 'test'
            $null -ne $env.Findings | Should -Be $true
            @($env.Findings).Count | Should -Be 0
        }
    }

    Context 'Errors array guarantee' {
        It 'defaults Errors to empty array (not $null)' {
            $env = New-WrapperEnvelope -Source 'test'
            $null -ne $env.Errors | Should -Be $true
            @($env.Errors).Count | Should -Be 0
        }

        It 'preserves FindingErrors entries' {
            $err = [PSCustomObject]@{
                Source      = 'wrapper:x'
                Category    = 'MissingDependency'
                Reason      = 'not found'
                Remediation = 'install it'
            }
            $env = New-WrapperEnvelope -Source 'test' -FindingErrors @($err)
            $env.Errors.Count | Should -Be 1
            $env.Errors[0].Category | Should -Be 'MissingDependency'
        }
    }

    Context 'All required fields present' {
        It 'envelope has SchemaVersion, Source, Status, Message, Findings, Errors' {
            $env = New-WrapperEnvelope -Source 'test'
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
