#Requires -Version 7.4
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

<#
.SYNOPSIS
    Fail-first regression guard for issue #1065 (LiveTool state leak).
.DESCRIPTION
    Confirms that the LiveTool.Wrappers.Tests.ps1 BeforeEach block successfully
    isolates against leaked $LASTEXITCODE, GITLEAKS_* env vars, and working
    directory drift from prior tests in the full Pester suite.

    This test deliberately pollutes the environment, then verifies the gitleaks
    smoke test still passes.
#>

BeforeAll {
    $script:Here = Split-Path $PSCommandPath -Parent
    $script:RepoRoot = Resolve-Path (Join-Path $script:Here '..' '..')
    $script:GitleaksWrapper = Join-Path $script:RepoRoot 'modules' 'Invoke-Gitleaks.ps1'
    . (Join-Path $script:RepoRoot 'tests' '_helpers' 'Capture-WrapperHostOutput.ps1')

    # Snapshot env vars this file deliberately mutates so AfterEach can restore
    # the prior value (or remove the var if it was unset). Required by the
    # test isolation guard in tests/shared/TestIsolation.Tests.ps1 (#746).
    $script:_OrigGitleaksReportPath = if (Test-Path Env:GITLEAKS_REPORT_PATH) { $env:GITLEAKS_REPORT_PATH } else { $null }
    $script:_OrigLastExitCode = $global:LASTEXITCODE
}

AfterEach {
    # Restore $env:GITLEAKS_REPORT_PATH to its pre-test state.
    if ($null -eq $script:_OrigGitleaksReportPath) {
        Remove-Item Env:GITLEAKS_REPORT_PATH -ErrorAction SilentlyContinue
    } else {
        $env:GITLEAKS_REPORT_PATH = $script:_OrigGitleaksReportPath
    }
    # Restore $LASTEXITCODE so subsequent test files don't inherit our pollution.
    $global:LASTEXITCODE = $script:_OrigLastExitCode
}

Describe 'LiveTool state isolation guard (#1065 regression)' -Tag 'LiveTool' {
    It 'gitleaks smoke test passes even when $LASTEXITCODE is leaked from prior test' -Skip:(-not (Get-Command gitleaks -ErrorAction SilentlyContinue)) {
        # Deliberately pollute: simulate FixtureMode.Tests.ps1:23 leaking non-zero exit
        $global:LASTEXITCODE = 1

        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("state-leak-guard-" + [guid]::NewGuid().ToString('N'))
        $repoPath = Join-Path $tempRoot 'repo'
        try {
            # Reset state as LiveTool.Wrappers.Tests.ps1 BeforeEach does
            $global:LASTEXITCODE = 0
            Get-ChildItem Env:GITLEAKS_* -ErrorAction SilentlyContinue | Remove-Item -ErrorAction SilentlyContinue

            $null = New-Item -ItemType Directory -Path $repoPath -Force
            Set-Content -Path (Join-Path $repoPath 'README.md') -Value 'state isolation guard test' -Encoding UTF8
            $null = git -C $repoPath init 2>$null
            $null = git -C $repoPath add README.md 2>$null
            $null = git -C $repoPath -c user.name='isolation-test' -c user.email='test@example.com' commit -m 'init' --no-gpg-sign 2>$null

            $capture = Invoke-WrapperWithHostCapture -ScriptBlock { & $script:GitleaksWrapper -RepoPath $repoPath }
            $result = $capture.Result
            $result | Should -Not -BeNullOrEmpty
            $result.Source | Should -Be 'gitleaks'
            $result.Status | Should -Be 'Success' -Because 'BeforeEach reset of $LASTEXITCODE must prevent false-negative Status=Failed'
            @($result.Findings).Count | Should -BeGreaterOrEqual 0
        } finally {
            if (Test-Path $tempRoot) {
                Remove-Item -Path $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It 'gitleaks smoke test passes even when GITLEAKS_* env var is leaked' -Skip:(-not (Get-Command gitleaks -ErrorAction SilentlyContinue)) {
        # Deliberately pollute: set a fake GITLEAKS_* env var
        $env:GITLEAKS_REPORT_PATH = 'C:\fakepath\leaked.json'

        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("env-leak-guard-" + [guid]::NewGuid().ToString('N'))
        $repoPath = Join-Path $tempRoot 'repo'
        try {
            # Reset state as LiveTool.Wrappers.Tests.ps1 BeforeEach does
            $global:LASTEXITCODE = 0
            Get-ChildItem Env:GITLEAKS_* -ErrorAction SilentlyContinue | Remove-Item -ErrorAction SilentlyContinue

            $null = New-Item -ItemType Directory -Path $repoPath -Force
            Set-Content -Path (Join-Path $repoPath 'README.md') -Value 'env isolation guard test' -Encoding UTF8
            $null = git -C $repoPath init 2>$null
            $null = git -C $repoPath add README.md 2>$null
            $null = git -C $repoPath -c user.name='isolation-test' -c user.email='test@example.com' commit -m 'init' --no-gpg-sign 2>$null

            $capture = Invoke-WrapperWithHostCapture -ScriptBlock { & $script:GitleaksWrapper -RepoPath $repoPath }
            $result = $capture.Result
            $result | Should -Not -BeNullOrEmpty
            $result.Source | Should -Be 'gitleaks'
            $result.Status | Should -Be 'Success' -Because 'BeforeEach removal of GITLEAKS_* env vars must prevent interference'
            @($result.Findings).Count | Should -BeGreaterOrEqual 0
        } finally {
            if (Test-Path $tempRoot) {
                Remove-Item -Path $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
            Remove-Item Env:GITLEAKS_REPORT_PATH -ErrorAction SilentlyContinue
        }
    }
}
