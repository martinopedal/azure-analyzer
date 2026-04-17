#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Pre-commit hook for gitleaks secret detection and zizmor workflow security analysis.

.DESCRIPTION
    Runs gitleaks on all staged changes to catch secrets before commit.
    Runs zizmor on any modified .github/workflows/*.yml files to catch workflow injection risks.
    Exits non-zero if either tool finds issues.
    Gracefully skips with a warning if binaries are not installed.

.NOTES
    This script is designed to work cross-platform (Windows PowerShell 7+ and Unix pwsh).
#>

$ErrorActionPreference = 'Stop'

function Test-ToolInstalled {
    param([string]$ToolName)
    $null -ne (Get-Command $ToolName -ErrorAction SilentlyContinue)
}

function Get-StagedWorkflowFiles {
    # Get staged .yml/.yaml files under .github/workflows/
    $stagedFiles = git diff --cached --name-only --diff-filter=ACM
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "Failed to get staged files. Skipping workflow checks."
        return @()
    }
    
    $workflowFiles = $stagedFiles | Where-Object {
        $_ -match '^\.github[/\\]workflows[/\\].+\.(yml|yaml)$'
    }
    
    return @($workflowFiles)
}

function Invoke-Gitleaks {
    Write-Host "🔍 Running gitleaks on staged changes..." -ForegroundColor Cyan
    
    # Check if config exists, use it if present
    $configArg = if (Test-Path '.gitleaks.toml') { '--config=.gitleaks.toml' } else { '' }
    
    # Run gitleaks protect on staged changes
    if ($configArg) {
        git diff --staged | gitleaks protect --staged --redact --no-banner $configArg 2>&1 | Write-Host
    } else {
        git diff --staged | gitleaks protect --staged --redact --no-banner 2>&1 | Write-Host
    }
    
    return $LASTEXITCODE -eq 0
}

function Invoke-Zizmor {
    param([string[]]$Files)
    
    Write-Host "🔍 Running zizmor on workflow files..." -ForegroundColor Cyan
    Write-Host "   Checking: $($Files -join ', ')" -ForegroundColor Gray
    
    # Run zizmor on each workflow file
    zizmor $Files 2>&1 | Write-Host
    
    return $LASTEXITCODE -eq 0
}

# Main execution
$exitCode = 0
$checksRun = 0

# Check gitleaks
$gitleaksInstalled = Test-ToolInstalled 'gitleaks'
if (-not $gitleaksInstalled) {
    Write-Warning @"
⚠️  gitleaks is not installed. Skipping secret detection.
   Install: https://github.com/gitleaks/gitleaks#installing
   - Windows: winget install gitleaks
   - macOS: brew install gitleaks
   - Linux: see GitHub releases
"@
} else {
    $checksRun++
    if (-not (Invoke-Gitleaks)) {
        Write-Error "❌ gitleaks found secrets in staged changes. Fix them before committing."
        $exitCode = 1
    } else {
        Write-Host "✅ gitleaks: No secrets detected." -ForegroundColor Green
    }
}

# Check zizmor on workflow files
$workflowFiles = Get-StagedWorkflowFiles
if ($workflowFiles.Count -gt 0) {
    $zizmorInstalled = Test-ToolInstalled 'zizmor'
    if (-not $zizmorInstalled) {
        Write-Warning @"
⚠️  zizmor is not installed. Skipping workflow security checks.
   Install: https://woodruffw.github.io/zizmor/installation/
   - Windows/macOS/Linux: pipx install zizmor
   - Or: cargo install zizmor
"@
    } else {
        $checksRun++
        if (-not (Invoke-Zizmor -Files $workflowFiles)) {
            Write-Error "❌ zizmor found security issues in workflow files. Fix them before committing."
            $exitCode = 1
        } else {
            Write-Host "✅ zizmor: No workflow security issues detected." -ForegroundColor Green
        }
    }
} else {
    Write-Host "ℹ️  No workflow files staged. Skipping zizmor." -ForegroundColor Gray
}

# Summary
if ($exitCode -eq 0 -and $checksRun -gt 0) {
    Write-Host "`n✅ Pre-commit checks passed!" -ForegroundColor Green
} elseif ($checksRun -eq 0) {
    Write-Warning "`n⚠️  No pre-commit checks could run. Consider installing gitleaks and zizmor."
}

exit $exitCode
