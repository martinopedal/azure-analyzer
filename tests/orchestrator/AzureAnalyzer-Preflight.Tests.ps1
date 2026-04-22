#Requires -Version 7.4
Set-StrictMode -Version Latest

BeforeAll {
    $script:repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..')
    $script:orchestratorPath = Join-Path $script:repoRoot 'Invoke-AzureAnalyzer.ps1'
    $script:orchestratorCmd = Get-Command -Name $script:orchestratorPath
}

Describe 'Invoke-AzureAnalyzer preflight required inputs wiring' {
    It 'declares -NonInteractive switch' {
        $script:orchestratorCmd.Parameters.Keys | Should -Contain 'NonInteractive'
    }

    It 'loads preflight required-input module and resolves inputs before dispatch' {
        $src = Get-Content -LiteralPath $script:orchestratorPath -Raw
        $src | Should -Match '\$preflightPath = Join-Path'
        $src | Should -Match 'Get-RequiredInputs\.ps1'
        $src | Should -Match 'Get-RequiredInputs -Tools \$selectedTools'
    }

    It 'fails with exit code 2 path when required inputs are unresolved' {
        $src = Get-Content -LiteralPath $script:orchestratorPath -Raw
        $src | Should -Match 'exit 2'
    }
}
