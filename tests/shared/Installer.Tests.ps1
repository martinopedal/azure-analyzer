#Requires -Version 7.4
Set-StrictMode -Version Latest

BeforeAll {
    $repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..')
    . (Join-Path $repoRoot 'modules\shared\Installer.ps1')
}

Describe 'Installer helpers' {
    Context 'Get-CurrentOS' {
        It 'returns one of windows/macos/linux' {
            Get-CurrentOS | Should -BeIn @('windows', 'macos', 'linux')
        }
    }

    Context 'Test-CliAvailable' {
        It 'returns true for a shell builtin like pwsh' {
            Test-CliAvailable -Command 'pwsh' | Should -BeTrue
        }
        It 'returns false for a bogus command' {
            Test-CliAvailable -Command 'definitely-not-a-real-command-xyz123' | Should -BeFalse
        }
    }

    Context 'Test-PSModuleAvailable' {
        It 'returns true for Pester which is clearly installed' {
            Test-PSModuleAvailable -Name 'Pester' | Should -BeTrue
        }
        It 'returns false for a bogus module' {
            Test-PSModuleAvailable -Name 'NotARealModule-xyz123' | Should -BeFalse
        }
    }
}

Describe 'Install-PrerequisitesFromManifest' {
    BeforeAll {
        $repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..')
        $manifest = Get-Content (Join-Path $repoRoot 'tools\tool-manifest.json') -Raw | ConvertFrom-Json
    }

    It 'returns a missing count without throwing when SkipInstall is set' {
        $missing = Install-PrerequisitesFromManifest `
            -Manifest $manifest `
            -RepoRoot (Resolve-Path (Join-Path $PSScriptRoot '..\..')) `
            -ShouldRunTool { param($n) $false } `
            -SkipInstall
        $missing | Should -BeOfType [int]
    }

    It 'honours ShouldRunTool filter (no action when all excluded)' {
        $missing = Install-PrerequisitesFromManifest `
            -Manifest $manifest `
            -RepoRoot (Resolve-Path (Join-Path $PSScriptRoot '..\..')) `
            -ShouldRunTool { param($n) $false } `
            -SkipInstall
        $missing | Should -Be 0
    }

    It 'treats install.kind=none tools as fully satisfied' {
        $subset = [PSCustomObject]@{
            tools = @(
                [PSCustomObject]@{
                    name = 'nothing-needed'
                    displayName = 'Nothing needed'
                    enabled = $true
                    install = [PSCustomObject]@{ kind = 'none' }
                }
            )
        }
        $missing = Install-PrerequisitesFromManifest `
            -Manifest $subset `
            -RepoRoot (Resolve-Path (Join-Path $PSScriptRoot '..\..')) `
            -ShouldRunTool { param($n) $true } `
            -SkipInstall
        $missing | Should -Be 0
    }

    It 'flags missing CLI tools when SkipInstall is set' {
        $subset = [PSCustomObject]@{
            tools = @(
                [PSCustomObject]@{
                    name = 'fake-cli'
                    displayName = 'Fake CLI'
                    enabled = $true
                    install = [PSCustomObject]@{
                        kind = 'cli'
                        command = 'definitely-not-a-real-command-xyz123'
                        windows = [PSCustomObject]@{ url = 'https://example.com' }
                        macos   = [PSCustomObject]@{ url = 'https://example.com' }
                        linux   = [PSCustomObject]@{ url = 'https://example.com' }
                    }
                }
            )
        }
        $missing = Install-PrerequisitesFromManifest `
            -Manifest $subset `
            -RepoRoot (Resolve-Path (Join-Path $PSScriptRoot '..\..')) `
            -ShouldRunTool { param($n) $true } `
            -SkipInstall
        $missing | Should -Be 1
    }

    It 'skips disabled tools' {
        $subset = [PSCustomObject]@{
            tools = @(
                [PSCustomObject]@{
                    name = 'disabled-tool'
                    displayName = 'Disabled'
                    enabled = $false
                    install = [PSCustomObject]@{
                        kind = 'cli'
                        command = 'definitely-not-a-real-command-xyz123'
                    }
                }
            )
        }
        $missing = Install-PrerequisitesFromManifest `
            -Manifest $subset `
            -RepoRoot (Resolve-Path (Join-Path $PSScriptRoot '..\..')) `
            -ShouldRunTool { param($n) $true } `
            -SkipInstall
        $missing | Should -Be 0
    }
}

Describe 'Manifest wiring' {
    BeforeAll {
        $repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..')
        $manifest = Get-Content (Join-Path $repoRoot 'tools\tool-manifest.json') -Raw | ConvertFrom-Json
    }

    It 'every enabled tool has an install block' {
        foreach ($t in $manifest.tools) {
            if (-not $t.enabled) { continue }
            $t.PSObject.Properties['install'] | Should -Not -BeNullOrEmpty
            $t.install.kind | Should -BeIn @('cli', 'psmodule', 'gitclone', 'none')
        }
    }

    It 'every enabled tool has a report color and phase' {
        foreach ($t in $manifest.tools) {
            if (-not $t.enabled) { continue }
            $t.PSObject.Properties['report'] | Should -Not -BeNullOrEmpty
            $t.report.color | Should -Match '^#[0-9a-fA-F]{6}$'
            $t.report.phase | Should -BeIn @(1, 2, 3, 4, 5, 6)
        }
    }

    It 'cli install entries reference a probe command' {
        foreach ($t in $manifest.tools) {
            if (-not $t.enabled) { continue }
            if ($t.install.kind -ne 'cli') { continue }
            $t.install.command | Should -Not -BeNullOrEmpty
        }
    }

    It 'gitclone install entries specify repo, target, and probe' {
        foreach ($t in $manifest.tools) {
            if (-not $t.enabled) { continue }
            if ($t.install.kind -ne 'gitclone') { continue }
            $t.install.repo   | Should -Match '^https?://'
            $t.install.target | Should -Not -BeNullOrEmpty
            $t.install.probe  | Should -Not -BeNullOrEmpty
        }
    }
}
