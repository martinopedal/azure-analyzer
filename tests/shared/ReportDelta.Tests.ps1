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
