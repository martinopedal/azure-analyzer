#Requires -Version 7.4
Set-StrictMode -Version Latest

BeforeAll {
    $repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..')
    $zizmorScript = Join-Path $repoRoot 'modules\Invoke-Zizmor.ps1'
    $gitleaksScript = Join-Path $repoRoot 'modules\Invoke-Gitleaks.ps1'
    $trivyScript = Join-Path $repoRoot 'modules\Invoke-Trivy.ps1'
}

Describe 'Remote-first wrapper targeting' {
    BeforeEach {
        Remove-Item Function:\Invoke-RemoteRepoClone -ErrorAction SilentlyContinue
        Remove-Item Function:\zizmor -ErrorAction SilentlyContinue
        Remove-Item Function:\gitleaks -ErrorAction SilentlyContinue
        Remove-Item Function:\trivy -ErrorAction SilentlyContinue
        $global:cleanupCalled = $false
        function global:zizmor { $global:LASTEXITCODE = 0 }
        function global:gitleaks { $global:LASTEXITCODE = 0 }
        function global:trivy { $global:LASTEXITCODE = 0 }
    }

    Context 'Invoke-Zizmor.ps1' {
        It 'uses remote clone when Repository is provided' {
            $remoteDir = Join-Path ([System.IO.Path]::GetTempPath()) "zizmor-remote-$([guid]::NewGuid().ToString('N'))"
            $null = New-Item -ItemType Directory -Path (Join-Path $remoteDir '.github/workflows') -Force
            Set-Content -Path (Join-Path $remoteDir '.github/workflows/ci.yml') -Value 'name: ci'

            function global:Invoke-RemoteRepoClone {
                param([string]$RepoUrl)
                return [PSCustomObject]@{
                    Path = $remoteDir
                    Cleanup = { Remove-Item -LiteralPath $remoteDir -Recurse -Force -ErrorAction SilentlyContinue; $global:cleanupCalled = $true }
                }
            }

            $global:capturedScanPath = ''
            function global:zizmor {
                param([Parameter(ValueFromRemainingArguments = $true)][object[]]$Args)
                $outputIndex = [Array]::IndexOf($Args, '--output')
                $reportFile = [string]$Args[$outputIndex + 1]
                $global:capturedScanPath = [string]$Args[-1]
                Set-Content -Path $reportFile -Value '[]'
                $global:LASTEXITCODE = 0
            }

            $result = & $zizmorScript -Repository 'github.com/owner/repo'

            $result.Status | Should -Be 'Success'
            $global:capturedScanPath | Should -Be (Join-Path $remoteDir '.github/workflows')
            $global:cleanupCalled | Should -BeTrue
        }

        It 'falls back to local RepoPath when no remote target is provided' {
            $localDir = Join-Path ([System.IO.Path]::GetTempPath()) "zizmor-local-$([guid]::NewGuid().ToString('N'))"
            $null = New-Item -ItemType Directory -Path (Join-Path $localDir '.github/workflows') -Force
            Set-Content -Path (Join-Path $localDir '.github/workflows/ci.yml') -Value 'name: ci'

            $global:capturedScanPath = ''
            function global:zizmor {
                param([Parameter(ValueFromRemainingArguments = $true)][object[]]$Args)
                $outputIndex = [Array]::IndexOf($Args, '--output')
                $reportFile = [string]$Args[$outputIndex + 1]
                $global:capturedScanPath = [string]$Args[-1]
                Set-Content -Path $reportFile -Value '[]'
                $global:LASTEXITCODE = 0
            }

            $result = & $zizmorScript -RepoPath $localDir

            $result.Status | Should -Be 'Success'
            $global:capturedScanPath | Should -Be (Join-Path $localDir '.github/workflows')
        }

        It 'returns Failed for disallowed remote host' {
            function global:zizmor { param([Parameter(ValueFromRemainingArguments = $true)][object[]]$Args) $global:LASTEXITCODE = 0 }
            $result = & $zizmorScript -Repository 'https://evil.example.com/org/repo'

            $result.Status | Should -Be 'Failed'
            $result.Message | Should -Match 'Allowed hosts'
        }

        It 'runs cleanup even when scanner throws' {
            $remoteDir = Join-Path ([System.IO.Path]::GetTempPath()) "zizmor-cleanup-$([guid]::NewGuid().ToString('N'))"
            $null = New-Item -ItemType Directory -Path (Join-Path $remoteDir '.github/workflows') -Force
            Set-Content -Path (Join-Path $remoteDir '.github/workflows/ci.yml') -Value 'name: ci'

            function global:Invoke-RemoteRepoClone {
                param([string]$RepoUrl)
                return [PSCustomObject]@{
                    Path = $remoteDir
                    Cleanup = { Remove-Item -LiteralPath $remoteDir -Recurse -Force -ErrorAction SilentlyContinue; $global:cleanupCalled = $true }
                }
            }

            function global:zizmor { throw 'simulated zizmor failure' }
            $result = & $zizmorScript -Repository 'github.com/owner/repo'

            $result.Status | Should -Be 'Failed'
            $global:cleanupCalled | Should -BeTrue
        }
    }

    Context 'Invoke-Gitleaks.ps1' {
        It 'uses remote clone when Repository is provided' {
            $remoteDir = Join-Path ([System.IO.Path]::GetTempPath()) "gitleaks-remote-$([guid]::NewGuid().ToString('N'))"
            $null = New-Item -ItemType Directory -Path $remoteDir -Force
            Set-Content -Path (Join-Path $remoteDir 'README.md') -Value 'content'

            function global:Invoke-RemoteRepoClone {
                param([string]$RepoUrl)
                return [PSCustomObject]@{
                    Path = $remoteDir
                    Cleanup = { Remove-Item -LiteralPath $remoteDir -Recurse -Force -ErrorAction SilentlyContinue; $global:cleanupCalled = $true }
                }
            }

            $global:capturedSourcePath = ''
            function global:gitleaks {
                param([Parameter(ValueFromRemainingArguments = $true)][object[]]$Args)
                $sourceIndex = [Array]::IndexOf($Args, '--source')
                $reportIndex = [Array]::IndexOf($Args, '--report-path')
                $global:capturedSourcePath = [string]$Args[$sourceIndex + 1]
                Set-Content -Path ([string]$Args[$reportIndex + 1]) -Value '[]'
                $global:LASTEXITCODE = 0
            }

            $result = & $gitleaksScript -Repository 'github.com/owner/repo'

            $result.Status | Should -Be 'Success'
            $global:capturedSourcePath | Should -Be $remoteDir
            $global:cleanupCalled | Should -BeTrue
        }

        It 'falls back to local RepoPath when no remote target is provided' {
            $localDir = Join-Path ([System.IO.Path]::GetTempPath()) "gitleaks-local-$([guid]::NewGuid().ToString('N'))"
            $null = New-Item -ItemType Directory -Path $localDir -Force
            Set-Content -Path (Join-Path $localDir 'README.md') -Value 'content'

            $global:capturedSourcePath = ''
            function global:gitleaks {
                param([Parameter(ValueFromRemainingArguments = $true)][object[]]$Args)
                $sourceIndex = [Array]::IndexOf($Args, '--source')
                $reportIndex = [Array]::IndexOf($Args, '--report-path')
                $global:capturedSourcePath = [string]$Args[$sourceIndex + 1]
                Set-Content -Path ([string]$Args[$reportIndex + 1]) -Value '[]'
                $global:LASTEXITCODE = 0
            }

            $result = & $gitleaksScript -RepoPath $localDir

            $result.Status | Should -Be 'Success'
            $global:capturedSourcePath | Should -Be $localDir
        }

        It 'returns Failed for disallowed remote host' {
            function global:gitleaks { param([Parameter(ValueFromRemainingArguments = $true)][object[]]$Args) $global:LASTEXITCODE = 0 }
            $result = & $gitleaksScript -Repository 'https://evil.example.com/org/repo'

            $result.Status | Should -Be 'Failed'
            $result.Message | Should -Match 'Allowed hosts'
        }

        It 'runs cleanup even when scanner throws' {
            $remoteDir = Join-Path ([System.IO.Path]::GetTempPath()) "gitleaks-cleanup-$([guid]::NewGuid().ToString('N'))"
            $null = New-Item -ItemType Directory -Path $remoteDir -Force
            Set-Content -Path (Join-Path $remoteDir 'README.md') -Value 'content'

            function global:Invoke-RemoteRepoClone {
                param([string]$RepoUrl)
                return [PSCustomObject]@{
                    Path = $remoteDir
                    Cleanup = { Remove-Item -LiteralPath $remoteDir -Recurse -Force -ErrorAction SilentlyContinue; $global:cleanupCalled = $true }
                }
            }

            function global:gitleaks { throw 'simulated gitleaks failure' }
            $result = & $gitleaksScript -Repository 'github.com/owner/repo'

            $result.Status | Should -Be 'Failed'
            $global:cleanupCalled | Should -BeTrue
        }
    }

    Context 'Invoke-Trivy.ps1' {
        It 'uses remote clone when Repository is provided' {
            $remoteDir = Join-Path ([System.IO.Path]::GetTempPath()) "trivy-remote-$([guid]::NewGuid().ToString('N'))"
            $null = New-Item -ItemType Directory -Path $remoteDir -Force
            Set-Content -Path (Join-Path $remoteDir 'package-lock.json') -Value '{}'

            function global:Invoke-RemoteRepoClone {
                param([string]$RepoUrl)
                return [PSCustomObject]@{
                    Path = $remoteDir
                    Cleanup = { Remove-Item -LiteralPath $remoteDir -Recurse -Force -ErrorAction SilentlyContinue; $global:cleanupCalled = $true }
                }
            }

            $global:capturedScanType = ''
            $global:capturedScanPath = ''
            function global:trivy {
                param([Parameter(ValueFromRemainingArguments = $true)][object[]]$Args)
                if ($Args -contains '--version') {
                    return 'Version: 0.56.0'
                }
                $global:capturedScanType = [string]$Args[0]
                $outputIndex = [Array]::IndexOf($Args, '--output')
                $global:capturedScanPath = [string]$Args[-1]
                Set-Content -Path ([string]$Args[$outputIndex + 1]) -Value '{"Results":[]}'
                $global:LASTEXITCODE = 0
            }

            $result = & $trivyScript -Repository 'github.com/owner/repo' -ScanType 'repo'

            $result.Status | Should -Be 'Success'
            $global:capturedScanType | Should -Be 'fs'
            $global:capturedScanPath | Should -Be $remoteDir
            $global:cleanupCalled | Should -BeTrue
        }

        It 'falls back to local ScanPath when no remote target is provided' {
            $localDir = Join-Path ([System.IO.Path]::GetTempPath()) "trivy-local-$([guid]::NewGuid().ToString('N'))"
            $null = New-Item -ItemType Directory -Path $localDir -Force
            Set-Content -Path (Join-Path $localDir 'package-lock.json') -Value '{}'

            $global:capturedScanPath = ''
            function global:trivy {
                param([Parameter(ValueFromRemainingArguments = $true)][object[]]$Args)
                if ($Args -contains '--version') {
                    return 'Version: 0.56.0'
                }
                $outputIndex = [Array]::IndexOf($Args, '--output')
                $global:capturedScanPath = [string]$Args[-1]
                Set-Content -Path ([string]$Args[$outputIndex + 1]) -Value '{"Results":[]}'
                $global:LASTEXITCODE = 0
            }

            $result = & $trivyScript -ScanPath $localDir

            $result.Status | Should -Be 'Success'
            $global:capturedScanPath | Should -Be $localDir
        }

        It 'returns Failed for disallowed remote host' {
            function global:trivy { param([Parameter(ValueFromRemainingArguments = $true)][object[]]$Args) $global:LASTEXITCODE = 0 }
            $result = & $trivyScript -Repository 'https://evil.example.com/org/repo'

            $result.Status | Should -Be 'Failed'
            $result.Message | Should -Match 'Allowed hosts'
        }

        It 'runs cleanup even when scanner throws' {
            $remoteDir = Join-Path ([System.IO.Path]::GetTempPath()) "trivy-cleanup-$([guid]::NewGuid().ToString('N'))"
            $null = New-Item -ItemType Directory -Path $remoteDir -Force
            Set-Content -Path (Join-Path $remoteDir 'package-lock.json') -Value '{}'

            function global:Invoke-RemoteRepoClone {
                param([string]$RepoUrl)
                return [PSCustomObject]@{
                    Path = $remoteDir
                    Cleanup = { Remove-Item -LiteralPath $remoteDir -Recurse -Force -ErrorAction SilentlyContinue; $global:cleanupCalled = $true }
                }
            }

            function global:trivy {
                param([Parameter(ValueFromRemainingArguments = $true)][object[]]$Args)
                if ($Args -contains '--version') {
                    return 'Version: 0.56.0'
                }
                throw 'simulated trivy failure'
            }
            $result = & $trivyScript -Repository 'github.com/owner/repo'

            $result.Status | Should -Be 'Failed'
            $global:cleanupCalled | Should -BeTrue
        }
    }
}
