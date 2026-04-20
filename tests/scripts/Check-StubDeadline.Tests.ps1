#requires -Version 7.0
#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }

Describe 'Check-StubDeadline' {
    BeforeAll {
        $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
        $script:ScriptPath = Join-Path $script:RepoRoot 'scripts\Check-StubDeadline.ps1'
        $script:NewStubFixture = {
            param(
                [Parameter(Mandatory)]
                [string]$RootPath,
                [Parameter(Mandatory)]
                [string]$ModuleVersion,
                [Parameter(Mandatory)]
                [string]$ExpiresAt,
                [bool]$CreateStub = $true
            )

            $manifestPath = Join-Path $RootPath 'AzureAnalyzer.psd1'
            $stubPath = Join-Path $RootPath 'docs\legacy.md'
            $stubDirectory = Split-Path -Parent $stubPath
            $registryPath = Join-Path $RootPath '.squad\stub-deadlines.json'
            $registryDirectory = Split-Path -Parent $registryPath

            New-Item -ItemType Directory -Path $stubDirectory -Force | Out-Null
            New-Item -ItemType Directory -Path $registryDirectory -Force | Out-Null

            @"
@{
    ModuleVersion = '$ModuleVersion'
}
"@ | Set-Content -LiteralPath $manifestPath -NoNewline

            if ($CreateStub) {
                '# Moved' | Set-Content -LiteralPath $stubPath -NoNewline
            }

            @"
{
  "schemaVersion": "1.0",
  "stubs": [
    {
      "path": "docs/legacy.md",
      "replacementPath": "docs/new/location.md",
      "expiresAt": "$ExpiresAt"
    }
  ]
}
"@ | Set-Content -LiteralPath $registryPath -NoNewline

            return [PSCustomObject]@{
                ManifestPath = $manifestPath
                RegistryPath = $registryPath
                StubPath = $stubPath
            }
        }
    }

    BeforeEach {
        $global:LASTEXITCODE = 0
    }

    It 'script file exists' {
        Test-Path -LiteralPath $script:ScriptPath | Should -BeTrue
    }

    It 'Check mode succeeds when current version is below deadline' {
        $fixture = & $script:NewStubFixture -RootPath $TestDrive -ModuleVersion '1.0.0' -ExpiresAt '1.1.0'
        & $script:ScriptPath -Mode Check -ModuleManifestPath $fixture.ManifestPath -RegistryPath $fixture.RegistryPath | Out-Null
        $LASTEXITCODE | Should -Be 0
    }

    It 'Check mode fails when current version reached deadline and stub still exists' {
        $fixture = & $script:NewStubFixture -RootPath $TestDrive -ModuleVersion '1.1.0' -ExpiresAt '1.1.0'
        & $script:ScriptPath -Mode Check -ModuleManifestPath $fixture.ManifestPath -RegistryPath $fixture.RegistryPath 2>&1 | Out-Null
        $LASTEXITCODE | Should -Be 1
    }

    It 'Remove mode deletes expired stubs' {
        $fixture = & $script:NewStubFixture -RootPath $TestDrive -ModuleVersion '1.1.0' -ExpiresAt '1.1.0'
        & $script:ScriptPath -Mode Remove -ModuleManifestPath $fixture.ManifestPath -RegistryPath $fixture.RegistryPath | Out-Null
        $LASTEXITCODE | Should -Be 0
        Test-Path -LiteralPath $fixture.StubPath | Should -BeFalse
    }

    It 'Report mode returns a row for each tracked stub' {
        $fixture = & $script:NewStubFixture -RootPath $TestDrive -ModuleVersion '1.0.0' -ExpiresAt '1.1.0'
        $rows = & $script:ScriptPath -Mode Report -ModuleManifestPath $fixture.ManifestPath -RegistryPath $fixture.RegistryPath
        $LASTEXITCODE | Should -Be 0
        $rows.Count | Should -Be 1
        $rows[0].Path | Should -Be 'docs/legacy.md'
    }

    AfterAll {
        $global:LASTEXITCODE = 0
    }
}
