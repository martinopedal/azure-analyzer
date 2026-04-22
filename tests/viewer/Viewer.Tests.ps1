#Requires -Version 7.4
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

BeforeAll {
    $script:Here = Split-Path $PSCommandPath -Parent
    $script:RepoRoot = Resolve-Path (Join-Path $script:Here '..' '..')
    . (Join-Path $script:RepoRoot 'modules' 'shared' 'Viewer.ps1')
}

Describe 'Select-ReportArchitecture' {
    It 'applies 1.25x headroom and picks the expected tier' {
        $result = Select-ReportArchitecture -FindingCount 1600 -EntityCount 600 -EdgeCount 3000
        $result.ProjectedFindings | Should -Be 2000
        $result.ProjectedEntities | Should -Be 750
        $result.ProjectedEdges | Should -Be 3750
        $result.Tier | Should -Be 'Tier1'
    }

    It 'falls through to Tier4 for large datasets' {
        $result = Select-ReportArchitecture -FindingCount 120000 -EntityCount 60000 -EdgeCount 300000
        $result.Tier | Should -Be 'Tier4'
    }

    It 'can derive counts from output files when explicit counts are not passed' {
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

        $result = Select-ReportArchitecture `
            -FindingsPath (Join-Path $outDir 'results.json') `
            -EntitiesPath (Join-Path $outDir 'entities.json')

        $result.Findings | Should -Be 2
        $result.Entities | Should -Be 1
        $result.Edges | Should -Be 3
    }
}

Describe 'viewer security stubs' {
    It 'accepts loopback-only bind address' {
        (Test-LoopbackBind -Address '127.0.0.1') | Should -BeTrue
        (Test-LoopbackBind -Address '0.0.0.0') | Should -BeFalse
    }

    It 'validates host header against loopback and selected port' {
        (Test-HostHeader -HostHeader '127.0.0.1:4280' -Port 4280) | Should -BeTrue
        (Test-HostHeader -HostHeader 'evil.example:4280' -Port 4280) | Should -BeFalse
    }

    It 'validates origin header for same-origin loopback requests' {
        (Test-OriginHeader -Origin 'http://127.0.0.1:4280' -Port 4280) | Should -BeTrue
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

    It 'starts a Pode-backed job and wires /api/health route' {
        Mock Get-Command {
            [pscustomobject]@{ Name = 'Start-PodeServer'; CommandType = 'Function' }
        } -ParameterFilter { $Name -eq 'Start-PodeServer' }
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
        $script:CapturedStartJobScript | Should -Match '/api/health'
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
}
