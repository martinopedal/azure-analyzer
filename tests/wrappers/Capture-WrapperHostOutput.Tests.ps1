#Requires -Version 7.4
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

BeforeAll {
    $script:RepoRoot = Resolve-Path (Join-Path $PSScriptRoot '..' '..')
    . (Join-Path $script:RepoRoot 'tests' '_helpers' 'Capture-WrapperHostOutput.ps1')
}

Describe 'Invoke-WrapperWithHostCapture' {
    It 'captures warning stream records' {
        $capture = Invoke-WrapperWithHostCapture -ScriptBlock {
            Write-Warning 'wrapper warning'
            [pscustomobject]@{ Status = 'Success'; Findings = @(); Message = '' }
        }

        $capture.Error | Should -BeNullOrEmpty
        @($capture.Warnings).Count | Should -Be 1
        @($capture.Warnings)[0] | Should -Be 'wrapper warning'
        $capture.Result.Status | Should -Be 'Success'
    }

    It 'captures warning-like information markers' {
        $capture = Invoke-WrapperWithHostCapture -ScriptBlock {
            Write-Information 'WARNING: native tool emitted warning text' -InformationAction Continue
            Write-Information '##[warning] workflow warning marker' -InformationAction Continue
            Write-Information 'Notice: optional notice marker' -InformationAction Continue
            [pscustomobject]@{ Status = 'Success'; Findings = @(); Message = '' }
        }

        $capture.Error | Should -BeNullOrEmpty
        @($capture.Warnings).Count | Should -Be 3
        @($capture.Warnings) | Should -Contain 'WARNING: native tool emitted warning text'
        @($capture.Warnings) | Should -Contain '##[warning] workflow warning marker'
        @($capture.Warnings) | Should -Contain 'Notice: optional notice marker'
    }

    It 'does not treat regular information lines as warnings' {
        $capture = Invoke-WrapperWithHostCapture -ScriptBlock {
            Write-Information 'scan started' -InformationAction Continue
            [pscustomobject]@{ Status = 'Success'; Findings = @(); Message = '' }
        }

        $capture.Error | Should -BeNullOrEmpty
        @($capture.Warnings) | Should -BeNullOrEmpty
        $capture.Result.Status | Should -Be 'Success'
    }
}
