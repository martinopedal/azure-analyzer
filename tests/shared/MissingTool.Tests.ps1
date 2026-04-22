#Requires -Version 7.0
Set-StrictMode -Version Latest

BeforeAll {
    $repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..')
    . (Join-Path $repoRoot 'modules\shared\MissingTool.ps1')
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

Describe 'Wrapper integration (Invoke-Trivy)' {

    BeforeAll {
        $script:repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..')
        $script:trivyWrapper = Join-Path $repoRoot 'modules\Invoke-Trivy.ps1'
    }

    AfterEach {
        Remove-Item Env:AZURE_ANALYZER_ORCHESTRATED   -ErrorAction SilentlyContinue
        Remove-Item Env:AZURE_ANALYZER_EXPLICIT_TOOLS -ErrorAction SilentlyContinue
    }

    It 'is silent when orchestrator runs default scan and trivy is missing' -Skip:([bool](Get-Command trivy -ErrorAction SilentlyContinue)) {
        $env:AZURE_ANALYZER_ORCHESTRATED   = '1'
        $env:AZURE_ANALYZER_EXPLICIT_TOOLS = ''
        $warnings = $null
        $null = & $trivyWrapper -ScanPath $repoRoot -WarningVariable warnings -WarningAction SilentlyContinue
        ($warnings | Where-Object { $_.Message -match 'trivy is not installed' }).Count | Should -Be 0
    }

    It 'warns loudly when user explicitly requested trivy and it is missing' -Skip:([bool](Get-Command trivy -ErrorAction SilentlyContinue)) {
        $env:AZURE_ANALYZER_ORCHESTRATED   = '1'
        $env:AZURE_ANALYZER_EXPLICIT_TOOLS = 'trivy'
        $warnings = $null
        $null = & $trivyWrapper -ScanPath $repoRoot -WarningVariable warnings -WarningAction SilentlyContinue
        ($warnings | Where-Object { $_.Message -match 'trivy is not installed' }).Count | Should -BeGreaterOrEqual 1
    }
}
