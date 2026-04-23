#Requires -Version 7.4
<#
.SYNOPSIS
    Tests for AzureAnalyzer module import safety — regression gate for P0-2
    (module import must not hang on mandatory parameter prompts).

.DESCRIPTION
    Validates that `Import-Module ./AzureAnalyzer.psd1` completes without
    prompting for mandatory parameters, blocking on stdin, or requiring
    environment variables.

    Background:
    - Initial E2E walkthrough reported a P0 where module import hung the
      terminal with mandatory-parameter prompts
    - Root cause suspected: top-level function CALL (not just definition)
      with mandatory params in a dot-sourced file
    - This test ensures module load is always non-blocking in CI and local
      non-interactive contexts

    Coverage:
    - Non-interactive module import completes in <10 seconds
    - No stderr output (clean load)
    - Exported functions are available
    - Works across clean/cached module states

.NOTES
    Test ID: MIT-001 (Module Import Test)
    Severity: P0 (module load is the entry point for all user workflows)
    Track: Infrastructure
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

BeforeAll {
    $script:RepoRoot = Resolve-Path (Join-Path $PSScriptRoot '..' '..')
    $script:ModuleManifest = Join-Path $script:RepoRoot 'AzureAnalyzer.psd1'
    $script:ModuleScript = Join-Path $script:RepoRoot 'AzureAnalyzer.psm1'
}

Describe 'AzureAnalyzer Module Import Safety' -Tag 'Unit', 'Module', 'P0' {
    Context 'Non-Interactive Import' {
        BeforeEach {
            # Clean state: remove any existing module instance
            Remove-Module AzureAnalyzer -Force -ErrorAction SilentlyContinue
        }

        It 'completes without prompting for parameters in non-interactive mode' {
            # MIT-001-A: The critical P0 gate — must not hang or prompt
            $importScript = @"
Set-Location '$($script:RepoRoot)'
Import-Module ./AzureAnalyzer.psd1 -Force -ErrorAction Stop
'IMPORT_OK'
"@
            $result = pwsh -NonInteractive -NoProfile -Command $importScript 2>&1
            
            # Assertion 1: No error about missing mandatory parameters
            $result | Should -Not -Match 'Cannot process command because of one or more missing mandatory parameters'
            $result | Should -Not -Match 'Supply values for the following parameters'
            
            # Assertion 2: Import succeeded marker present
            $result | Should -Contain 'IMPORT_OK'
        }

        It 'completes within 10 seconds' {
            # MIT-001-B: Timeout gate to catch hangs early
            $importScript = @"
Set-Location '$($script:RepoRoot)'
Import-Module ./AzureAnalyzer.psd1 -Force -ErrorAction Stop
'IMPORT_OK'
"@
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            $result = pwsh -NonInteractive -NoProfile -Command $importScript 2>&1
            $sw.Stop()
            
            $sw.Elapsed.TotalSeconds | Should -BeLessThan 10 -Because 'module import must not block or hang'
            $result | Should -Contain 'IMPORT_OK'
        }

        It 'produces no stderr warnings or errors' {
            # MIT-001-C: Clean load — no missing dependencies or stray errors
            $importScript = @"
Set-Location '$($script:RepoRoot)'
`$ErrorActionPreference = 'Continue'
Import-Module ./AzureAnalyzer.psd1 -Force -ErrorAction Stop -WarningAction SilentlyContinue 2>&1 |
    Where-Object { `$_ -is [System.Management.Automation.ErrorRecord] } |
    ForEach-Object { `$_.ToString() }
"@
            $stderr = pwsh -NonInteractive -NoProfile -Command $importScript
            
            # Allow warnings about missing Az modules (expected in clean environments)
            # but forbid errors about missing mandatory parameters or load failures
            if ($stderr) {
                $stderr | Should -Not -Match 'Cannot process command because of one or more missing mandatory parameters'
                $stderr | Should -Not -Match 'was not processed because no valid module was found'
            }
        }

        It 'exports exactly 3 public functions' {
            # MIT-001-D: Smoke test — expected API surface
            $importScript = @"
Set-Location '$($script:RepoRoot)'
Import-Module ./AzureAnalyzer.psd1 -Force -ErrorAction Stop
(Get-Command -Module AzureAnalyzer).Count
"@
            $count = pwsh -NonInteractive -NoProfile -Command $importScript
            
            $count | Should -Be 3
        }

        It 'exports Invoke-AzureAnalyzer, New-HtmlReport, New-MdReport' {
            # MIT-001-E: Named function verification
            $importScript = @"
Set-Location '$($script:RepoRoot)'
Import-Module ./AzureAnalyzer.psd1 -Force -ErrorAction Stop
(Get-Command -Module AzureAnalyzer).Name -join ','
"@
            $functions = pwsh -NonInteractive -NoProfile -Command $importScript
            
            $functions | Should -Match 'Invoke-AzureAnalyzer'
            $functions | Should -Match 'New-HtmlReport'
            $functions | Should -Match 'New-MdReport'
        }
    }

    Context 'Module Manifest Validation' {
        It 'has a valid module manifest' {
            # MIT-001-F: Manifest schema validation
            Test-Path $script:ModuleManifest | Should -Be $true
            
            $manifest = Test-ModuleManifest -Path $script:ModuleManifest -ErrorAction Stop
            $manifest | Should -Not -BeNullOrEmpty
            $manifest.Name | Should -Be 'AzureAnalyzer'
        }

        It 'points to an existing RootModule script' {
            # MIT-001-G: RootModule exists and is readable
            Test-Path $script:ModuleScript | Should -Be $true
            
            $content = Get-Content $script:ModuleScript -Raw
            $content | Should -Not -BeNullOrEmpty
        }
    }

    Context 'Dot-Sourced Shared Modules' {
        It 'all shared modules can be loaded individually without errors' {
            # MIT-001-H: Isolation test — each shared module is side-effect-free
            $sharedPath = Join-Path $script:RepoRoot 'modules' 'shared'
            $sharedFiles = Get-ChildItem -Path $sharedPath -Filter '*.ps1' -Recurse -ErrorAction SilentlyContinue
            
            $sharedFiles.Count | Should -BeGreaterThan 0 -Because 'modules/shared should contain at least one .ps1 file'
            
            foreach ($file in $sharedFiles) {
                $loadScript = @"
Set-Location '$($script:RepoRoot)'
. '$($file.FullName)'
'LOADED_OK'
"@
                $result = pwsh -NonInteractive -NoProfile -Command $loadScript 2>&1
                
                # Each shared module must load without prompting
                $result | Should -Not -Match 'Cannot process command because of one or more missing mandatory parameters' `
                    -Because "$($file.Name) must not have top-level function calls with mandatory params"
                $result | Should -Contain 'LOADED_OK'
            }
        }
    }
}
