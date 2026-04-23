#Requires -Version 7.4
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Keep transcript noise down for missing-tool notices when running locally.
$env:AZURE_ANALYZER_SUPPRESS_TOOL_MISSING_WARNINGS = '1'

BeforeAll {
    $script:Here = Split-Path $PSCommandPath -Parent
    $script:RepoRoot = Resolve-Path (Join-Path $script:Here '..' '..')
    $script:GitleaksWrapper = Join-Path $script:RepoRoot 'modules' 'Invoke-Gitleaks.ps1'
    $script:TrivyWrapper = Join-Path $script:RepoRoot 'modules' 'Invoke-Trivy.ps1'
    $script:ZizmorWrapper = Join-Path $script:RepoRoot 'modules' 'Invoke-Zizmor.ps1'
    $script:ScorecardWrapper = Join-Path $script:RepoRoot 'modules' 'Invoke-Scorecard.ps1'
}

Describe 'Wrapper live-tool smoke suite' -Tag 'LiveTool' {
    It 'runs Invoke-Gitleaks with the real CLI binary' -Skip:(-not (Get-Command gitleaks -ErrorAction SilentlyContinue)) {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("live-gitleaks-" + [guid]::NewGuid().ToString('N'))
        $repoPath = Join-Path $tempRoot 'repo'
        try {
            $null = New-Item -ItemType Directory -Path $repoPath -Force
            Set-Content -Path (Join-Path $repoPath 'README.md') -Value 'live gitleaks test' -Encoding UTF8
            $null = git -C $repoPath init 2>$null
            $null = git -C $repoPath add README.md 2>$null
            $null = git -C $repoPath -c user.name='live-test' -c user.email='live@example.com' commit -m 'init' --no-gpg-sign 2>$null

            $result = & $script:GitleaksWrapper -RepoPath $repoPath
            $result | Should -Not -BeNullOrEmpty
            $result.Source | Should -Be 'gitleaks'
            $result.SchemaVersion | Should -Be '1.0'
            $result.Status | Should -Not -Be 'Skipped'
        } finally {
            if (Test-Path $tempRoot) {
                Remove-Item -Path $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It 'runs Invoke-Trivy with the real CLI binary' -Skip:(-not (Get-Command trivy -ErrorAction SilentlyContinue)) {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("live-trivy-" + [guid]::NewGuid().ToString('N'))
        try {
            $null = New-Item -ItemType Directory -Path $tempRoot -Force
            Set-Content -Path (Join-Path $tempRoot 'package.json') -Value '{"name":"live-trivy","version":"1.0.0"}' -Encoding UTF8

            $result = & $script:TrivyWrapper -ScanPath $tempRoot -ScanType 'fs'
            $result | Should -Not -BeNullOrEmpty
            $result.Source | Should -Be 'trivy'
            $result.SchemaVersion | Should -Be '1.0'
            $result.Status | Should -Not -Be 'Skipped'
        } finally {
            if (Test-Path $tempRoot) {
                Remove-Item -Path $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It 'runs Invoke-Zizmor with the real CLI binary' -Skip:(-not (Get-Command zizmor -ErrorAction SilentlyContinue)) {
        $result = & $script:ZizmorWrapper -Repository $script:RepoRoot
        $result | Should -Not -BeNullOrEmpty
        $result.Source | Should -Be 'zizmor'
        $result.SchemaVersion | Should -Be '1.0'
        $result.Status | Should -Not -Be 'Skipped'
    }

    It 'runs Invoke-Scorecard with the real CLI binary' -Skip:(-not (Get-Command scorecard -ErrorAction SilentlyContinue)) {
        $result = & $script:ScorecardWrapper -Repository 'github.com/martinopedal/azure-analyzer'
        $result | Should -Not -BeNullOrEmpty
        $result.Source | Should -Be 'scorecard'
        $result.SchemaVersion | Should -Be '1.0'
        $result.Status | Should -Not -Be 'Skipped'
    }
}
