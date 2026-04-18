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
