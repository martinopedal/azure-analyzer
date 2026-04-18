Describe 'ReportDelta' {
    BeforeAll {
        . (Join-Path $PSScriptRoot '..' '..' 'modules' 'shared' 'ReportDelta.ps1')

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

    It 'classifies rows present in both as Unchanged' {
        $a = NewRow -Source 'azqr' -ResourceId '/subscriptions/1/rg/x' -Category 'Storage' -Title 'TLS required'
        $delta = Get-ReportDelta -Current @($a) -Previous @($a)
        $delta.Summary.Unchanged | Should -Be 1
        $delta.Summary.New       | Should -Be 0
        $delta.Summary.Resolved  | Should -Be 0
    }

    It 'flags new findings' {
        $a = NewRow -Source 'azqr' -ResourceId '/subscriptions/1/rg/x' -Category 'Storage' -Title 'TLS required'
        $b = NewRow -Source 'azqr' -ResourceId '/subscriptions/1/rg/y' -Category 'Storage' -Title 'TLS required'
        $delta = Get-ReportDelta -Current @($a, $b) -Previous @($a)
        $delta.Summary.New       | Should -Be 1
        $delta.Summary.Unchanged | Should -Be 1
    }

    It 'flags resolved findings and emits them as synthetic rows' {
        $a = NewRow -Source 'azqr' -ResourceId '/subscriptions/1/rg/x' -Category 'Storage' -Title 'TLS required'
        $b = NewRow -Source 'psrule' -ResourceId '/subscriptions/1/rg/y' -Category 'Compute' -Title 'Managed disk required'
        $delta = Get-ReportDelta -Current @($a) -Previous @($a, $b)
        $delta.Summary.Resolved | Should -Be 1
        $delta.Resolved.Count   | Should -Be 1
        $delta.Resolved[0].Title | Should -Be 'Managed disk required'
    }

    It 'is case-insensitive on ResourceId' {
        $a = NewRow -Source 'azqr' -ResourceId '/subscriptions/1/rg/X' -Category 'Storage' -Title 'TLS required'
        $b = NewRow -Source 'azqr' -ResourceId '/subscriptions/1/rg/x' -Category 'Storage' -Title 'TLS required'
        $delta = Get-ReportDelta -Current @($a) -Previous @($b)
        $delta.Summary.Unchanged | Should -Be 1
    }

    It 'computes NetNonCompliantDelta' {
        $a = NewRow -Source 'azqr' -ResourceId '/subscriptions/1/rg/x' -Category 'Storage' -Title 'TLS required' -Compliant $false
        $b = NewRow -Source 'azqr' -ResourceId '/subscriptions/1/rg/y' -Category 'Storage' -Title 'TLS required' -Compliant $false
        $c = NewRow -Source 'azqr' -ResourceId '/subscriptions/1/rg/z' -Category 'Compute' -Title 'Disk'         -Compliant $true
        $delta = Get-ReportDelta -Current @($a, $c) -Previous @($a, $b)
        # current non-compliant = 1, previous non-compliant = 2 -> net -1
        $delta.Summary.NetNonCompliantDelta | Should -Be -1
    }

    It 'handles empty previous run (first run)' {
        $a = NewRow -Source 'azqr' -ResourceId '/subscriptions/1/rg/x' -Category 'Storage' -Title 'TLS required'
        $delta = Get-ReportDelta -Current @($a) -Previous @()
        $delta.Summary.New       | Should -Be 1
        $delta.Summary.Resolved  | Should -Be 0
        $delta.Summary.Unchanged | Should -Be 0
    }

    It 'falls back to EntityId when ResourceId missing' {
        $a = [pscustomobject]@{ Source = 'maester'; EntityId = 'tenant:abc'; Category = 'IAM'; Title = 'MFA'; Compliant = $false }
        $delta = Get-ReportDelta -Current @($a) -Previous @($a)
        $delta.Summary.Unchanged | Should -Be 1
    }

    Context 'Get-MttrBySeverity' {
        BeforeAll {
            . (Join-Path $PSScriptRoot '..' '..' 'modules' 'shared' 'RunHistory.ps1')

            function NewMttrFinding($Source, $Rid, $Sev) {
                [pscustomobject]@{
                    Source = $Source; ResourceId = $Rid; Category = 'X'
                    Title = "T-$Rid"; Severity = $Sev; Compliant = $false
                }
            }

            function WriteResults($Path, $Rows) {
                $dir = Split-Path $Path -Parent
                if (-not (Test-Path $dir)) { $null = New-Item -ItemType Directory -Path $dir -Force }
                $Rows | ConvertTo-Json -Depth 5 | Set-Content -Path $Path -Encoding UTF8
            }
        }

        It 'returns empty buckets when history has fewer than 2 runs' {
            $rows = Get-MttrBySeverity -History @()
            @($rows).Count | Should -Be 5
            ($rows | Where-Object { $_.Severity -eq 'Critical' }).MedianDays | Should -BeNullOrEmpty
        }

        It 'computes median days per severity from a 3-run history' {
            $tmp = Join-Path $TestDrive 'mttr-3'
            $null = New-Item -ItemType Directory -Path $tmp -Force
            $r = Join-Path $tmp 'results.json'

            # Run 1: A(High), B(Critical)
            WriteResults $r @(
                NewMttrFinding 'azqr' '/x/A' 'High'
                NewMttrFinding 'azqr' '/x/B' 'Critical'
            )
            $null = Save-RunSnapshot -OutputPath $tmp -ResultsPath $r -Timestamp ([datetime]'2025-01-01T00:00:00Z')

            # Run 2 (3 days later): A still there, B resolved (3 days) -> Critical median 3.
            WriteResults $r @(
                NewMttrFinding 'azqr' '/x/A' 'High'
                NewMttrFinding 'azqr' '/x/C' 'High'  # newly seen
            )
            $null = Save-RunSnapshot -OutputPath $tmp -ResultsPath $r -Timestamp ([datetime]'2025-01-04T00:00:00Z')

            # Run 3 (5 days after run 1, 2 days after run 2): A resolved (4 days), C still there.
            WriteResults $r @(
                NewMttrFinding 'azqr' '/x/C' 'High'
            )
            $null = Save-RunSnapshot -OutputPath $tmp -ResultsPath $r -Timestamp ([datetime]'2025-01-05T00:00:00Z')

            $history = @(Get-RunHistory -OutputPath $tmp)
            $mttr    = Get-MttrBySeverity -History $history

            $crit = $mttr | Where-Object { $_.Severity -eq 'Critical' }
            $crit.ResolvedCount | Should -Be 1
            $crit.MedianDays    | Should -Be 3

            $high = $mttr | Where-Object { $_.Severity -eq 'High' }
            $high.ResolvedCount | Should -Be 1
            $high.MedianDays    | Should -Be 4

            $low = $mttr | Where-Object { $_.Severity -eq 'Low' }
            $low.ResolvedCount  | Should -Be 0
            $low.MedianDays     | Should -BeNullOrEmpty
        }
    }
}


Describe 'ReportDelta as input to incremental history (#94)' {
    BeforeAll {
        . (Join-Path $PSScriptRoot '..' '..' 'modules' 'shared' 'ScanState.ps1')

        function NewRow2 {
            param($Source, $ResourceId, $Category, $Title, $Compliant = $false)
            [pscustomobject]@{ Source = $Source; ResourceId = $ResourceId; Category = $Category; Title = $Title; Compliant = $Compliant }
        }
    }

    It 'feeds Get-ReportDelta keys into Update-FindingHistoryFromDelta consistently' {
        $tmpDir = Join-Path ([System.IO.Path]::GetTempPath()) "delta-inc-$([Guid]::NewGuid().ToString('N'))"
        New-Item -ItemType Directory -Path $tmpDir | Out-Null
        try {
            $prev = @( NewRow2 -Source 'azqr' -ResourceId '/s/1' -Category 'Storage' -Title 'TLS' )
            $curr = @(
                NewRow2 -Source 'azqr' -ResourceId '/s/1' -Category 'Storage' -Title 'TLS'
                NewRow2 -Source 'azqr' -ResourceId '/s/2' -Category 'Storage' -Title 'TLS'
            )

            $delta = Get-ReportDelta -Current $curr -Previous $prev
            $delta.Summary.New | Should -Be 1
            $delta.Summary.Unchanged | Should -Be 1

            $state = Read-ScanState -OutputPath $tmpDir
            $state = Update-FindingHistoryFromDelta -State $state -Current $curr
            $state.findings.Count | Should -Be 2

            foreach ($row in $curr) {
                $key = Get-ReportDeltaKey -Row $row
                $state.findings.Contains($key) | Should -BeTrue
            }
        } finally {
            Remove-Item $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
