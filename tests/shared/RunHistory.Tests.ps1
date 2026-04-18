Describe 'RunHistory' {
    BeforeAll {
        . (Join-Path $PSScriptRoot '..' '..' 'modules' 'shared' 'RunHistory.ps1')

        function NewFinding($Source, $Rid, $Sev, $Compliant = $false) {
            [pscustomobject]@{
                Source     = $Source
                ResourceId = $Rid
                Category   = 'X'
                Title      = "T-$Rid"
                Severity   = $Sev
                Compliant  = $Compliant
            }
        }

        function NewResultsFile($Path, $Rows) {
            $dir = Split-Path $Path -Parent
            if (-not (Test-Path $dir)) { $null = New-Item -ItemType Directory -Path $dir -Force }
            $Rows | ConvertTo-Json -Depth 5 | Set-Content -Path $Path -Encoding UTF8
        }
    }

    Context 'Save-RunSnapshot' {
        It 'creates a stamped directory with results.json + run-meta.json and severity counts' {
            $tmp = Join-Path $TestDrive 'out1'
            $null = New-Item -ItemType Directory -Path $tmp -Force
            $results = Join-Path $tmp 'results.json'
            NewResultsFile -Path $results -Rows @(
                NewFinding 'azqr' '/subscriptions/a/x' 'High'
                NewFinding 'azqr' '/subscriptions/a/y' 'Critical'
                NewFinding 'psrule' '/subscriptions/a/z' 'Low' $true
            )

            # Pass an explicit UTC datetime (Save-RunSnapshot must not double-convert).
            $ts = [datetime]::SpecifyKind([datetime]::new(2025, 1, 15, 10, 30, 0), [System.DateTimeKind]::Utc)
            $snap = Save-RunSnapshot -OutputPath $tmp -ResultsPath $results -Timestamp $ts -Tools @('azqr','psrule') -Subscriptions @('sub-a')

            $snap | Should -Not -BeNullOrEmpty
            $snap.FindingCount | Should -Be 3
            (Test-Path $snap.Path)     | Should -BeTrue
            (Test-Path $snap.MetaPath) | Should -BeTrue
            $snap.Stamp | Should -Be '2025-01-15-103000'

            $meta = Get-Content $snap.MetaPath -Raw | ConvertFrom-Json
            # SeverityCounts is volume over all findings (unchanged in schema 1.1).
            $meta.SeverityCounts.Critical    | Should -Be 1
            $meta.SeverityCounts.High        | Should -Be 1
            $meta.SeverityCounts.Low         | Should -Be 1
            $meta.NonCompliantCount          | Should -Be 2
            # NonCompliantSeverityCounts is the risk-over-time counter - excludes the compliant Low.
            $meta.SchemaVersion                              | Should -Be '1.1'
            $meta.NonCompliantSeverityCounts.Critical        | Should -Be 1
            $meta.NonCompliantSeverityCounts.High            | Should -Be 1
            $meta.NonCompliantSeverityCounts.Low             | Should -Be 0
            $meta.Tools                      | Should -Contain 'azqr'
        }

        It 'returns $null and warns when results file does not exist' {
            $tmp = Join-Path $TestDrive 'out-missing'
            $null = New-Item -ItemType Directory -Path $tmp -Force
            $snap = Save-RunSnapshot -OutputPath $tmp -ResultsPath (Join-Path $tmp 'absent.json') -WarningAction SilentlyContinue
            $snap | Should -BeNullOrEmpty
        }
    }

    Context 'Get-RunHistory' {
        It 'returns an empty array when history dir is missing' {
            $tmp = Join-Path $TestDrive 'out-empty'
            $null = New-Item -ItemType Directory -Path $tmp -Force
            $h = Get-RunHistory -OutputPath $tmp
            @($h).Count | Should -Be 0
        }

        It 'returns runs ordered oldest -> newest' {
            $tmp = Join-Path $TestDrive 'out2'
            $null = New-Item -ItemType Directory -Path $tmp -Force
            $r = Join-Path $tmp 'results.json'
            NewResultsFile -Path $r -Rows @(NewFinding 'azqr' '/x/1' 'High')

            $t1 = [datetime]'2025-01-01T00:00:00Z'
            $t2 = [datetime]'2025-01-02T00:00:00Z'
            $t3 = [datetime]'2025-01-03T00:00:00Z'
            $null = Save-RunSnapshot -OutputPath $tmp -ResultsPath $r -Timestamp $t2
            $null = Save-RunSnapshot -OutputPath $tmp -ResultsPath $r -Timestamp $t1
            $null = Save-RunSnapshot -OutputPath $tmp -ResultsPath $r -Timestamp $t3

            $h = @(Get-RunHistory -OutputPath $tmp)
            $h.Count | Should -Be 3
            $h[0].Stamp | Should -Be '2025-01-01-000000'
            $h[2].Stamp | Should -Be '2025-01-03-000000'
            $h[1].Meta  | Should -Not -BeNullOrEmpty
        }
    }

    Context 'Remove-OldRunSnapshots' {
        It 'prunes oldest snapshots beyond the retention count' {
            $tmp = Join-Path $TestDrive 'out3'
            $null = New-Item -ItemType Directory -Path $tmp -Force
            $r = Join-Path $tmp 'results.json'
            NewResultsFile -Path $r -Rows @(NewFinding 'azqr' '/x/1' 'High')

            for ($i = 1; $i -le 5; $i++) {
                $ts = [datetime]"2025-01-0${i}T00:00:00Z"
                $null = Save-RunSnapshot -OutputPath $tmp -ResultsPath $r -Timestamp $ts
            }
            (Get-RunHistory -OutputPath $tmp).Count | Should -Be 5

            $removed = Remove-OldRunSnapshots -OutputPath $tmp -Retention 2
            @($removed).Count | Should -Be 3
            $kept = @(Get-RunHistory -OutputPath $tmp)
            $kept.Count | Should -Be 2
            $kept[0].Stamp | Should -Be '2025-01-04-000000'
            $kept[1].Stamp | Should -Be '2025-01-05-000000'
        }

        It 'is a no-op when history is at or below retention' {
            $tmp = Join-Path $TestDrive 'out4'
            $null = New-Item -ItemType Directory -Path $tmp -Force
            $r = Join-Path $tmp 'results.json'
            NewResultsFile -Path $r -Rows @(NewFinding 'azqr' '/x/1' 'High')
            $null = Save-RunSnapshot -OutputPath $tmp -ResultsPath $r -Timestamp ([datetime]'2025-01-01T00:00:00Z')
            $removed = Remove-OldRunSnapshots -OutputPath $tmp -Retention 5
            @($removed).Count | Should -Be 0
        }
    }
}
