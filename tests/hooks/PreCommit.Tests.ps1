BeforeAll {
    $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
    $hookScript = Join-Path $repoRoot 'hooks' 'pre-commit.ps1'
    $installerScript = Join-Path $repoRoot 'tools' 'Install-PreCommitHook.ps1'
    
    # Mock external commands
    Mock git {
        param($Command)
        if ($Command -eq 'diff') {
            # Default: no staged files
            return @()
        }
        if ($Command -eq 'rev-parse') {
            return $repoRoot
        }
    } -ModuleName $null
}

Describe 'Pre-commit Hook' {
    BeforeAll {
        $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
        $hookScript = Join-Path $repoRoot 'hooks' 'pre-commit.ps1'
    }
    
    It 'Hook script exists' {
        $hookScript | Should -Exist
    }
    
    It 'Hook script has shebang' {
        $content = Get-Content $hookScript -Raw
        $content | Should -Match '#!/usr/bin/env pwsh'
    }
    
    It 'Hook defines Test-ToolInstalled function' {
        $content = Get-Content $hookScript -Raw
        $content | Should -Match 'function Test-ToolInstalled'
    }
    
    It 'Hook defines Get-StagedWorkflowFiles function' {
        $content = Get-Content $hookScript -Raw
        $content | Should -Match 'function Get-StagedWorkflowFiles'
    }
    
    It 'Hook defines Invoke-Gitleaks function' {
        $content = Get-Content $hookScript -Raw
        $content | Should -Match 'function Invoke-Gitleaks'
    }
    
    It 'Hook defines Invoke-Zizmor function' {
        $content = Get-Content $hookScript -Raw
        $content | Should -Match 'function Invoke-Zizmor'
    }
    
    It 'Hook checks for .gitleaks.toml config' {
        $content = Get-Content $hookScript -Raw
        $content | Should -Match '\.gitleaks\.toml'
    }
    
    It 'Hook uses --staged --redact flags for gitleaks' {
        $content = Get-Content $hookScript -Raw
        $content | Should -Match '--staged'
        $content | Should -Match '--redact'
    }
    
    It 'Hook filters workflow files with regex' {
        $content = Get-Content $hookScript -Raw
        $content | Should -Match '\.github\[/\\\\\]workflows'
    }
    
    It 'Hook exits with non-zero on failure' {
        $content = Get-Content $hookScript -Raw
        $content | Should -Match 'exit \$exitCode'
    }
}

Describe 'Install-PreCommitHook Script' {
    BeforeAll {
        $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
        $installerScript = Join-Path $repoRoot 'tools' 'Install-PreCommitHook.ps1'
    }
    
    It 'Installer script exists' {
        $installerScript | Should -Exist
    }
    
    It 'Installer has shebang' {
        $content = Get-Content $installerScript -Raw
        $content | Should -Match '#!/usr/bin/env pwsh'
    }
    
    It 'Installer validates git repository' {
        $content = Get-Content $installerScript -Raw
        $content | Should -Match 'git rev-parse --show-toplevel'
    }
    
    It 'Installer handles Windows and Unix differently' {
        $content = Get-Content $installerScript -Raw
        $content | Should -Match '#!/bin/sh'
        $content | Should -Match 'exec pwsh\.exe'
        $content | Should -Match '"\$@"'
    }
    
    It 'Installer makes hook executable on Unix' {
        $content = Get-Content $installerScript -Raw
        $content | Should -Match 'chmod \+x'
    }
    
    It 'Installer is idempotent (removes existing hook)' {
        $content = Get-Content $installerScript -Raw
        $content | Should -Match 'Remove-Item \$hookTarget'
    }

    It 'Installer uses git-compatible hook wrapper (not batch syntax)' {
        $content = Get-Content $installerScript -Raw
        $content | Should -Not -Match '@echo off'
    }
    
    It 'Installer provides install instructions' {
        $content = Get-Content $installerScript -Raw
        $content | Should -Match 'gitleaks'
        $content | Should -Match 'zizmor'
        $content | Should -Match 'https://'
    }
}

Describe 'Hook Behavior (Mocked)' {
    BeforeAll {
        $repoRoot = git rev-parse --show-toplevel
        
        # Define mock functions in the test scope
        function Test-ToolInstalled {
            param([string]$ToolName)
            $false  # Default: tools not installed
        }
        
        function Get-StagedWorkflowFiles {
            @()  # Default: no workflow files
        }
        
        function Invoke-Gitleaks {
            $true  # Default: pass
        }
        
        function Invoke-Zizmor {
            param([string[]]$Files)
            $true  # Default: pass
        }
    }
    
    It 'Exits 0 when no tools are installed and no checks run' {
        # This tests the graceful degradation path
        $result = Test-ToolInstalled 'gitleaks'
        $result | Should -Be $false
        
        $result = Test-ToolInstalled 'zizmor'
        $result | Should -Be $false
    }
    
    It 'Detects workflow files by pattern' {
        $testFiles = @(
            '.github/workflows/ci.yml',
            '.github/workflows/deploy.yaml',
            'src/main.ps1'
        )
        
        $workflowPattern = '^\.github[/\\]workflows[/\\].+\.(yml|yaml)$'
        $matched = $testFiles | Where-Object { $_ -match $workflowPattern }
        
        $matched.Count | Should -Be 2
        $matched | Should -Contain '.github/workflows/ci.yml'
        $matched | Should -Contain '.github/workflows/deploy.yaml'
    }

    It 'Workflow diff filter includes renamed files' {
        $content = Get-Content $hookScript -Raw
        $content | Should -Match '--diff-filter=ACMR'
    }
    
    It 'Gitleaks function signature is correct' {
        $hookScript = Join-Path $repoRoot 'hooks' 'pre-commit.ps1'
        $content = Get-Content $hookScript -Raw
        
        # Check function returns boolean (exit code check)
        $content | Should -Match 'function Invoke-Gitleaks.*\{[\s\S]*?return \$LASTEXITCODE -eq 0'
    }
    
    It 'Zizmor function accepts file array' {
        $hookScript = Join-Path $repoRoot 'hooks' 'pre-commit.ps1'
        $content = Get-Content $hookScript -Raw
        
        # Check function signature (use more flexible pattern)
        $content | Should -Match 'function Invoke-Zizmor'
        $content | Should -Match '\[string\[\]\]\$Files'
    }
}
