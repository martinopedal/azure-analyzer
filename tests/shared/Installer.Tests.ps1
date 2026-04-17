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

Describe 'SHA-256 hash verification' {
    BeforeAll {
        $repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..')
        $testDir = Join-Path $env:TEMP "installer-tests-$(New-Guid)"
        $null = New-Item -ItemType Directory -Path $testDir -Force
    }
    
    AfterAll {
        if (Test-Path $testDir) {
            Remove-Item $testDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    
    Context 'Get-FileHash256' {
        It 'computes SHA-256 hash of a file' {
            $testFile = Join-Path $testDir 'test.txt'
            'test content' | Set-Content -Path $testFile -NoNewline
            
            $hash = Get-FileHash256 -Path $testFile
            $hash | Should -Match '^[a-f0-9]{64}$'
        }
        
        It 'returns lowercase hex string' {
            $testFile = Join-Path $testDir 'lowercase.txt'
            'lowercase test' | Set-Content -Path $testFile -NoNewline
            
            $hash = Get-FileHash256 -Path $testFile
            
            # Should be 64 hex chars, all lowercase
            $hash | Should -MatchExactly '^[a-f0-9]{64}$'
        }
        
        It 'throws when file does not exist' {
            { Get-FileHash256 -Path (Join-Path $testDir 'nonexistent.txt') } | 
                Should -Throw '*not found*'
        }
        
        It 'computes consistent hash for same content' {
            $testFile1 = Join-Path $testDir 'consistent1.txt'
            $testFile2 = Join-Path $testDir 'consistent2.txt'
            
            'same content' | Set-Content -Path $testFile1 -NoNewline
            'same content' | Set-Content -Path $testFile2 -NoNewline
            
            $hash1 = Get-FileHash256 -Path $testFile1
            $hash2 = Get-FileHash256 -Path $testFile2
            
            $hash1 | Should -Be $hash2
        }
    }
    
    Context 'Test-InstallManifestHash' {
        BeforeAll {
            # Create a mock install manifest
            $mockManifest = @{
                schemaVersion = '1.0'
                tools = @(
                    @{
                        name = 'test-tool'
                        version = '1.0.0'
                        platforms = @{
                            windows = @{
                                url = 'https://example.com/test.exe'
                                sha256 = 'abc123def456789012345678901234567890123456789012345678901234567890'
                            }
                            linux = @{
                                url = 'https://example.com/test-linux'
                                sha256 = 'PLACEHOLDER_COMPUTED_AT_RUNTIME'
                            }
                        }
                    }
                    @{
                        name = 'no-hash-tool'
                        version = '2.0.0'
                        platforms = @{
                            windows = @{
                                installMethod = 'winget'
                                wingetId = 'test.package'
                            }
                        }
                    }
                )
            } | ConvertTo-Json -Depth 10
            
            $mockManifestPath = Join-Path $testDir 'install-manifest.json'
            $mockManifest | Set-Content -Path $mockManifestPath -Encoding utf8
            
            # Override the script-level manifest path for testing
            $script:InstallManifestPath = $mockManifestPath
        }
        
        It 'returns true when hash matches' {
            $testFile = Join-Path $testDir 'matching.exe'
            'test content' | Set-Content -Path $testFile -NoNewline
            
            $actualHash = Get-FileHash256 -Path $testFile
            
            # Update mock manifest with actual hash
            $manifest = Get-Content $mockManifestPath -Raw | ConvertFrom-Json
            $manifest.tools[0].platforms.windows.sha256 = $actualHash
            $manifest | ConvertTo-Json -Depth 10 | Set-Content -Path $mockManifestPath -Encoding utf8
            
            $result = Test-InstallManifestHash -FilePath $testFile -ToolName 'test-tool' -Platform 'windows'
            $result | Should -BeTrue
        }
        
        It 'returns false when hash mismatches' {
            $testFile = Join-Path $testDir 'mismatching.exe'
            'different content' | Set-Content -Path $testFile -NoNewline
            
            # Manifest still has the old hash from previous test
            $result = Test-InstallManifestHash -FilePath $testFile -ToolName 'test-tool' -Platform 'windows'
            $result | Should -BeFalse
        }
        
        It 'returns true when tool not in manifest' {
            $testFile = Join-Path $testDir 'unknown.exe'
            'content' | Set-Content -Path $testFile -NoNewline
            
            $result = Test-InstallManifestHash -FilePath $testFile -ToolName 'unknown-tool' -Platform 'windows'
            $result | Should -BeTrue
        }
        
        It 'returns true when platform not in manifest' {
            $testFile = Join-Path $testDir 'noplatform.exe'
            'content' | Set-Content -Path $testFile -NoNewline
            
            $result = Test-InstallManifestHash -FilePath $testFile -ToolName 'test-tool' -Platform 'macos'
            $result | Should -BeTrue
        }
        
        It 'returns true when SHA-256 is placeholder' {
            $testFile = Join-Path $testDir 'placeholder.bin'
            'content' | Set-Content -Path $testFile -NoNewline
            
            $result = Test-InstallManifestHash -FilePath $testFile -ToolName 'test-tool' -Platform 'linux'
            $result | Should -BeTrue
        }
        
        It 'returns true when tool has no SHA-256 (delegated to package manager)' {
            $testFile = Join-Path $testDir 'nohash.exe'
            'content' | Set-Content -Path $testFile -NoNewline
            
            $result = Test-InstallManifestHash -FilePath $testFile -ToolName 'no-hash-tool' -Platform 'windows'
            $result | Should -BeTrue
        }
        
        It 'returns true when manifest does not exist' {
            $script:InstallManifestPath = Join-Path $testDir 'nonexistent-manifest.json'
            
            $testFile = Join-Path $testDir 'nomanifest.exe'
            'content' | Set-Content -Path $testFile -NoNewline
            
            $result = Test-InstallManifestHash -FilePath $testFile -ToolName 'any-tool' -Platform 'windows'
            $result | Should -BeTrue
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
