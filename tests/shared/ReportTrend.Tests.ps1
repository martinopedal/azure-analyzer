Describe 'ReportTrend — Resolve-BaselineRun and Get-RunTrend' {
    BeforeAll {
        . (Join-Path $PSScriptRoot '..' '..' 'modules' 'shared' 'ReportDelta.ps1')

        # Helper: build a minimal results.json fixture under a temp-like run dir inside TestDrive.
        function New-RunDir {
            param(
                [string] $Root,
                [string] $RunId,
                [object[]] $Findings,
                [int] $AgeSecs = 0
            )
            $dir = Join-Path $Root $RunId
            $null = New-Item -ItemType Directory -Path $dir -Force
            $jsonPath = Join-Path $dir 'results.json'
            $Findings | ConvertTo-Json -Depth 5 | Set-Content -Path $jsonPath -Encoding UTF8
            if ($AgeSecs -gt 0) {
                (Get-Item $jsonPath).LastWriteTime = (Get-Date).AddSeconds(-$AgeSecs)
            }
            return $dir
        }

        function NewFinding {
            param([string]$Title, [string]$Severity = 'High', [bool]$Compliant = $false)
            [pscustomobject]@{ Title = $Title; Severity = $Severity; Compliant = $Compliant }
        }
    }

    Context 'Resolve-BaselineRun' {

        It 'returns $null when the output root does not exist' {
            $result = Resolve-BaselineRun -OutputRoot 'TestDrive:\nonexistent' -CurrentRunId 'run-001'
            $result | Should -BeNullOrEmpty
        }

        It 'returns $null when only the current run directory exists' {
            $root = Join-Path $TestDrive 'single-run'
            New-RunDir -Root $root -RunId 'run-001' -Findings @(NewFinding 'A') | Out-Null
            $result = Resolve-BaselineRun -OutputRoot $root -CurrentRunId 'run-001'
            $result | Should -BeNullOrEmpty
        }

        It 'excludes the current run directory by exact name' {
            $root = Join-Path $TestDrive 'exclude-test'
            New-RunDir -Root $root -RunId 'run-001' -Findings @(NewFinding 'A') -AgeSecs 120 | Out-Null
            New-RunDir -Root $root -RunId 'run-002' -Findings @(NewFinding 'B') -AgeSecs 60  | Out-Null
            New-RunDir -Root $root -RunId 'run-003' -Findings @(NewFinding 'C') -AgeSecs 0   | Out-Null
            # Treat run-003 as current; should pick run-002 (most recent prior)
            $result = Resolve-BaselineRun -OutputRoot $root -CurrentRunId 'run-003'
            $result | Should -Not -BeNullOrEmpty
            $result | Should -Not -Match 'run-003'
            $result | Should -Match 'run-002'
        }

        It 'returns the most recent prior run when multiple priors exist' {
            $root = Join-Path $TestDrive 'multi-prior'
            New-RunDir -Root $root -RunId 'run-alpha'  -Findings @(NewFinding 'A') -AgeSecs 300 | Out-Null
            New-RunDir -Root $root -RunId 'run-beta'   -Findings @(NewFinding 'B') -AgeSecs 100 | Out-Null
            New-RunDir -Root $root -RunId 'run-gamma'  -Findings @(NewFinding 'C') -AgeSecs 0   | Out-Null
            $result = Resolve-BaselineRun -OutputRoot $root -CurrentRunId 'run-gamma'
            $result | Should -Match 'run-beta'
        }
    }

    Context 'Get-RunTrend' {

        It 'returns an empty array when the output root does not exist' {
            $result = Get-RunTrend -OutputRoot 'TestDrive:\no-such-dir'
            @($result).Count | Should -Be 0
        }

        It 'returns an empty array when no run directories contain results.json' {
            $root = Join-Path $TestDrive 'empty-root'
            $null = New-Item -ItemType Directory -Path $root -Force
            $result = Get-RunTrend -OutputRoot $root
            @($result).Count | Should -Be 0
        }

        It 'returns items ordered oldest to newest (left-to-right for sparkline)' {
            $root = Join-Path $TestDrive 'ordered'
            New-RunDir -Root $root -RunId 'run-old'    -Findings @(NewFinding 'A') -AgeSecs 200 | Out-Null
            New-RunDir -Root $root -RunId 'run-middle' -Findings @(NewFinding 'B') -AgeSecs 100 | Out-Null
            New-RunDir -Root $root -RunId 'run-new'    -Findings @(NewFinding 'C') -AgeSecs 0   | Out-Null
            $result = @(Get-RunTrend -OutputRoot $root)
            $result.Count | Should -Be 3
            $result[0].RunId | Should -Be 'run-old'
            $result[-1].RunId | Should -Be 'run-new'
        }

        It 'respects MaxRuns and returns no more than the specified limit' {
            $root = Join-Path $TestDrive 'max-runs'
            for ($i = 1; $i -le 15; $i++) {
                $findings = @(NewFinding "Finding-$i")
                New-RunDir -Root $root -RunId "run-$('{0:D3}' -f $i)" -Findings $findings -AgeSecs (600 - $i * 30) | Out-Null
            }
            $result = @(Get-RunTrend -OutputRoot $root -MaxRuns 5)
            $result.Count | Should -Be 5
        }

        It 'aggregates NonCompliant and BySeverity correctly from a two-run fixture' {
            $root = Join-Path $TestDrive 'severity-agg'
            # Run A: 1 Critical NC, 2 High NC, 1 Medium compliant
            $findingsA = @(
                NewFinding 'Crit-1'   'Critical' $false
                NewFinding 'High-1'   'High'     $false
                NewFinding 'High-2'   'High'     $false
                NewFinding 'Med-ok'   'Medium'   $true
            )
            # Run B: 1 High NC, 1 Low NC, 1 Info NC
            $findingsB = @(
                NewFinding 'High-B1'  'High'     $false
                NewFinding 'Low-B1'   'Low'      $false
                NewFinding 'Info-B1'  'Info'     $false
            )
            New-RunDir -Root $root -RunId 'run-A' -Findings $findingsA -AgeSecs 120 | Out-Null
            New-RunDir -Root $root -RunId 'run-B' -Findings $findingsB -AgeSecs 0   | Out-Null

            $result = @(Get-RunTrend -OutputRoot $root)
            $result.Count | Should -Be 2

            # Oldest first (run-A)
            $rA = $result[0]
            $rA.RunId        | Should -Be 'run-A'
            $rA.Total        | Should -Be 4
            $rA.NonCompliant | Should -Be 3
            $rA.BySeverity.Critical | Should -Be 1
            $rA.BySeverity.High     | Should -Be 2
            $rA.BySeverity.Medium   | Should -Be 0
            $rA.BySeverity.Low      | Should -Be 0
            $rA.BySeverity.Info     | Should -Be 0

            # Newest (run-B)
            $rB = $result[1]
            $rB.RunId        | Should -Be 'run-B'
            $rB.Total        | Should -Be 3
            $rB.NonCompliant | Should -Be 3
            $rB.BySeverity.High     | Should -Be 1
            $rB.BySeverity.Low      | Should -Be 1
            $rB.BySeverity.Info     | Should -Be 1
            $rB.BySeverity.Critical | Should -Be 0
            $rB.BySeverity.Medium   | Should -Be 0
        }
    }
}
