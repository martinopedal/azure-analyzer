Set-StrictMode -Version Latest

BeforeAll {
    . "$PSScriptRoot\..\..\modules\shared\ReportDelta.ps1"
    . "$PSScriptRoot\..\..\modules\shared\ScanState.ps1"

    function NewRow {
        param($Source, $ResourceId, $Category, $Title, $Compliant = $false)
        [pscustomobject]@{
            Source     = $Source
            ResourceId = $ResourceId
            Category   = $Category
            Title      = $Title
            Compliant  = $Compliant
        }
    }
}

Describe 'Get-ScanStatePath' {
    BeforeAll {
        $script:outDir = Join-Path ([System.IO.Path]::GetTempPath()) "scanstate-path-$([Guid]::NewGuid().ToString('N'))"
        New-Item -ItemType Directory -Path $script:outDir | Out-Null
    }
    AfterAll {
        if (Test-Path $script:outDir) { Remove-Item $script:outDir -Recurse -Force }
    }

    It 'resolves the canonical scan-state.json path under the state subfolder' {
        $p = Get-ScanStatePath -OutputPath $script:outDir
        $p | Should -Match 'state'
        Split-Path $p -Leaf | Should -Be 'scan-state.json'
    }

    It 'rejects file names that contain a path separator' {
        { Get-ScanStatePath -OutputPath $script:outDir -FileName '..\evil.json' } | Should -Throw
        { Get-ScanStatePath -OutputPath $script:outDir -FileName 'sub/file.json' } | Should -Throw
    }
}

Describe 'Read-ScanState / Write-ScanState' {
    BeforeAll {
        $script:outDir = Join-Path ([System.IO.Path]::GetTempPath()) "scanstate-rw-$([Guid]::NewGuid().ToString('N'))"
        New-Item -ItemType Directory -Path $script:outDir | Out-Null
    }
    AfterAll {
        if (Test-Path $script:outDir) { Remove-Item $script:outDir -Recurse -Force }
    }

    It 'returns a fresh state when no file exists' {
        $state = Read-ScanState -OutputPath $script:outDir
        $state.schemaVersion | Should -Be 1
        $state.tools.Count | Should -Be 0
        $state.findings.Count | Should -Be 0
    }

    It 'persists and reloads with all top-level keys' {
        $state = Read-ScanState -OutputPath $script:outDir
        $state = Update-ScanStateRun -State $state -RunMode 'Incremental'
        $state = Update-ScanStateToolEntry -State $state -Tool 'azqr' -Status 'Success' -RunMode 'Incremental' -FindingCount 7
        $path = Write-ScanState -OutputPath $script:outDir -State $state
        Test-Path $path | Should -BeTrue

        $reloaded = Read-ScanState -OutputPath $script:outDir
        $reloaded.runs.lastRunMode | Should -Be 'Incremental'
        $entry = Get-ScanStateToolEntry -State $reloaded -Tool 'azqr'
        $entry.status | Should -Be 'Success'
        $entry.findingCount | Should -Be 7
        $entry.runMode | Should -Be 'Incremental'
        $entry.lastSuccessUtc | Should -Not -BeNullOrEmpty
    }

    It 'rebuilds when state file is corrupt' {
        $stateFile = Get-ScanStatePath -OutputPath $script:outDir
        Set-Content -Path $stateFile -Value '{ this is not json' -Encoding utf8
        $warnings = @()
        $reloaded = Read-ScanState -OutputPath $script:outDir `
            -WarningVariable warnings -WarningAction SilentlyContinue
        $reloaded.schemaVersion | Should -Be 1
        # Promote intentional warning to asserted behavior (no log noise).
        ($warnings -join "`n") | Should -Match 'corrupt or unreadable'
    }
}

Describe 'Resolve-IncrementalSince' {
    BeforeAll {
        $script:outDir = Join-Path ([System.IO.Path]::GetTempPath()) "scanstate-since-$([Guid]::NewGuid().ToString('N'))"
        New-Item -ItemType Directory -Path $script:outDir | Out-Null
    }
    AfterAll {
        if (Test-Path $script:outDir) { Remove-Item $script:outDir -Recurse -Force }
    }

    It 'returns null when -Incremental is off and no override is provided' {
        $state = Read-ScanState -OutputPath $script:outDir
        Resolve-IncrementalSince -State $state -Tool 'azqr' | Should -BeNullOrEmpty
    }

    It 'returns the explicit override when supplied (operator wins)' {
        $state = Read-ScanState -OutputPath $script:outDir
        $override = [datetime]::Parse('2026-01-01T00:00:00Z').ToUniversalTime()
        $resolved = Resolve-IncrementalSince -State $state -Tool 'azqr' -Override $override
        $resolved | Should -Not -BeNullOrEmpty
        $resolved.Year | Should -Be 2026
    }

    It 'falls back to the tool''s previous lastSuccessUtc under -Incremental' {
        $state = Read-ScanState -OutputPath $script:outDir
        $past = [datetime]::Parse('2025-06-15T12:00:00Z').ToUniversalTime()
        $state = Update-ScanStateToolEntry -State $state -Tool 'azqr' -Status 'Success' -RunMode 'Full' -FindingCount 3 -Now $past
        $resolved = Resolve-IncrementalSince -State $state -Tool 'azqr' -Incremental
        $resolved | Should -Not -BeNullOrEmpty
        $resolved.Year | Should -Be 2025
    }
}

Describe 'Update-FindingHistoryFromDelta' {
    BeforeAll {
        $script:outDir = Join-Path ([System.IO.Path]::GetTempPath()) "scanstate-hist-$([Guid]::NewGuid().ToString('N'))"
        New-Item -ItemType Directory -Path $script:outDir | Out-Null
    }
    AfterAll {
        if (Test-Path $script:outDir) { Remove-Item $script:outDir -Recurse -Force }
    }

    It 'stamps FirstSeenUtc on first sighting and updates LastSeenUtc on re-sighting' {
        $state = Read-ScanState -OutputPath $script:outDir
        $row = NewRow -Source 'azqr' -ResourceId '/subs/1/rg/x' -Category 'Storage' -Title 'TLS required'

        $first  = [datetime]::Parse('2026-04-01T00:00:00Z').ToUniversalTime()
        $second = [datetime]::Parse('2026-04-10T00:00:00Z').ToUniversalTime()

        $state = Update-FindingHistoryFromDelta -State $state -Current @($row) -Now $first
        $key = Get-ReportDeltaKey -Row $row
        $state.findings[$key].FirstSeenUtc | Should -Match '2026-04-01'
        $state.findings[$key].LastSeenUtc  | Should -Match '2026-04-01'

        $state = Update-FindingHistoryFromDelta -State $state -Current @($row) -Now $second
        $state.findings[$key].FirstSeenUtc | Should -Match '2026-04-01'
        $state.findings[$key].LastSeenUtc  | Should -Match '2026-04-10'
    }

    It 'keeps prior history entries that are not in the current run (resolved is trendable)' {
        $state = Read-ScanState -OutputPath $script:outDir
        $r1 = NewRow -Source 'azqr' -ResourceId '/subs/1/rg/x' -Category 'Storage' -Title 'TLS required'
        $r2 = NewRow -Source 'azqr' -ResourceId '/subs/1/rg/y' -Category 'Storage' -Title 'TLS required'

        $state = Update-FindingHistoryFromDelta -State $state -Current @($r1, $r2)
        $state = Update-FindingHistoryFromDelta -State $state -Current @($r1)

        $state.findings.Count | Should -Be 2
    }
}

Describe 'Update-ScanStateToolEntry watermark semantics (#94 R1)' {
    BeforeAll {
        $script:outDir = Join-Path ([System.IO.Path]::GetTempPath()) "scanstate-watermark-$([Guid]::NewGuid().ToString('N'))"
        New-Item -ItemType Directory -Path $script:outDir | Out-Null
    }
    AfterAll {
        if (Test-Path $script:outDir) { Remove-Item $script:outDir -Recurse -Force }
    }

    It 'Partial status does NOT advance lastSuccessUtc' {
        $state = Read-ScanState -OutputPath $script:outDir
        $past = [datetime]::Parse('2025-06-01T00:00:00Z').ToUniversalTime()
        $state = Update-ScanStateToolEntry -State $state -Tool 'azqr' -Status 'Success' -RunMode 'Full' -FindingCount 5 -Now $past
        $afterSuccess = (Get-ScanStateToolEntry -State $state -Tool 'azqr').lastSuccessUtc

        $later = [datetime]::Parse('2025-09-01T00:00:00Z').ToUniversalTime()
        $state = Update-ScanStateToolEntry -State $state -Tool 'azqr' -Status 'Partial' -RunMode 'FullFallback' -FindingCount 1 -Now $later
        $afterPartial = (Get-ScanStateToolEntry -State $state -Tool 'azqr').lastSuccessUtc

        $afterPartial | Should -Be $afterSuccess
        (Get-ScanStateToolEntry -State $state -Tool 'azqr').status | Should -Be 'Partial'
    }

    It 'Partial on a never-succeeded tool leaves lastSuccessUtc null' {
        $state = Read-ScanState -OutputPath $script:outDir
        $now = [datetime]::Parse('2025-10-01T00:00:00Z').ToUniversalTime()
        $state = Update-ScanStateToolEntry -State $state -Tool 'brand-new-tool' -Status 'Partial' -RunMode 'FullFallback' -FindingCount 0 -Now $now
        $entry = Get-ScanStateToolEntry -State $state -Tool 'brand-new-tool'
        $entry.lastSuccessUtc | Should -BeNullOrEmpty
    }
}

Describe 'Update-ScanStateRun' {
    BeforeAll {
        $script:outDir = Join-Path ([System.IO.Path]::GetTempPath()) "scanstate-run-$([Guid]::NewGuid().ToString('N'))"
        New-Item -ItemType Directory -Path $script:outDir | Out-Null
    }
    AfterAll {
        if (Test-Path $script:outDir) { Remove-Item $script:outDir -Recurse -Force }
    }

    It 'sets baseline timestamp on first run and refreshes only when requested' {
        $state = Read-ScanState -OutputPath $script:outDir
        $t1 = [datetime]::Parse('2026-04-01T00:00:00Z').ToUniversalTime()
        $t2 = [datetime]::Parse('2026-04-02T00:00:00Z').ToUniversalTime()
        $t3 = [datetime]::Parse('2026-04-03T00:00:00Z').ToUniversalTime()

        $state = Update-ScanStateRun -State $state -RunMode 'Full' -Now $t1
        $state.runs.lastBaselineUtc | Should -Match '2026-04-01'

        $state = Update-ScanStateRun -State $state -RunMode 'Incremental' -Now $t2
        $state.runs.lastBaselineUtc | Should -Match '2026-04-01'

        $state = Update-ScanStateRun -State $state -RunMode 'Full' -Now $t3 -UpdateBaseline
        $state.runs.lastBaselineUtc | Should -Match '2026-04-03'
    }
}
