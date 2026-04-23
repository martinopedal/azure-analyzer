#Requires -Version 7.0

Set-StrictMode -Version Latest

BeforeAll {
    $repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..')
    . (Join-Path $repoRoot 'modules\shared\MissingTool.ps1')
    # The bootstrap helper (tests/_helpers/setup.ps1) sets
    # AZURE_ANALYZER_SUPPRESS_TOOL_MISSING_WARNINGS=1 to silence wrapper noise.
    # These tests verify the orchestrator-aware warning logic, so the kill-switch
    # must be cleared for the lifetime of this file. Captured + restored to
    # avoid leaking into subsequent test files.
    $script:OriginalSuppressFlag = $env:AZURE_ANALYZER_SUPPRESS_TOOL_MISSING_WARNINGS
    Remove-Item Env:AZURE_ANALYZER_SUPPRESS_TOOL_MISSING_WARNINGS -ErrorAction SilentlyContinue
}

AfterAll {
    if ($null -ne $script:OriginalSuppressFlag) {
        $env:AZURE_ANALYZER_SUPPRESS_TOOL_MISSING_WARNINGS = $script:OriginalSuppressFlag
    }
}

Describe 'Write-MissingToolNotice' {

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

Describe 'Wrapper integration (Invoke-Trivy) sourcing contract' {

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
