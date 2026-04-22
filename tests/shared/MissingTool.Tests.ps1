#Requires -Version 7.0
Set-StrictMode -Version Latest

BeforeAll {
    $repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..')
    . (Join-Path $repoRoot 'modules\shared\MissingTool.ps1')
    # Snapshot the suppress-flag set by tests/_helpers/setup.ps1 so Describe
    # blocks below can safely clear it to assert baseline warn/silent behaviour
    # without leaking a cleared state to the rest of the Pester run.
    $script:OriginalSuppressFlag = $env:AZURE_ANALYZER_SUPPRESS_TOOL_MISSING_WARNINGS
}

AfterAll {
    if ($null -ne $script:OriginalSuppressFlag) {
        $env:AZURE_ANALYZER_SUPPRESS_TOOL_MISSING_WARNINGS = $script:OriginalSuppressFlag
    }
}

Describe 'Write-MissingToolNotice' {

    BeforeEach {
        # Suite-level setup.ps1 sets the suppress flag globally; the helper-behaviour
        # tests below must observe a clean baseline so they can assert warn-vs-silent.
        Remove-Item Env:AZURE_ANALYZER_SUPPRESS_TOOL_MISSING_WARNINGS -ErrorAction SilentlyContinue
    }

    AfterEach {
        Remove-Item Env:AZURE_ANALYZER_ORCHESTRATED   -ErrorAction SilentlyContinue
        Remove-Item Env:AZURE_ANALYZER_EXPLICIT_TOOLS -ErrorAction SilentlyContinue
    }

    Context 'Standalone wrapper invocation (no orchestrator env)' {
        It 'emits Write-Warning when no orchestrator flag is set' {
            $warnings = $null
            Write-MissingToolNotice -Tool 'trivy' -Message 'trivy missing.' -WarningVariable warnings -WarningAction SilentlyContinue
            $warnings.Count | Should -Be 1
            $warnings[0].Message | Should -Match 'trivy missing\.'
        }
    }

    Context 'Orchestrated run with no -IncludeTools' {
        BeforeEach {
            $env:AZURE_ANALYZER_ORCHESTRATED   = '1'
            $env:AZURE_ANALYZER_EXPLICIT_TOOLS = ''
        }
        It 'silences Write-Warning when tool was not explicitly requested' {
            $warnings = $null
            Write-MissingToolNotice -Tool 'trivy' -Message 'trivy missing.' -WarningVariable warnings -WarningAction SilentlyContinue
            $warnings.Count | Should -Be 0
        }
    }

    Context 'Orchestrated run WITH -IncludeTools naming the tool' {
        BeforeEach {
            $env:AZURE_ANALYZER_ORCHESTRATED   = '1'
            $env:AZURE_ANALYZER_EXPLICIT_TOOLS = 'trivy,gitleaks'
        }
        It 'still warns when tool is in the explicit list' {
            $warnings = $null
            Write-MissingToolNotice -Tool 'trivy' -Message 'trivy missing.' -WarningVariable warnings -WarningAction SilentlyContinue
            $warnings.Count | Should -Be 1
        }
        It 'silences when a different tool was requested' {
            $warnings = $null
            Write-MissingToolNotice -Tool 'zizmor' -Message 'zizmor missing.' -WarningVariable warnings -WarningAction SilentlyContinue
            $warnings.Count | Should -Be 0
        }
    }

    Context 'Explicit override' {
        BeforeEach {
            $env:AZURE_ANALYZER_ORCHESTRATED   = '1'
            $env:AZURE_ANALYZER_EXPLICIT_TOOLS = ''
        }
        It '-ExplicitlyRequested:$true forces a warning even in orchestrated default scan' {
            $warnings = $null
            Write-MissingToolNotice -Tool 'trivy' -Message 'trivy missing.' -ExplicitlyRequested:$true -WarningVariable warnings -WarningAction SilentlyContinue
            $warnings.Count | Should -Be 1
        }
        It '-ExplicitlyRequested:$false silences even when env says explicit' {
            $env:AZURE_ANALYZER_EXPLICIT_TOOLS = 'trivy'
            $warnings = $null
            Write-MissingToolNotice -Tool 'trivy' -Message 'trivy missing.' -ExplicitlyRequested:$false -WarningVariable warnings -WarningAction SilentlyContinue
            $warnings.Count | Should -Be 0
        }
    }
}

Describe 'Test-ToolExplicitlyRequested' {

    BeforeEach {
        Remove-Item Env:AZURE_ANALYZER_SUPPRESS_TOOL_MISSING_WARNINGS -ErrorAction SilentlyContinue
    }

    AfterEach {
        Remove-Item Env:AZURE_ANALYZER_ORCHESTRATED   -ErrorAction SilentlyContinue
        Remove-Item Env:AZURE_ANALYZER_EXPLICIT_TOOLS -ErrorAction SilentlyContinue
    }

    It 'returns $true when no orchestrator flag is set (standalone)' {
        Test-ToolExplicitlyRequested -Tool 'trivy' | Should -BeTrue
    }
    It 'returns $false when orchestrated with empty explicit list' {
        $env:AZURE_ANALYZER_ORCHESTRATED   = '1'
        $env:AZURE_ANALYZER_EXPLICIT_TOOLS = ''
        Test-ToolExplicitlyRequested -Tool 'trivy' | Should -BeFalse
    }
    It 'returns $true when tool is in the explicit list' {
        $env:AZURE_ANALYZER_ORCHESTRATED   = '1'
        $env:AZURE_ANALYZER_EXPLICIT_TOOLS = 'trivy , gitleaks'
        Test-ToolExplicitlyRequested -Tool 'trivy' | Should -BeTrue
    }
    It 'returns $false when tool is not in the explicit list' {
        $env:AZURE_ANALYZER_ORCHESTRATED   = '1'
        $env:AZURE_ANALYZER_EXPLICIT_TOOLS = 'gitleaks'
        Test-ToolExplicitlyRequested -Tool 'trivy' | Should -BeFalse
    }
}

Describe 'AZURE_ANALYZER_SUPPRESS_TOOL_MISSING_WARNINGS env var' {

    AfterEach {
        Remove-Item Env:AZURE_ANALYZER_SUPPRESS_TOOL_MISSING_WARNINGS -ErrorAction SilentlyContinue
        Remove-Item Env:AZURE_ANALYZER_ORCHESTRATED                  -ErrorAction SilentlyContinue
        Remove-Item Env:AZURE_ANALYZER_EXPLICIT_TOOLS                -ErrorAction SilentlyContinue
    }

    It 'silences warning even on standalone wrapper invocation' {
        $env:AZURE_ANALYZER_SUPPRESS_TOOL_MISSING_WARNINGS = '1'
        $warnings = $null
        Write-MissingToolNotice -Tool 'trivy' -Message 'trivy missing.' -WarningVariable warnings -WarningAction SilentlyContinue
        $warnings.Count | Should -Be 0
    }

    It 'silences warning even when tool is explicitly requested via -IncludeTools' {
        $env:AZURE_ANALYZER_ORCHESTRATED                   = '1'
        $env:AZURE_ANALYZER_EXPLICIT_TOOLS                 = 'trivy'
        $env:AZURE_ANALYZER_SUPPRESS_TOOL_MISSING_WARNINGS = 'true'
        $warnings = $null
        Write-MissingToolNotice -Tool 'trivy' -Message 'trivy missing.' -WarningVariable warnings -WarningAction SilentlyContinue
        $warnings.Count | Should -Be 0
    }

    It 'silences even when -ExplicitlyRequested:$true is passed' {
        $env:AZURE_ANALYZER_SUPPRESS_TOOL_MISSING_WARNINGS = 'yes'
        $warnings = $null
        Write-MissingToolNotice -Tool 'trivy' -Message 'trivy missing.' -ExplicitlyRequested:$true -WarningVariable warnings -WarningAction SilentlyContinue
        $warnings.Count | Should -Be 0
    }

    It 'still warns when env var is empty / unset' {
        $env:AZURE_ANALYZER_SUPPRESS_TOOL_MISSING_WARNINGS = ''
        $warnings = $null
        Write-MissingToolNotice -Tool 'trivy' -Message 'trivy missing.' -WarningVariable warnings -WarningAction SilentlyContinue
        $warnings.Count | Should -Be 1
    }

    It 'still warns when env var holds a non-truthy value (e.g. "0")' {
        $env:AZURE_ANALYZER_SUPPRESS_TOOL_MISSING_WARNINGS = '0'
        $warnings = $null
        Write-MissingToolNotice -Tool 'trivy' -Message 'trivy missing.' -WarningVariable warnings -WarningAction SilentlyContinue
        $warnings.Count | Should -Be 1
    }
}

Describe 'Wrapper integration (Invoke-Trivy) — sourcing contract' {

    BeforeAll {
        $script:repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..')
        $script:trivyWrapper = Join-Path $repoRoot 'modules\Invoke-Trivy.ps1'
    }

    It 'dot-sources MissingTool.ps1 so Write-MissingToolNotice is in scope' {
        # Helper-behaviour matrices are covered exhaustively by the unit tests above.
        # Here we just enforce the wrapper-side contract: the trivy wrapper sources the
        # helper module and routes its missing-tool message through Write-MissingToolNotice.
        $content = Get-Content $trivyWrapper -Raw
        $content | Should -Match 'MissingTool\.ps1'
        $content | Should -Match 'Write-MissingToolNotice'
    }
}
