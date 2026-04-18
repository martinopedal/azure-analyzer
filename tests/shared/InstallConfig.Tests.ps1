#Requires -Version 7.4
Set-StrictMode -Version Latest

BeforeAll {
    $repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..')
    . (Join-Path $repoRoot 'modules\shared\Installer.ps1')
}

Describe 'Test-InstallConfig' {
    BeforeAll {
        $repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..')
        $manifest = Get-Content (Join-Path $repoRoot 'tools\tool-manifest.json') -Raw | ConvertFrom-Json
    }

    It 'accepts a valid minimal config' {
        $cfg = [PSCustomObject]@{
            schemaVersion = '1.0'
            defaults = [PSCustomObject]@{ autoInstall = $true }
            tools = [PSCustomObject]@{}
        }
        $result = Test-InstallConfig -Config $cfg -Manifest $manifest
        $result.Valid | Should -BeTrue
        $result.Errors | Should -HaveCount 0
    }

    It 'accepts a config with known tool overrides' {
        $cfg = [PSCustomObject]@{
            schemaVersion = '1.0'
            defaults = [PSCustomObject]@{ autoInstall = $true }
            tools = [PSCustomObject]@{
                trivy = [PSCustomObject]@{ enabled = $true; manager = 'winget' }
                gitleaks = [PSCustomObject]@{ enabled = $false }
            }
        }
        $result = Test-InstallConfig -Config $cfg -Manifest $manifest
        $result.Valid | Should -BeTrue
    }

    It 'rejects wrong schema version' {
        $cfg = [PSCustomObject]@{
            schemaVersion = '2.0'
            tools = [PSCustomObject]@{}
        }
        $result = Test-InstallConfig -Config $cfg -Manifest $manifest
        $result.Valid | Should -BeFalse
        $result.Errors | Should -Contain "schemaVersion must be '1.0', got '2.0'."
    }

    It 'rejects missing schema version' {
        $cfg = [PSCustomObject]@{
            tools = [PSCustomObject]@{}
        }
        $result = Test-InstallConfig -Config $cfg -Manifest $manifest
        $result.Valid | Should -BeFalse
        ($result.Errors | Where-Object { $_ -match 'schemaVersion' }) | Should -Not -BeNullOrEmpty
        ($result.Errors | Where-Object { $_ -match '<missing>' }) | Should -Not -BeNullOrEmpty
    }

    It 'rejects unknown top-level keys' {
        $cfg = [PSCustomObject]@{
            schemaVersion = '1.0'
            tools = [PSCustomObject]@{}
            hackerPayload = 'drop tables'
        }
        $result = Test-InstallConfig -Config $cfg -Manifest $manifest
        $result.Valid | Should -BeFalse
        ($result.Errors | Where-Object { $_ -match 'hackerPayload' }) | Should -Not -BeNullOrEmpty
    }

    It 'rejects unknown tool names' {
        $cfg = [PSCustomObject]@{
            schemaVersion = '1.0'
            tools = [PSCustomObject]@{
                'not-a-real-tool' = [PSCustomObject]@{ enabled = $false }
            }
        }
        $result = Test-InstallConfig -Config $cfg -Manifest $manifest
        $result.Valid | Should -BeFalse
        ($result.Errors | Where-Object { $_ -match 'not-a-real-tool' }) | Should -Not -BeNullOrEmpty
    }

    It 'rejects disallowed package manager' {
        $cfg = [PSCustomObject]@{
            schemaVersion = '1.0'
            tools = [PSCustomObject]@{
                trivy = [PSCustomObject]@{ manager = 'curl' }
            }
        }
        $result = Test-InstallConfig -Config $cfg -Manifest $manifest
        $result.Valid | Should -BeFalse
        ($result.Errors | Where-Object { $_ -match "curl.*not in the allow-list" }) | Should -Not -BeNullOrEmpty
    }

    It 'rejects choco as a package manager (not in allow-list)' {
        $cfg = [PSCustomObject]@{
            schemaVersion = '1.0'
            tools = [PSCustomObject]@{
                trivy = [PSCustomObject]@{ manager = 'choco' }
            }
        }
        $result = Test-InstallConfig -Config $cfg -Manifest $manifest
        $result.Valid | Should -BeFalse
        ($result.Errors | Where-Object { $_ -match "choco.*not in the allow-list" }) | Should -Not -BeNullOrEmpty
    }

    It 'rejects unknown keys inside tool overrides' {
        $cfg = [PSCustomObject]@{
            schemaVersion = '1.0'
            tools = [PSCustomObject]@{
                trivy = [PSCustomObject]@{ enabled = $true; version = '0.50' }
            }
        }
        $result = Test-InstallConfig -Config $cfg -Manifest $manifest
        $result.Valid | Should -BeFalse
        ($result.Errors | Where-Object { $_ -match 'version' }) | Should -Not -BeNullOrEmpty
    }

    It 'rejects unknown defaults keys' {
        $cfg = [PSCustomObject]@{
            schemaVersion = '1.0'
            defaults = [PSCustomObject]@{ autoInstall = $true; parallel = $true }
            tools = [PSCustomObject]@{}
        }
        $result = Test-InstallConfig -Config $cfg -Manifest $manifest
        $result.Valid | Should -BeFalse
        ($result.Errors | Where-Object { $_ -match 'parallel' }) | Should -Not -BeNullOrEmpty
    }

    It 'accepts all allowed managers (winget, brew, pipx, pip, snap)' {
        foreach ($mgr in @('winget', 'brew', 'pipx', 'pip', 'snap')) {
            $cfg = [PSCustomObject]@{
                schemaVersion = '1.0'
                tools = [PSCustomObject]@{
                    trivy = [PSCustomObject]@{ manager = $mgr }
                }
            }
            $result = Test-InstallConfig -Config $cfg -Manifest $manifest
            $result.Valid | Should -BeTrue -Because "manager '$mgr' should be in the allow-list"
        }
    }
}

Describe 'Read-InstallConfig' {
    BeforeAll {
        $repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..')
        $manifest = Get-Content (Join-Path $repoRoot 'tools\tool-manifest.json') -Raw | ConvertFrom-Json
        $tempDir = if ($env:TEMP) { $env:TEMP } elseif ($env:TMPDIR) { $env:TMPDIR } else { '/tmp' }
        $testDir = Join-Path $tempDir "installconfig-tests-$(New-Guid)"
        $null = New-Item -ItemType Directory -Path $testDir -Force
    }

    AfterAll {
        if (Test-Path $testDir) {
            Remove-Item $testDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'returns null when file does not exist (backward compatible)' {
        $result = Read-InstallConfig -Path (Join-Path $testDir 'nonexistent.json') -Manifest $manifest
        $result | Should -BeNullOrEmpty
    }

    It 'returns null and warns on malformed JSON' {
        $badFile = Join-Path $testDir 'bad.json'
        'this is not json {{{' | Set-Content -Path $badFile
        $result = Read-InstallConfig -Path $badFile -Manifest $manifest 3>&1
        # The function returns $null for invalid JSON
        $returnValue = $result | Where-Object { $_ -isnot [System.Management.Automation.WarningRecord] }
        $returnValue | Should -BeNullOrEmpty
    }

    It 'returns null and warns on invalid config (bad manager)' {
        $invalidFile = Join-Path $testDir 'invalid.json'
        @{
            schemaVersion = '1.0'
            tools = @{ trivy = @{ manager = 'curl' } }
        } | ConvertTo-Json -Depth 5 | Set-Content -Path $invalidFile
        $result = Read-InstallConfig -Path $invalidFile -Manifest $manifest 3>&1
        $warnings = $result | Where-Object { $_ -is [System.Management.Automation.WarningRecord] }
        $warnings | Should -Not -BeNullOrEmpty
    }

    It 'returns parsed config for a valid file' {
        $validFile = Join-Path $testDir 'valid.json'
        @{
            schemaVersion = '1.0'
            defaults = @{ autoInstall = $true }
            tools = @{ trivy = @{ enabled = $true } }
        } | ConvertTo-Json -Depth 5 | Set-Content -Path $validFile
        $result = Read-InstallConfig -Path $validFile -Manifest $manifest
        $result | Should -Not -BeNullOrEmpty
        $result.schemaVersion | Should -Be '1.0'
    }

    It 'uses default path when -Path is empty and returns valid config or null' {
        $result = Read-InstallConfig -Path '' -Manifest $manifest
        # install-config.json exists in repo with empty tools block, so we get a config
        if ($null -ne $result) {
            $result.schemaVersion | Should -Be '1.0'
        }
        # Either way, no exception is the point
    }
}

Describe 'Install-PrerequisitesFromManifest with InstallConfig' {
    BeforeAll {
        $repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..')
        . (Join-Path $repoRoot 'modules\shared\Installer.ps1')
    }

    It 'skips tools disabled by install config' {
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
        $config = [PSCustomObject]@{
            schemaVersion = '1.0'
            defaults = [PSCustomObject]@{ autoInstall = $true }
            tools = [PSCustomObject]@{
                'fake-cli' = [PSCustomObject]@{ enabled = $false }
            }
        }
        $missing = Install-PrerequisitesFromManifest `
            -Manifest $subset `
            -RepoRoot (Resolve-Path (Join-Path $PSScriptRoot '..\..')) `
            -ShouldRunTool { param($n) $true } `
            -SkipInstall `
            -InstallConfig $config
        # Tool was skipped, so nothing is missing
        $missing | Should -Be 0
    }

    It 'does not skip tools when config has enabled=true' {
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
        $config = [PSCustomObject]@{
            schemaVersion = '1.0'
            tools = [PSCustomObject]@{
                'fake-cli' = [PSCustomObject]@{ enabled = $true }
            }
        }
        $missing = Install-PrerequisitesFromManifest `
            -Manifest $subset `
            -RepoRoot (Resolve-Path (Join-Path $PSScriptRoot '..\..')) `
            -ShouldRunTool { param($n) $true } `
            -SkipInstall `
            -InstallConfig $config
        $missing | Should -Be 1
    }

    It 'works when InstallConfig is null (backward compatible)' {
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
            -SkipInstall `
            -InstallConfig $null
        $missing | Should -Be 0
    }

    It 'CLI flags take precedence over install config' {
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
        $config = [PSCustomObject]@{
            schemaVersion = '1.0'
            tools = [PSCustomObject]@{
                'fake-cli' = [PSCustomObject]@{ enabled = $true }
            }
        }
        # ShouldRunTool returns $false (CLI -ExcludeTools takes precedence)
        $missing = Install-PrerequisitesFromManifest `
            -Manifest $subset `
            -RepoRoot (Resolve-Path (Join-Path $PSScriptRoot '..\..')) `
            -ShouldRunTool { param($n) $false } `
            -SkipInstall `
            -InstallConfig $config
        $missing | Should -Be 0
    }
}
