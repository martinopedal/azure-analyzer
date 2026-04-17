#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Installs the pre-commit hook for gitleaks and zizmor.

.DESCRIPTION
    Writes a POSIX-compatible .git/hooks/pre-commit wrapper that execs pwsh/pwsh.exe and
    forwards all arguments to hooks/pre-commit.ps1. This works with git's bash-based hook runner
    on Windows and Unix-like systems.
    
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
$gitHooksDir = git rev-parse --git-path hooks
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($gitHooksDir)) {
    throw "Failed to resolve git hooks directory with 'git rev-parse --git-path hooks'."
}
$hookTarget = Join-Path $gitHooksDir 'pre-commit'

# Validate source exists
if (-not (Test-Path $hookSource)) {
    throw "Hook source not found: $hookSource"
}

# Ensure hooks directory exists
if (-not (Test-Path $gitHooksDir)) {
    New-Item -ItemType Directory -Path $gitHooksDir -Force | Out-Null
}

Write-Host "📦 Installing pre-commit hook..." -ForegroundColor Cyan

# Check if hook already exists
if (Test-Path $hookTarget) {
    Write-Host "   Existing hook found. Replacing..." -ForegroundColor Yellow
    Remove-Item $hookTarget -Force
}

$wrapperContent = @'
#!/bin/sh
repo_root="$(git rev-parse --show-toplevel 2>/dev/null)"
if [ -z "$repo_root" ]; then
  echo "pre-commit: failed to resolve repo root" >&2
  exit 1
fi
hook_script="$repo_root/hooks/pre-commit.ps1"
if [ ! -f "$hook_script" ]; then
  echo "pre-commit: hook script not found: $hook_script" >&2
  exit 1
fi
if command -v pwsh.exe >/dev/null 2>&1; then
  exec pwsh.exe -NoProfile -ExecutionPolicy Bypass -File "$hook_script" "$@"
fi
exec pwsh -NoProfile -File "$hook_script" "$@"
'@

Set-Content -Path $hookTarget -Value $wrapperContent -Encoding ASCII
try {
    chmod +x $hookTarget
} catch {
    # Git for Windows can still execute hooks without chmod; ignore when chmod is unavailable.
}
Write-Host "   ✅ Hook installed (POSIX shebang wrapper)." -ForegroundColor Green

Write-Host ""
Write-Host "✅ Pre-commit hook installed successfully!" -ForegroundColor Green
Write-Host ""
Write-Host "The hook will run gitleaks and zizmor on every commit." -ForegroundColor Cyan
Write-Host "To skip the hook for a specific commit, use: git commit --no-verify" -ForegroundColor Gray
Write-Host ""
Write-Host "Install dependencies:" -ForegroundColor Cyan
Write-Host "  - gitleaks: https://github.com/gitleaks/gitleaks#installing" -ForegroundColor Gray
Write-Host "  - zizmor:   https://woodruffw.github.io/zizmor/installation/" -ForegroundColor Gray
