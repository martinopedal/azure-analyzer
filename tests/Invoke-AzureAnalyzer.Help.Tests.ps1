#Requires -Version 7.4
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Describe 'Invoke-AzureAnalyzer -Help' {
    It 'exits 0 and prints help when -Help is passed' {
        $script = Join-Path $PSScriptRoot '..' 'Invoke-AzureAnalyzer.ps1'
        $output = & pwsh -NoProfile -NonInteractive -Command "& '$script' -Help" 2>&1
        $LASTEXITCODE | Should -Be 0
        ($output -join "`n") | Should -Match 'Invoke-AzureAnalyzer'
    }

    It 'documents -AlzReferenceMode in help output' {
        $script = Join-Path $PSScriptRoot '..' 'Invoke-AzureAnalyzer.ps1'
        $output = & pwsh -NoProfile -NonInteractive -Command "& '$script' -Help" 2>&1
        ($output -join "`n") | Should -Match 'AlzReferenceMode'
    }
}
