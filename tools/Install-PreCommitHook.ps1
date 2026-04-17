#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Installs the pre-commit hook for gitleaks and zizmor.

.DESCRIPTION
    Copies or symlinks hooks/pre-commit.ps1 into .git/hooks/pre-commit with the appropriate
    shebang wrapper. Makes it executable on Unix-like systems.
    
    Idempotent: re-running replaces any existing hook cleanly.

.EXAMPLE
    .\tools\Install-PreCommitHook.ps1
    
    Installs the pre-commit hook for the current repository.

.NOTES
    This script works cross-platform (Windows PowerShell 7+ and Unix pwsh).
#>

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

# Resolve paths
$repoRoot = git rev-parse --show-toplevel
if ($LASTEXITCODE -ne 0) {
    throw "Not in a git repository. Run this script from within the azure-analyzer repository."
}

$hookSource = Join-Path $repoRoot 'hooks' 'pre-commit.ps1'
$hookTarget = Join-Path $repoRoot '.git' 'hooks' 'pre-commit'
$gitHooksDir = Join-Path $repoRoot '.git' 'hooks'

# Validate source exists
if (-not (Test-Path $hookSource)) {
    throw "Hook source not found: $hookSource"
}

# Ensure .git/hooks directory exists
if (-not (Test-Path $gitHooksDir)) {
    throw ".git/hooks directory not found. Is this a valid git repository?"
}

Write-Host "📦 Installing pre-commit hook..." -ForegroundColor Cyan

# Check if hook already exists
if (Test-Path $hookTarget) {
    Write-Host "   Existing hook found. Replacing..." -ForegroundColor Yellow
    Remove-Item $hookTarget -Force
}

# On Windows, create a .cmd shim that calls pwsh
# On Unix, create a symlink with shebang
if ($IsWindows -or $PSVersionTable.Platform -eq 'Win32NT' -or (-not $PSVersionTable.Platform)) {
    # Windows: Create a .cmd shim
    $shimContent = @"
@echo off
pwsh.exe -NoProfile -ExecutionPolicy Bypass -File "$hookSource" %*
exit /b %ERRORLEVEL%
"@
    Set-Content -Path $hookTarget -Value $shimContent -Encoding ASCII
    Write-Host "   ✅ Hook installed (Windows .cmd shim)." -ForegroundColor Green
} else {
    # Unix: Create a symlink and make it executable
    # Use relative path for portability
    $relativePath = [System.IO.Path]::GetRelativePath($gitHooksDir, $hookSource)
    
    # Create symlink
    New-Item -ItemType SymbolicLink -Path $hookTarget -Target $relativePath -Force | Out-Null
    
    # Make executable
    chmod +x $hookTarget
    
    Write-Host "   ✅ Hook installed (Unix symlink)." -ForegroundColor Green
}

Write-Host ""
Write-Host "✅ Pre-commit hook installed successfully!" -ForegroundColor Green
Write-Host ""
Write-Host "The hook will run gitleaks and zizmor on every commit." -ForegroundColor Cyan
Write-Host "To skip the hook for a specific commit, use: git commit --no-verify" -ForegroundColor Gray
Write-Host ""
Write-Host "Install dependencies:" -ForegroundColor Cyan
Write-Host "  - gitleaks: https://github.com/gitleaks/gitleaks#installing" -ForegroundColor Gray
Write-Host "  - zizmor:   https://woodruffw.github.io/zizmor/installation/" -ForegroundColor Gray
