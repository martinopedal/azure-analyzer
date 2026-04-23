#Requires -Version 7.0
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

BeforeAll {
    $repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..')
    . (Join-Path $repoRoot 'tests\_helpers\Suppress-WrapperWarnings.ps1')
}

Describe 'Suppress-WrapperWarnings: Class A tool inventory' {
    It 'exports Get-ClassAToolInventory returning a hashtable snapshot' {
        $inv = Get-ClassAToolInventory
        $inv | Should -BeOfType ([hashtable])
        $inv.ContainsKey('CliTools')    | Should -BeTrue
        $inv.ContainsKey('PsModules')   | Should -BeTrue
        $inv.ContainsKey('ScriptFiles') | Should -BeTrue
    }

    It 'includes every wrapper CLI that calls Write-MissingToolNotice' {
        $inv = Get-ClassAToolInventory
        # Sweep #5: keep in sync with modules/Invoke-*.ps1.
        foreach ($tool in @('trivy','terraform','gitleaks','zizmor','prowler','infracost','powerpipe','azqr','bicep','scorecard')) {
            $inv.CliTools | Should -Contain $tool -Because "$tool is gated in modules/Invoke-*.ps1"
        }
    }

    It 'includes every wrapper PS module that calls Write-MissingToolNotice' {
        $inv = Get-ClassAToolInventory
        foreach ($mod in @('PSRule.Rules.Azure','PSRule','Maester','WARA','Az.ResourceGraph','Microsoft.Graph.Users')) {
            $inv.PsModules | Should -Contain $mod -Because "$mod is gated in modules/Invoke-*.ps1"
        }
    }

    It 'returns fresh copies so callers cannot mutate the shared inventory' {
        $first  = Get-ClassAToolInventory
        $first.CliTools += 'mutated'
        $second = Get-ClassAToolInventory
        $second.CliTools | Should -Not -Contain 'mutated'
    }
}

Describe 'Suppress-WrapperWarnings: Enable-MissingToolWarningSuppression' {
    It 'sets AZURE_ANALYZER_SUPPRESS_TOOL_MISSING_WARNINGS=1 and returns a restorer' {
        $prior = $env:AZURE_ANALYZER_SUPPRESS_TOOL_MISSING_WARNINGS
        try {
            Remove-Item Env:AZURE_ANALYZER_SUPPRESS_TOOL_MISSING_WARNINGS -ErrorAction SilentlyContinue
            $restore = Enable-MissingToolWarningSuppression
            $env:AZURE_ANALYZER_SUPPRESS_TOOL_MISSING_WARNINGS | Should -Be '1'
            & $restore
            $env:AZURE_ANALYZER_SUPPRESS_TOOL_MISSING_WARNINGS | Should -BeNullOrEmpty
        } finally {
            if ($null -ne $prior) {
                $env:AZURE_ANALYZER_SUPPRESS_TOOL_MISSING_WARNINGS = $prior
            }
        }
    }

    It 'preserves a previously set value on restore' {
        $prior = $env:AZURE_ANALYZER_SUPPRESS_TOOL_MISSING_WARNINGS
        try {
            $env:AZURE_ANALYZER_SUPPRESS_TOOL_MISSING_WARNINGS = 'true'
            $restore = Enable-MissingToolWarningSuppression
            $env:AZURE_ANALYZER_SUPPRESS_TOOL_MISSING_WARNINGS | Should -Be '1'
            & $restore
            $env:AZURE_ANALYZER_SUPPRESS_TOOL_MISSING_WARNINGS | Should -Be 'true'
        } finally {
            if ($null -ne $prior) {
                $env:AZURE_ANALYZER_SUPPRESS_TOOL_MISSING_WARNINGS = $prior
            } else {
                Remove-Item Env:AZURE_ANALYZER_SUPPRESS_TOOL_MISSING_WARNINGS -ErrorAction SilentlyContinue
            }
        }
    }
}
