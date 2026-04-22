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

    It 'returns process exit code 2 at runtime for unresolved required inputs in non-interactive mode' {
        $original = $env:AZURE_SUBSCRIPTION_ID
        try {
            Remove-Item Env:\AZURE_SUBSCRIPTION_ID -ErrorAction SilentlyContinue
            $stderr = & pwsh -NoLogo -NoProfile -File $script:orchestratorPath -IncludeTools azqr -NonInteractive 2>&1
            $LASTEXITCODE | Should -Be 2
            ($stderr | Out-String) | Should -Match 'Unresolved required inputs'
        } finally {
            if ($null -eq $original) {
                Remove-Item Env:\AZURE_SUBSCRIPTION_ID -ErrorAction SilentlyContinue
            } else {
                $env:AZURE_SUBSCRIPTION_ID = $original
            }
            $global:LASTEXITCODE = 0
        }
    }
}
