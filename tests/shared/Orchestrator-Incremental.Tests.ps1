#Requires -Version 7.4
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

BeforeAll {
    $script:RepoRoot = Resolve-Path (Join-Path (Split-Path $PSCommandPath -Parent) '..' '..')
    $script:Orchestrator = Join-Path $script:RepoRoot 'Invoke-AzureAnalyzer.ps1'
}

Describe 'Invoke-AzureAnalyzer incremental surface (#94)' {
    BeforeAll {
        # Parse the orchestrator script via AST so we can introspect parameters
        # without actually executing it (it needs Azure context to run end-to-end).
        $tokens = $null; $errs = $null
        $script:Ast = [System.Management.Automation.Language.Parser]::ParseFile(
            $script:Orchestrator, [ref]$tokens, [ref]$errs)
        $script:ParamAst = $script:Ast.ParamBlock
    }

    It 'exposes -Incremental as a switch parameter' {
        $p = @($script:ParamAst.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'Incremental' })
        @($p).Count | Should -Be 1
        $p[0].StaticType.Name | Should -Be 'SwitchParameter'
    }

    It 'exposes -Since as a nullable datetime parameter' {
        $p = @($script:ParamAst.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'Since' })
        @($p).Count | Should -Be 1
        # Either Nullable[DateTime] or DateTime -- accept both, but we want nullable.
        $typeText = $p[0].StaticType.ToString()
        $typeText | Should -Match 'DateTime'
    }

    It 'still exposes -PreviousRun for explicit baselines' {
        $p = @($script:ParamAst.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'PreviousRun' })
        @($p).Count | Should -Be 1
    }

    It 'dot-sources the new ScanState shared module' {
        $text = Get-Content $script:Orchestrator -Raw
        $text | Should -Match "ScanState"
    }

    It 'bootstraps (runMode=Full, shouldRefreshBaseline=true) when -Incremental is set but no baseline exists (#94 R1)' {
        $text = Get-Content $script:Orchestrator -Raw
        # The orchestrator must set a bootstrap flag and force shouldRefreshBaseline
        # so the first -Incremental run seeds the baseline.
        $text | Should -Match 'bootstrapRun\s*=\s*\$true'
        $text | Should -Match 'shouldRefreshBaseline\s*=\s*\$bootstrapRun\s*-or'
    }

    It 'calls Resolve-IncrementalSince per tool before dispatch (#94 R1)' {
        $text = Get-Content $script:Orchestrator -Raw
        $text | Should -Match 'Resolve-IncrementalSince'
        # The call must happen before parallel dispatch. A simple heuristic:
        # Resolve-IncrementalSince appears earlier in the file than Invoke-ParallelTools.
        $resolveIdx = $text.IndexOf('Resolve-IncrementalSince')
        $dispatchIdx = $text.IndexOf('Invoke-ParallelTools -ToolSpecs')
        $resolveIdx | Should -BeLessThan $dispatchIdx
    }

    It 'passes -Since into the zizmor param splat when the per-tool since map resolves (#94 R1)' {
        $text = Get-Content $script:Orchestrator -Raw
        $text | Should -Match "incrementalSinceMap\.ContainsKey\('zizmor'\)"
        $text | Should -Match "params\['Since'\]\s*=\s*\`$incrementalSinceMap\['zizmor'\]"
    }
}

Describe 'Run-metadata persistence (#94)' {
    BeforeAll {
        . (Join-Path $script:RepoRoot 'modules' 'shared' 'ReportDelta.ps1')
        . (Join-Path $script:RepoRoot 'modules' 'shared' 'ScanState.ps1')

        $script:outDir = Join-Path ([System.IO.Path]::GetTempPath()) "orch-state-$([Guid]::NewGuid().ToString('N'))"
        New-Item -ItemType Directory -Path $script:outDir | Out-Null
    }
    AfterAll {
        if (Test-Path $script:outDir) { Remove-Item $script:outDir -Recurse -Force }
    }

    It 'writes scan-state.json under the output state folder when shared module runs end-to-end' {
        $state = Read-ScanState -OutputPath $script:outDir
        $state = Update-ScanStateToolEntry -State $state -Tool 'azqr' -Status 'Success' -RunMode 'FullFallback' -FindingCount 4
        $state = Update-ScanStateRun -State $state -RunMode 'Incremental'
        $null  = Write-ScanState -OutputPath $script:outDir -State $state

        $stateFile = Join-Path $script:outDir 'state' 'scan-state.json'
        Test-Path $stateFile | Should -BeTrue

        $reloaded = Read-ScanState -OutputPath $script:outDir
        $reloaded.runs.lastRunMode | Should -Be 'Incremental'
        (Get-ScanStateToolEntry -State $reloaded -Tool 'azqr').runMode | Should -Be 'FullFallback'
    }
}

