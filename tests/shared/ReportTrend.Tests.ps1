Describe 'ReportTrend — Add-RunSnapshot, Resolve-BaselineRun, Get-RunTrend' {
    BeforeAll {
        . (Join-Path $PSScriptRoot '..' '..' 'modules' 'shared' 'ReportDelta.ps1')

        function NewFinding {
            param([string]$Title, [string]$Severity = 'High', [bool]$Compliant = $false)
            [pscustomobject]@{ Title = $Title; Severity = $Severity; Compliant = $Compliant }
        }

        function WriteResults {
            param([string]$Path, [object[]]$Findings)
            $dir = Split-Path $Path -Parent
            $null = New-Item -ItemType Directory -Path $dir -Force
            @($Findings) | ConvertTo-Json -Depth 5 | Set-Content -Path $Path -Encoding UTF8
        }
    }

    Context 'Add-RunSnapshot' {

        It 'creates snapshot file and index.json on first call' {
            $root = Join-Path $TestDrive 'snap-first'
            $sd   = Join-Path $root 'snapshots'
            $rf   = Join-Path $root 'results.json'
            WriteResults -Path $rf -Findings @(NewFinding 'A')

            Add-RunSnapshot -SnapshotDir $sd -RunId 'run-001' -SourceFile $rf

            Test-Path (Join-Path $sd 'run-001.json') | Should -BeTrue
            Test-Path (Join-Path $sd 'index.json')   | Should -BeTrue
        }

        It 'index entry contains RunId, Timestamp, and SnapshotFile fields' {
            $root = Join-Path $TestDrive 'snap-fields'
            $sd   = Join-Path $root 'snapshots'
            $rf   = Join-Path $root 'results.json'
            WriteResults -Path $rf -Findings @(NewFinding 'A')

            Add-RunSnapshot -SnapshotDir $sd -RunId 'run-check' -SourceFile $rf

            $idx = @(Get-Content (Join-Path $sd 'index.json') -Raw | ConvertFrom-Json)
            $idx.Count | Should -Be 1
            $idx[0].RunId        | Should -Be 'run-check'
            $idx[0].SnapshotFile | Should -Be 'run-check.json'
            $idx[0].Timestamp    | Should -Not -BeNullOrEmpty
        }

        It 'prunes oldest entry and file when MaxHistory is exceeded' {
            $root = Join-Path $TestDrive 'snap-prune'
            $sd   = Join-Path $root 'snapshots'
            for ($i = 1; $i -le 3; $i++) {
                $rf = Join-Path $root "r$i.json"
                WriteResults -Path $rf -Findings @(NewFinding "F$i")
                Add-RunSnapshot -SnapshotDir $sd -RunId "run-$('{0:D3}' -f $i)" -SourceFile $rf -MaxHistory 2
            }
            $idx = @(Get-Content (Join-Path $sd 'index.json') -Raw | ConvertFrom-Json)
            $idx.Count          | Should -Be 2
            $idx[0].RunId       | Should -Be 'run-002'
            Test-Path (Join-Path $sd 'run-001.json') | Should -BeFalse
        }
    }

    Context 'Resolve-BaselineRun' {

        It 'returns $null when snapshot dir does not exist' {
            Resolve-BaselineRun -SnapshotDir (Join-Path $TestDrive 'no-dir' 'snapshots') |
                Should -BeNullOrEmpty
        }

        It 'returns $null when index.json is absent' {
            $sd = Join-Path $TestDrive 'no-index'
            $null = New-Item -ItemType Directory -Path $sd -Force
            Resolve-BaselineRun -SnapshotDir $sd | Should -BeNullOrEmpty
        }

        It 'returns $null when index is empty (called before first snapshot is added)' {
            $sd = Join-Path $TestDrive 'empty-index'
            $null = New-Item -ItemType Directory -Path $sd -Force
            '[]' | Set-Content (Join-Path $sd 'index.json')
            Resolve-BaselineRun -SnapshotDir $sd | Should -BeNullOrEmpty
        }

        It 'returns the most recent snapshot when called before current run is indexed' {
            $root = Join-Path $TestDrive 'baseline-pick'
            $sd   = Join-Path $root 'snapshots'
            $rf1  = Join-Path $root 'r1.json'
            $rf2  = Join-Path $root 'r2.json'
            WriteResults -Path $rf1 -Findings @(NewFinding 'A')
            WriteResults -Path $rf2 -Findings @(NewFinding 'B')

            Add-RunSnapshot -SnapshotDir $sd -RunId 'run-001' -SourceFile $rf1
            Add-RunSnapshot -SnapshotDir $sd -RunId 'run-002' -SourceFile $rf2

            # Simulate run-003: call before Add-RunSnapshot for this run — should pick run-002
            $result = Resolve-BaselineRun -SnapshotDir $sd
            $result | Should -Not -BeNullOrEmpty
            $result | Should -Match 'run-002'
        }
    }

    Context 'Get-RunTrend' {

        It 'returns empty array when snapshot dir does not exist' {
            @(Get-RunTrend -SnapshotDir (Join-Path $TestDrive 'no-dir2' 'snapshots')).Count |
                Should -Be 0
        }

        It 'returns empty array when index has no entries' {
            $sd = Join-Path $TestDrive 'empty-trend'
            $null = New-Item -ItemType Directory -Path $sd -Force
            '[]' | Set-Content (Join-Path $sd 'index.json')
            @(Get-RunTrend -SnapshotDir $sd).Count | Should -Be 0
        }

        It 'returns items ordered oldest to newest (left-to-right for sparkline)' {
            $root = Join-Path $TestDrive 'trend-order'
            $sd   = Join-Path $root 'snapshots'
            foreach ($id in @('run-A','run-B','run-C')) {
                $rf = Join-Path $root "$id.json"
                WriteResults -Path $rf -Findings @(NewFinding $id)
                Add-RunSnapshot -SnapshotDir $sd -RunId $id -SourceFile $rf
            }
            $result = @(Get-RunTrend -SnapshotDir $sd)
            $result.Count    | Should -Be 3
            $result[0].RunId | Should -Be 'run-A'
            $result[-1].RunId| Should -Be 'run-C'
        }

        It 'respects MaxRuns and returns the most recent N entries oldest-first' {
            $root = Join-Path $TestDrive 'trend-maxruns'
            $sd   = Join-Path $root 'snapshots'
            for ($i = 1; $i -le 5; $i++) {
                $rf = Join-Path $root "r$i.json"
                WriteResults -Path $rf -Findings @(NewFinding "F$i")
                Add-RunSnapshot -SnapshotDir $sd -RunId "run-$('{0:D3}' -f $i)" -SourceFile $rf
            }
            $result = @(Get-RunTrend -SnapshotDir $sd -MaxRuns 3)
            $result.Count    | Should -Be 3
            $result[0].RunId | Should -Be 'run-003'   # oldest of the last 3
            $result[-1].RunId| Should -Be 'run-005'   # newest
        }

        It 'aggregates NonCompliant and BySeverity correctly from a two-run fixture' {
            $root = Join-Path $TestDrive 'trend-sev'
            $sd   = Join-Path $root 'snapshots'
            $rfA  = Join-Path $root 'rA.json'
            $rfB  = Join-Path $root 'rB.json'

            # Run A: 1 Critical NC, 2 High NC, 1 Medium compliant
            WriteResults -Path $rfA -Findings @(
                NewFinding 'Crit-1' 'Critical' $false
                NewFinding 'High-1' 'High'     $false
                NewFinding 'High-2' 'High'     $false
                NewFinding 'Med-ok' 'Medium'   $true
            )
            # Run B: 1 High NC, 1 Low NC, 1 Info NC
            WriteResults -Path $rfB -Findings @(
                NewFinding 'High-B' 'High' $false
                NewFinding 'Low-B'  'Low'  $false
                NewFinding 'Info-B' 'Info' $false
            )
            Add-RunSnapshot -SnapshotDir $sd -RunId 'run-A' -SourceFile $rfA
            Add-RunSnapshot -SnapshotDir $sd -RunId 'run-B' -SourceFile $rfB

            $result = @(Get-RunTrend -SnapshotDir $sd)
            $result.Count | Should -Be 2

            $rA = $result[0]
            $rA.RunId              | Should -Be 'run-A'
            $rA.Total              | Should -Be 4
            $rA.NonCompliant       | Should -Be 3
            $rA.BySeverity.Critical| Should -Be 1
            $rA.BySeverity.High    | Should -Be 2
            $rA.BySeverity.Medium  | Should -Be 0
            $rA.BySeverity.Low     | Should -Be 0
            $rA.BySeverity.Info    | Should -Be 0

            $rB = $result[1]
            $rB.RunId              | Should -Be 'run-B'
            $rB.Total              | Should -Be 3
            $rB.NonCompliant       | Should -Be 3
            $rB.BySeverity.Critical| Should -Be 0
            $rB.BySeverity.High    | Should -Be 1
            $rB.BySeverity.Low     | Should -Be 1
            $rB.BySeverity.Info    | Should -Be 1
        }

        It 'skips entries whose snapshot file is missing (tolerates orphaned index entries)' {
            $root = Join-Path $TestDrive 'trend-ghost'
            $sd   = Join-Path $root 'snapshots'
            $rf   = Join-Path $root 'r1.json'
            WriteResults -Path $rf -Findings @(NewFinding 'Good')
            Add-RunSnapshot -SnapshotDir $sd -RunId 'run-good' -SourceFile $rf

            # Corrupt index to include a ghost entry before the real one
            $idxPath = Join-Path $sd 'index.json'
            @(
                [pscustomobject]@{ RunId='run-ghost'; Timestamp=(Get-Date -Format 'o'); SnapshotFile='ghost.json' }
                [pscustomobject]@{ RunId='run-good';  Timestamp=(Get-Date -Format 'o'); SnapshotFile='run-good.json' }
            ) | ConvertTo-Json -Depth 3 | Set-Content $idxPath

            $result = @(Get-RunTrend -SnapshotDir $sd)
            $result.Count    | Should -Be 1
            $result[0].RunId | Should -Be 'run-good'
        }
    }
}
