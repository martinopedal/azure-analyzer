#Requires -Version 7.4
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

BeforeAll {
    $script:Here = Split-Path $PSCommandPath -Parent
    $script:RepoRoot = Resolve-Path (Join-Path $script:Here '..' '..')
    . (Join-Path $script:RepoRoot 'modules' 'shared' 'Viewer.ps1')
}

Describe 'viewer architecture wiring' {
    It 'derives counts from output files using the merged ReportManifest contract' {
        $outDir = Join-Path $TestDrive 'viewer-counts'
        New-Item -ItemType Directory -Path $outDir -Force | Out-Null

        @(
            [pscustomobject]@{ Id = 'f-1' },
            [pscustomobject]@{ Id = 'f-2' }
        ) | ConvertTo-Json -Depth 4 | Set-Content -Path (Join-Path $outDir 'results.json') -Encoding UTF8

        @{
            SchemaVersion = '3.1'
            Entities      = @(@{ EntityId = 'tenant:1' })
            Edges         = @(@{ EdgeId = 'e1' }, @{ EdgeId = 'e2' }, @{ EdgeId = 'e3' })
        } | ConvertTo-Json -Depth 6 | Set-Content -Path (Join-Path $outDir 'entities.json') -Encoding UTF8

        $result = Resolve-ViewerArchitecture `
            -FindingsPath (Join-Path $outDir 'results.json') `
            -EntitiesPath (Join-Path $outDir 'entities.json')

        $result.Tier | Should -Be 'PureJson'
        $result.Measurements.Findings | Should -Be 2
        $result.Measurements.Entities | Should -Be 1
        $result.Measurements.Edges | Should -Be 3
    }

    It 'reports edges=0 for v3.0 bare-array entities.json (regression guard)' {
        $outDir = Join-Path $TestDrive 'viewer-bare-array'
        New-Item -ItemType Directory -Path $outDir -Force | Out-Null

        # v3.0 bare-array entities.json: a JSON array root with no Edges property at all.
        @(
            [pscustomobject]@{ EntityId = 'tenant:1' },
            [pscustomobject]@{ EntityId = 'tenant:2' },
            [pscustomobject]@{ EntityId = 'tenant:3' },
            [pscustomobject]@{ EntityId = 'tenant:4' },
            [pscustomobject]@{ EntityId = 'tenant:5' }
        ) | ConvertTo-Json -Depth 4 | Set-Content -Path (Join-Path $outDir 'entities.json') -Encoding UTF8

        # Edges count derived from the bare-array file MUST default to 0, NOT entity count.
        $edges = Get-ViewerJsonCount -Path (Join-Path $outDir 'entities.json') -PropertyPreference @('Edges','edges') -ArrayIsAxis:$false
        $edges | Should -Be 0

        $entities = Get-ViewerJsonCount -Path (Join-Path $outDir 'entities.json') -PropertyPreference @('Entities','entities') -ArrayIsAxis:$true
        $entities | Should -Be 5

        $arch = Resolve-ViewerArchitecture -EntitiesPath (Join-Path $outDir 'entities.json')
        $arch.Measurements.Entities | Should -Be 5
        $arch.Measurements.Edges | Should -Be 0
    }
}

Describe 'viewer security stubs' {
    It 'accepts loopback-only bind address' {
        (Test-LoopbackBind -Address '127.0.0.1') | Should -BeTrue
        (Test-LoopbackBind -Address 'localhost') | Should -BeTrue
        (Test-LoopbackBind -Address 'LocalHost') | Should -BeTrue
        (Test-LoopbackBind -Address '') | Should -BeFalse
        (Test-LoopbackBind -Address '   ') | Should -BeFalse
        (Test-LoopbackBind -Address '::1') | Should -BeFalse
        (Test-LoopbackBind -Address '0.0.0.0') | Should -BeFalse
    }

    It 'validates host header against loopback and selected port' {
        (Test-HostHeader -HostHeader '127.0.0.1:4280' -Port 4280) | Should -BeTrue
        (Test-HostHeader -HostHeader '127.0.0.1' -Port 4280) | Should -BeTrue
        (Test-HostHeader -HostHeader 'localhost' -Port 4280) | Should -BeTrue
        (Test-HostHeader -HostHeader '127.0.0.1:9999' -Port 4280) | Should -BeFalse
        (Test-HostHeader -HostHeader 'evil.example:4280' -Port 4280) | Should -BeFalse
    }

    It 'validates origin header for same-origin loopback requests' {
        (Test-OriginHeader -Origin 'http://127.0.0.1:4280' -Port 4280) | Should -BeTrue
        (Test-OriginHeader -Origin 'http://localhost:4280' -Port 4280) | Should -BeTrue
        (Test-OriginHeader -Origin 'https://127.0.0.1:4280' -Port 4280) | Should -BeFalse
        (Test-OriginHeader -Origin 'http://example.com:4280' -Port 4280) | Should -BeFalse
    }

    It 'compares csrf tokens without plain string equality shortcuts' {
        (Test-CsrfToken -ProvidedToken 'abc123' -ExpectedToken 'abc123') | Should -BeTrue
        (Test-CsrfToken -ProvidedToken 'abc123' -ExpectedToken 'abc124') | Should -BeFalse
    }

    It 'rejects unsafe entity identifiers' {
        (Test-EntityIdSafe -EntityId 'tenant:11111111-1111-1111-1111-111111111111') | Should -BeTrue
        (Test-EntityIdSafe -EntityId '../etc/passwd') | Should -BeFalse
    }
}

Describe 'viewer cookie-bootstrap auth' {
    It 'parses an aa_session cookie out of a Cookie header' {
        Get-ViewerCookieValue -CookieHeader 'aa_session=abc123' -Name 'aa_session' | Should -Be 'abc123'
        Get-ViewerCookieValue -CookieHeader 'foo=bar; aa_session=xyz; baz=qux' -Name 'aa_session' | Should -Be 'xyz'
        Get-ViewerCookieValue -CookieHeader '' -Name 'aa_session' | Should -BeNullOrEmpty
        Get-ViewerCookieValue -CookieHeader 'foo=bar' -Name 'aa_session' | Should -BeNullOrEmpty
    }

    It 'accepts a valid session via cookie OR header but rejects mismatched/empty input' {
        $expected = 'tok-good'
        (Test-ViewerSessionAuth -CookieHeader 'aa_session=tok-good' -TokenHeader $null -ExpectedToken $expected) | Should -BeTrue
        (Test-ViewerSessionAuth -CookieHeader $null -TokenHeader 'tok-good' -ExpectedToken $expected) | Should -BeTrue
        (Test-ViewerSessionAuth -CookieHeader 'aa_session=tok-bad' -TokenHeader $null -ExpectedToken $expected) | Should -BeFalse
        (Test-ViewerSessionAuth -CookieHeader $null -TokenHeader 'tok-bad' -ExpectedToken $expected) | Should -BeFalse
        (Test-ViewerSessionAuth -CookieHeader $null -TokenHeader $null -ExpectedToken $expected) | Should -BeFalse
    }
}

Describe 'viewer lifecycle' {
    BeforeEach {
        $script:CapturedStartJobScript = $null
        $script:AzureAnalyzerViewerState.IsRunning = $false
        $script:AzureAnalyzerViewerState.Port = $null
        $script:AzureAnalyzerViewerState.Token = $null
        $script:AzureAnalyzerViewerState.Tier = $null
        $script:AzureAnalyzerViewerState.Job = $null
    }

    It 'throws when asked to bind to a non-loopback address' {
        { Start-AzureAnalyzerViewer -OutputPath $TestDrive -BindAddress '0.0.0.0' } | Should -Throw -ExpectedMessage '*loopback-only*'
    }

    It 'fails fast with a helpful message when Pode is not installed' {
        Mock Get-Command { $null } -ParameterFilter { $Name -eq 'Start-PodeServer' }
        Mock Test-ViewerPortAvailable { $true }
        Mock Import-Module { throw 'Module Pode was not found' } -ParameterFilter { $Name -eq 'Pode' }
        { Start-AzureAnalyzerViewer -OutputPath $TestDrive -Port 4282 } | Should -Throw -ExpectedMessage '*Pode module is required*'
    }

    It 'fails fast when the chosen viewer port is already in use' {
        Mock Test-ViewerPortAvailable { $false }
        Mock Get-Command {
            [pscustomobject]@{ Name = 'Start-PodeServer'; CommandType = 'Function' }
        } -ParameterFilter { $Name -eq 'Start-PodeServer' }
        { Start-AzureAnalyzerViewer -OutputPath $TestDrive -Port 4283 } | Should -Throw -ExpectedMessage '*already in use*'
    }

    It 'starts a Pode-backed job, wires /api/health, /api/triage, /auth and / routes, and waits for readiness' {
        Mock Get-Command {
            [pscustomobject]@{ Name = 'Start-PodeServer'; CommandType = 'Function' }
        } -ParameterFilter { $Name -eq 'Start-PodeServer' }
        Mock Test-ViewerPortAvailable { $true }
        Mock Wait-ViewerHealthReady { $true }
        Mock Start-Sleep {}
        Mock Start-Job {
            param($Name, $ScriptBlock, $ArgumentList)
            $script:CapturedStartJobScript = $ScriptBlock.ToString()
            return [pscustomobject]@{
                Id    = 9001
                Name  = $Name
                State = 'Running'
            }
        }

        $result = Start-AzureAnalyzerViewer -OutputPath $TestDrive -Port 4281

        $result.Url | Should -Be 'http://127.0.0.1:4281/'
        $result.HealthUrl | Should -Be 'http://127.0.0.1:4281/api/health'
        $result.AuthUrl | Should -Match '^http://127\.0\.0\.1:4281/auth\?t=[0-9a-f]{32}$'
        $script:CapturedStartJobScript | Should -Match '/api/health'
        $script:CapturedStartJobScript | Should -Match '/api/triage'
        $script:CapturedStartJobScript | Should -Match "Path '/auth'"
        # /api/health must validate Host header (DNS-rebinding guard).
        $script:CapturedStartJobScript | Should -Match 'invalid_host'
        # / must accept either the cookie or the header.
        $script:CapturedStartJobScript | Should -Match 'Test-ViewerSessionAuth'
        $script:CapturedStartJobScript | Should -Match 'triage-panel'
    }

    It 'stops and clears active viewer job state' {
        $script:AzureAnalyzerViewerState.Job = [pscustomobject]@{ Id = 77; State = 'Running' }
        Mock Stop-Job {}
        Mock Receive-Job {}
        Mock Remove-Job {}

        $stopped = Stop-AzureAnalyzerViewer

        $stopped | Should -BeTrue
        $script:AzureAnalyzerViewerState.Job | Should -BeNullOrEmpty
        Should -Invoke Stop-Job -Times 1
        Should -Invoke Remove-Job -Times 1
    }

    It 'Start- and Stop-AzureAnalyzerViewer support ShouldProcess (-WhatIf)' {
        (Get-Command Start-AzureAnalyzerViewer).Parameters.ContainsKey('WhatIf') | Should -BeTrue
        (Get-Command Stop-AzureAnalyzerViewer).Parameters.ContainsKey('WhatIf') | Should -BeTrue
    }
}
