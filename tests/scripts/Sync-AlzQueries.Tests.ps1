#requires -Version 7.0
#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }

Describe 'Sync-AlzQueries' {
    BeforeAll {
        $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
        $script:ScriptPath = Join-Path $script:RepoRoot 'scripts\Sync-AlzQueries.ps1'
        . $script:ScriptPath
    }

    It 'script file exists' {
        Test-Path -LiteralPath $script:ScriptPath | Should -BeTrue
    }

    It 'supports DryRun without writing destination file' {
        $repo = Join-Path $TestDrive 'repo'
        $toolsDir = Join-Path $repo 'tools'
        $queriesDir = Join-Path $repo 'queries'
        $upstream = Join-Path $TestDrive 'upstream'
        $upstreamQueries = Join-Path $upstream 'queries'
        New-Item -ItemType Directory -Path $toolsDir, $queriesDir, $upstreamQueries -Force | Out-Null

        @'
{
  "tools": [
    {
      "name": "alz-queries",
      "upstream": {
        "repo": "martinopedal/alz-graph-queries"
      }
    }
  ]
}
'@ | Set-Content -LiteralPath (Join-Path $toolsDir 'tool-manifest.json') -NoNewline

        '{ "queries": [ { "guid": "a", "queryable": true, "graph": "resources | take 1", "compliant": true } ] }' |
            Set-Content -LiteralPath (Join-Path $upstreamQueries 'alz_additional_queries.json') -NoNewline
        'old-content' | Set-Content -LiteralPath (Join-Path $queriesDir 'alz_additional_queries.json') -NoNewline

        Mock Invoke-RemoteRepoClone { return [PSCustomObject]@{ Path = $upstream; Cleanup = { } } }
        Mock Invoke-WithTimeout { return [PSCustomObject]@{ ExitCode = 0; Output = 'ok' } }

        $result = Invoke-SyncAlzQueries `
            -RepoRootPath $repo `
            -ManifestFilePath (Join-Path $toolsDir 'tool-manifest.json') `
            -SelectedToolName 'alz-queries' `
            -SourceRelativeFilePath 'queries\alz_additional_queries.json' `
            -DestinationPathRelative 'queries\alz_additional_queries.json' `
            -WhatIfDryRun

        $result.Action | Should -Be 'WouldUpdate'
        (Get-Content -LiteralPath (Join-Path $queriesDir 'alz_additional_queries.json') -Raw) | Should -Be 'old-content'
    }

    It 'is idempotent on re-run with unchanged upstream content' {
        $repo = Join-Path $TestDrive 'repo-idem'
        $toolsDir = Join-Path $repo 'tools'
        $queriesDir = Join-Path $repo 'queries'
        $upstream = Join-Path $TestDrive 'upstream-idem'
        $upstreamQueries = Join-Path $upstream 'queries'
        New-Item -ItemType Directory -Path $toolsDir, $queriesDir, $upstreamQueries -Force | Out-Null

        @'
{
  "tools": [
    {
      "name": "alz-queries",
      "upstream": {
        "repo": "martinopedal/alz-graph-queries"
      }
    }
  ]
}
'@ | Set-Content -LiteralPath (Join-Path $toolsDir 'tool-manifest.json') -NoNewline

        '{ "queries": [ { "guid": "b", "queryable": true, "graph": "resources | take 1", "compliant": true } ] }' |
            Set-Content -LiteralPath (Join-Path $upstreamQueries 'alz_additional_queries.json') -NoNewline

        Mock Invoke-RemoteRepoClone { return [PSCustomObject]@{ Path = $upstream; Cleanup = { } } }
        Mock Invoke-WithTimeout { return [PSCustomObject]@{ ExitCode = 0; Output = 'ok' } }

        $first = Invoke-SyncAlzQueries `
            -RepoRootPath $repo `
            -ManifestFilePath (Join-Path $toolsDir 'tool-manifest.json') `
            -SelectedToolName 'alz-queries' `
            -SourceRelativeFilePath 'queries\alz_additional_queries.json' `
            -DestinationPathRelative 'queries\alz_additional_queries.json'

        $second = Invoke-SyncAlzQueries `
            -RepoRootPath $repo `
            -ManifestFilePath (Join-Path $toolsDir 'tool-manifest.json') `
            -SelectedToolName 'alz-queries' `
            -SourceRelativeFilePath 'queries\alz_additional_queries.json' `
            -DestinationPathRelative 'queries\alz_additional_queries.json'

        $first.Action | Should -Be 'Created'
        $second.Action | Should -Be 'NoChange'
    }

    It 'retries transient clone errors and succeeds on later attempt' {
        $repo = Join-Path $TestDrive 'repo-retry'
        $toolsDir = Join-Path $repo 'tools'
        $queriesDir = Join-Path $repo 'queries'
        $upstream = Join-Path $TestDrive 'upstream-retry'
        $upstreamQueries = Join-Path $upstream 'queries'
        New-Item -ItemType Directory -Path $toolsDir, $queriesDir, $upstreamQueries -Force | Out-Null

        @'
{
  "tools": [
    {
      "name": "alz-queries",
      "upstream": {
        "repo": "martinopedal/alz-graph-queries"
      }
    }
  ]
}
'@ | Set-Content -LiteralPath (Join-Path $toolsDir 'tool-manifest.json') -NoNewline

        '{ "queries": [ { "guid": "c", "queryable": true, "graph": "resources | take 1", "compliant": true } ] }' |
            Set-Content -LiteralPath (Join-Path $upstreamQueries 'alz_additional_queries.json') -NoNewline

        $script:cloneAttempts = 0
        Mock Invoke-RemoteRepoClone {
            $script:cloneAttempts++
            if ($script:cloneAttempts -eq 1) {
                throw [System.Exception]::new('timed out contacting upstream')
            }
            return [PSCustomObject]@{ Path = $upstream; Cleanup = { } }
        }
        Mock Invoke-WithTimeout { return [PSCustomObject]@{ ExitCode = 0; Output = 'ok' } }

        $result = Invoke-SyncAlzQueries `
            -RepoRootPath $repo `
            -ManifestFilePath (Join-Path $toolsDir 'tool-manifest.json') `
            -SelectedToolName 'alz-queries' `
            -SourceRelativeFilePath 'queries\alz_additional_queries.json' `
            -DestinationPathRelative 'queries\alz_additional_queries.json'

        $script:cloneAttempts | Should -Be 2
        $result.Action | Should -Be 'Created'
    }

    It 'sanitizes credential-like values in verbose output' {
        $repo = Join-Path $TestDrive 'repo-sanitize'
        $toolsDir = Join-Path $repo 'tools'
        $queriesDir = Join-Path $repo 'queries'
        $upstream = Join-Path $TestDrive 'upstream-sanitize'
        $upstreamQueries = Join-Path $upstream 'queries'
        New-Item -ItemType Directory -Path $toolsDir, $queriesDir, $upstreamQueries -Force | Out-Null

        @'
{
  "tools": [
    {
      "name": "alz-queries",
      "upstream": {
        "repo": "martinopedal/alz-graph-queries"
      }
    }
  ]
}
'@ | Set-Content -LiteralPath (Join-Path $toolsDir 'tool-manifest.json') -NoNewline

        $secretName = 'ghp_123456789012345678901234567890123456'
        '{ "queries": [] }' | Set-Content -LiteralPath (Join-Path $upstreamQueries $secretName) -NoNewline

        Mock Invoke-RemoteRepoClone { return [PSCustomObject]@{ Path = $upstream; Cleanup = { } } }
        Mock Invoke-WithTimeout { return [PSCustomObject]@{ ExitCode = 0; Output = 'ok' } }

        $stream = Invoke-SyncAlzQueries `
            -RepoRootPath $repo `
            -ManifestFilePath (Join-Path $toolsDir 'tool-manifest.json') `
            -SelectedToolName 'alz-queries' `
            -SourceRelativeFilePath ('queries\' + $secretName) `
            -DestinationPathRelative ('queries\' + $secretName) `
            -WhatIfDryRun `
            -Verbose 4>&1

        $verboseMessages = $stream |
            Where-Object { $_ -is [System.Management.Automation.VerboseRecord] } |
            ForEach-Object { $_.Message }

        ($verboseMessages -join "`n") | Should -Not -Match 'ghp_1234567890'
        ($verboseMessages -join "`n") | Should -Match '\[GITHUB-PAT-REDACTED\]'
    }
}
