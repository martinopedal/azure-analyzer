#Requires -Version 7.4
Set-StrictMode -Version Latest

<#
.SYNOPSIS
    Guards against Pester version drift in CI workflows (#851).

.DESCRIPTION
    The Pester-null CI regression on all matrix OSes (#844, #849, #851,
    #856) traced back to `Install-Module Pester -MinimumVersion 5.0` and
    `Import-Module Pester -MinimumVersion 5.0` -- both let Pester 6.x
    (which has a different [PesterConfiguration] surface and has been
    observed returning $null from Invoke-Pester -PassThru on some OSes)
    be picked up the moment it ships stable.

    This test locks the *pin*: every workflow that runs Pester MUST use
    `-RequiredVersion` with the repo's canonical version so every matrix
    OS executes the identical engine. If someone adds a new workflow
    that runs Pester with `-MinimumVersion`, this test fails fast instead
    of waiting for a red CI run on main.
#>

$script:CanonicalPin  = '5.7.1'
$script:WorkflowFiles = @('ci.yml', 'e2e.yml', 'release.yml')
$script:WorkflowsDir  = Join-Path $PSScriptRoot '..' '..' '.github' 'workflows'

Describe 'Pester version pin (#851)' {

    BeforeAll {
        $script:CanonicalPin  = '5.7.1'
        $script:WorkflowsDir  = Join-Path $PSScriptRoot '..' '..' '.github' 'workflows'
    }

    Context 'Install-Module Pester uses -RequiredVersion, not -MinimumVersion' {
        It '<WorkflowFile> does not Install-Module Pester with -MinimumVersion' -ForEach (
            $script:WorkflowFiles | ForEach-Object { @{ WorkflowFile = $_ } }
        ) {
            $full = Join-Path $script:WorkflowsDir $WorkflowFile
            Test-Path $full | Should -BeTrue -Because "workflow $WorkflowFile must exist"
            $lines = Get-Content -Path $full
            # Ignore YAML comment lines; only assert on executable lines.
            $codeLines = $lines | Where-Object { $_ -notmatch '^\s*#' }
            $offenders = $codeLines | Where-Object { $_ -match 'Install-Module\s+Pester.*-MinimumVersion' }
            $offenders | Should -BeNullOrEmpty `
                -Because "$WorkflowFile must pin Pester via -RequiredVersion to prevent a Pester 6 upgrade from silently regressing CI (#851)"
        }

        It '<WorkflowFile> does not Import-Module Pester with -MinimumVersion' -ForEach (
            $script:WorkflowFiles | ForEach-Object { @{ WorkflowFile = $_ } }
        ) {
            $full = Join-Path $script:WorkflowsDir $WorkflowFile
            $lines = Get-Content -Path $full
            $codeLines = $lines | Where-Object { $_ -notmatch '^\s*#' }
            $offenders = $codeLines | Where-Object { $_ -match 'Import-Module\s+Pester.*-MinimumVersion' }
            $offenders | Should -BeNullOrEmpty `
                -Because "$WorkflowFile must import Pester via -RequiredVersion to avoid loading a Pester 6 side-install (#851)"
        }
    }

    Context 'Canonical Pester pin is consistent across workflows' {
        It '<WorkflowFile> pins Pester to the canonical version when it uses Pester' -ForEach (
            $script:WorkflowFiles | ForEach-Object { @{ WorkflowFile = $_ } }
        ) {
            $full = Join-Path $script:WorkflowsDir $WorkflowFile
            $content = Get-Content -Path $full -Raw
            if ($content -notmatch '(Install|Import)-Module\s+Pester') { return }
            $content | Should -Match ([regex]::Escape("-RequiredVersion $script:CanonicalPin")) `
                -Because "$WorkflowFile must pin Pester to $script:CanonicalPin so every matrix OS executes the identical engine (#851)"
        }
    }

    Context 'Null-return handling surfaces the loaded Pester version for triage' {
        It 'ci.yml emits the loaded Pester version when Invoke-Pester returns null' {
            $full = Join-Path $script:WorkflowsDir 'ci.yml'
            $content = Get-Content -Path $full -Raw
            $content | Should -Match 'Loaded Pester=' `
                -Because 'ci.yml must log the loaded Pester module version on null-return so triage is not blind (#851)'
        }
    }
}
