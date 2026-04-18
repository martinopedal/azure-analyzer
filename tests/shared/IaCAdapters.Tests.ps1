#Requires -Version 7.4
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

BeforeAll {
    $repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..')
    . (Join-Path $repoRoot 'modules\shared\Sanitize.ps1')
    . (Join-Path $repoRoot 'modules\shared\Retry.ps1')
    . (Join-Path $repoRoot 'modules\iac\IaCAdapters.ps1')
}

Describe 'IaCAdapters' {
    Context 'Invoke-IaCAdapter parameter validation' {
        It 'rejects unsupported flavour' {
            { Invoke-IaCAdapter -Flavour 'pulumi' -RepoPath '.' } | Should -Throw
        }

        It 'accepts bicep flavour' {
            $result = Invoke-IaCAdapter -Flavour 'bicep' -RepoPath $PSScriptRoot
            $result.Source | Should -Be 'bicep-iac'
        }

        It 'accepts terraform flavour' {
            $result = Invoke-IaCAdapter -Flavour 'terraform' -RepoPath $PSScriptRoot
            $result.Source | Should -Be 'terraform-iac'
        }
    }

    Context 'missing path handling' {
        It 'returns Skipped when no RepoPath or RemoteUrl is provided' {
            $result = Invoke-IaCAdapter -Flavour 'bicep'
            $result.Status | Should -Be 'Skipped'
            $result.Message | Should -Match 'No -RepoPath'
        }
    }

    Context 'sanitize behaviour' {
        It 'Remove-Credentials is available' {
            Get-Command Remove-Credentials -ErrorAction SilentlyContinue | Should -Not -BeNull
        }
    }

    Context 'Bicep validation with no .bicep files' {
        It 'returns Success with no findings when no .bicep files exist' {
            $result = Invoke-IaCAdapter -Flavour 'bicep' -RepoPath $PSScriptRoot
            $result.Status | Should -Be 'Success'
            $result.Message | Should -Match 'No .bicep files'
            @($result.Findings).Count | Should -Be 0
        }
    }

    Context 'Terraform validation with no .tf files' {
        It 'returns Success with no findings when no .tf files exist' {
            $result = Invoke-IaCAdapter -Flavour 'terraform' -RepoPath $PSScriptRoot
            $result.Status | Should -Be 'Success'
            $result.Message | Should -Match 'No .tf files'
            @($result.Findings).Count | Should -Be 0
        }
    }

    Context 'result envelope shape' {
        It 'bicep adapter returns standard envelope fields' {
            $result = Invoke-IaCAdapter -Flavour 'bicep' -RepoPath $PSScriptRoot
            $result.PSObject.Properties['Source'] | Should -Not -BeNull
            $result.PSObject.Properties['Status'] | Should -Not -BeNull
            $result.PSObject.Properties['Findings'] | Should -Not -BeNull
        }

        It 'terraform adapter returns standard envelope fields' {
            $result = Invoke-IaCAdapter -Flavour 'terraform' -RepoPath $PSScriptRoot
            $result.PSObject.Properties['Source'] | Should -Not -BeNull
            $result.PSObject.Properties['Status'] | Should -Not -BeNull
            $result.PSObject.Properties['Findings'] | Should -Not -BeNull
        }
    }

    Context 'timeout enforcement via Invoke-WithTimeout' {
        BeforeAll {
            # Create a temp dir with a dummy .bicep file for bicep tests
            $script:tempDir = Join-Path ([System.IO.Path]::GetTempPath()) "iac-test-$([guid]::NewGuid().ToString('N'))"
            New-Item -ItemType Directory -Path $script:tempDir -Force | Out-Null
            Set-Content -Path (Join-Path $script:tempDir 'main.bicep') -Value 'param location string'
        }

        AfterAll {
            if (Test-Path $script:tempDir) {
                Remove-Item $script:tempDir -Recurse -Force -ErrorAction SilentlyContinue
            }
        }

        It 'Bicep adapter calls Invoke-WithTimeout with 300s' {
            Mock Get-Command { return @{ Name = 'bicep' } } -ParameterFilter { $Name -eq 'bicep' }
            Mock Invoke-WithTimeout {
                # Verify the timeout parameter
                $TimeoutSec | Should -Be 300
                $Command | Should -Be 'bicep'
                return [PSCustomObject]@{ ExitCode = 0; Output = '' }
            }

            $result = Invoke-BicepValidation -RepoPath $script:tempDir
            Should -Invoke Invoke-WithTimeout -Times 1 -Exactly
        }

        It 'Bicep adapter emits finding when ExitCode is non-zero' {
            Mock Get-Command { return @{ Name = 'bicep' } } -ParameterFilter { $Name -eq 'bicep' }
            Mock Invoke-WithTimeout {
                return [PSCustomObject]@{
                    ExitCode = 1
                    Output   = "Error BCP062: The referenced declaration is not valid."
                }
            }

            $result = Invoke-BicepValidation -RepoPath $script:tempDir
            @($result.Findings).Count | Should -BeGreaterThan 0
            $result.Findings[0].Compliant | Should -BeFalse
        }

        It 'Bicep adapter emits finding on timeout (ExitCode=-1)' {
            Mock Get-Command { return @{ Name = 'bicep' } } -ParameterFilter { $Name -eq 'bicep' }
            Mock Invoke-WithTimeout {
                return [PSCustomObject]@{
                    ExitCode = -1
                    Output   = 'Timed out after 300 seconds'
                }
            }

            $result = Invoke-BicepValidation -RepoPath $script:tempDir
            # ExitCode -1 (timeout) is treated as non-zero, producing a finding
            @($result.Findings).Count | Should -BeGreaterThan 0
        }
    }

    Context 'terraform timeout enforcement' {
        BeforeAll {
            $script:tfDir = Join-Path ([System.IO.Path]::GetTempPath()) "iac-tf-test-$([guid]::NewGuid().ToString('N'))"
            New-Item -ItemType Directory -Path $script:tfDir -Force | Out-Null
            Set-Content -Path (Join-Path $script:tfDir 'main.tf') -Value 'resource "null_resource" "test" {}'
        }

        AfterAll {
            if (Test-Path $script:tfDir) {
                Remove-Item $script:tfDir -Recurse -Force -ErrorAction SilentlyContinue
            }
        }

        It 'Terraform adapter calls Invoke-WithTimeout with 300s for init and validate' {
            Mock Get-Command { return @{ Name = 'terraform' } } -ParameterFilter { $Name -eq 'terraform' }
            Mock Get-Command { return $null } -ParameterFilter { $Name -eq 'trivy' }
            $script:timeoutCalls = [System.Collections.Generic.List[hashtable]]::new()
            Mock Invoke-WithTimeout {
                $script:timeoutCalls.Add(@{ Command = $Command; TimeoutSec = $TimeoutSec; Arguments = $Arguments })
                $TimeoutSec | Should -Be 300
                return [PSCustomObject]@{ ExitCode = 0; Output = '{"valid":true,"diagnostics":[]}' }
            }

            $result = Invoke-TerraformValidation -RepoPath $script:tfDir
            # Should call at least twice: init + validate
            Should -Invoke Invoke-WithTimeout -Times 2 -Exactly
            $script:timeoutCalls[0].Command | Should -Be 'terraform'
            $script:timeoutCalls[0].Arguments | Should -Contain 'init'
            $script:timeoutCalls[1].Command | Should -Be 'terraform'
            $script:timeoutCalls[1].Arguments | Should -Contain 'validate'
        }
    }

    Context 'trivy config timeout produces finding' {
        BeforeAll {
            $script:trivyDir = Join-Path ([System.IO.Path]::GetTempPath()) "iac-trivy-test-$([guid]::NewGuid().ToString('N'))"
            New-Item -ItemType Directory -Path $script:trivyDir -Force | Out-Null
            Set-Content -Path (Join-Path $script:trivyDir 'main.tf') -Value 'resource "null_resource" "test" {}'
        }

        AfterAll {
            if (Test-Path $script:trivyDir) {
                Remove-Item $script:trivyDir -Recurse -Force -ErrorAction SilentlyContinue
            }
        }

        It 'emits a High-severity finding when trivy config times out' {
            Mock Get-Command { return $null } -ParameterFilter { $Name -eq 'terraform' }
            Mock Get-Command { return @{ Name = 'trivy' } } -ParameterFilter { $Name -eq 'trivy' }
            Mock Invoke-WithTimeout {
                if ($Command -eq 'trivy') {
                    return [PSCustomObject]@{ ExitCode = -1; Output = "Timed out after 300 seconds" }
                }
                return [PSCustomObject]@{ ExitCode = 0; Output = '' }
            }

            $result = Invoke-TerraformValidation -RepoPath $script:trivyDir
            @($result.Findings).Count | Should -BeGreaterThan 0
            $timeoutFinding = $result.Findings | Where-Object { $_.Title -match 'timed out' }
            $timeoutFinding | Should -Not -BeNull
            $timeoutFinding.Severity | Should -Be 'High'
            $timeoutFinding.Compliant | Should -BeFalse
        }

        It 'calls Invoke-WithTimeout with 300s for trivy config' {
            Mock Get-Command { return $null } -ParameterFilter { $Name -eq 'terraform' }
            Mock Get-Command { return @{ Name = 'trivy' } } -ParameterFilter { $Name -eq 'trivy' }
            Mock Invoke-WithTimeout {
                $TimeoutSec | Should -Be 300
                return [PSCustomObject]@{ ExitCode = 0; Output = '' }
            }

            $result = Invoke-TerraformValidation -RepoPath $script:trivyDir
            Should -Invoke Invoke-WithTimeout -Times 1 -Exactly
        }
    }

    Context 'fail-closed when timeout helper is missing' {
        It 'Assert-TimeoutHelperLoaded throws when Invoke-WithTimeout is absent' {
            Mock Get-Command { return $null } -ParameterFilter { $Name -eq 'Invoke-WithTimeout' }
            { Assert-TimeoutHelperLoaded } | Should -Throw '*Invoke-WithTimeout*'
        }
    }
}
