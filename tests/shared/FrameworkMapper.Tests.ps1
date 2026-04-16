Describe 'FrameworkMapper' {
    BeforeAll {
        . (Join-Path $PSScriptRoot '..' '..' 'modules' 'shared' 'Schema.ps1')
        . (Join-Path $PSScriptRoot '..' '..' 'modules' 'shared' 'FrameworkMapper.ps1')
        Clear-FrameworkMappingCache
    }

    It 'loads framework-mappings.json and lists the three frameworks' {
        $map = Get-FrameworkMappings
        $map             | Should -Not -BeNullOrEmpty
        $map.frameworks.CIS.name  | Should -Be 'CIS Azure Foundations'
        $map.frameworks.NIST.name | Should -Be 'NIST 800-53'
        $map.frameworks.PCI.name  | Should -Be 'PCI-DSS'
    }

    It 'maps an azqr Security finding to CIS / NIST / PCI controls' {
        $f = [pscustomobject]@{
            Id = 't1'; Source = 'azqr'; Category = 'Security'; Severity = 'High'
            Compliant = $false; Title = 'test'; RuleId = $null
            Frameworks = @(); Controls = @()
        }
        Add-FrameworkMapping -Finding $f | Out-Null
        $f.Frameworks.Count | Should -BeGreaterThan 0
        ($f.Frameworks | Where-Object { $_.framework -eq 'CIS'  }) | Should -Not -BeNullOrEmpty
        ($f.Frameworks | Where-Object { $_.framework -eq 'NIST' }) | Should -Not -BeNullOrEmpty
        ($f.Frameworks | Where-Object { $_.framework -eq 'PCI'  }) | Should -Not -BeNullOrEmpty
        $f.Controls | Should -Contain 'NIST:AC-2'
    }

    It 'matches PSRule on RuleIdPrefix' {
        $f = [pscustomobject]@{
            Id = 't2'; Source = 'psrule'; Category = 'Security'
            RuleId = 'Azure.KeyVault.SoftDelete'
            Frameworks = @(); Controls = @()
        }
        Add-FrameworkMapping -Finding $f | Out-Null
        $f.Controls | Should -Contain 'CIS:8.1'
        $f.Controls | Should -Contain 'NIST:SC-12'
    }

    It 'leaves unknown (source,category) pairs unmapped' {
        $f = [pscustomobject]@{
            Id = 't3'; Source = 'unknown-tool'; Category = 'XYZ'
            Frameworks = @(); Controls = @()
        }
        Add-FrameworkMapping -Finding $f | Out-Null
        $f.Frameworks.Count | Should -Be 0
    }

    It 'FilterFramework narrows output to a single framework' {
        $f = [pscustomobject]@{
            Id = 't4'; Source = 'azqr'; Category = 'Security'
            Frameworks = @(); Controls = @()
        }
        Add-FrameworkMapping -Finding $f -FilterFramework 'CIS' | Out-Null
        ($f.Frameworks | ForEach-Object { $_.framework } | Sort-Object -Unique) | Should -Be @('CIS')
    }

    It 'Get-FrameworkCoverage returns per-framework stats' {
        $findings = @(
            [pscustomobject]@{ Source = 'azqr'; Category = 'Security'; Frameworks = @(); Controls = @() }
            [pscustomobject]@{ Source = 'scorecard'; Category = 'Branch-Protection'; Frameworks = @(); Controls = @() }
        )
        foreach ($f in $findings) { Add-FrameworkMapping -Finding $f | Out-Null }
        $cov = @(Get-FrameworkCoverage -Findings $findings)
        $cov.Count | Should -BeGreaterThan 0
        ($cov | Where-Object { $_.Framework -eq 'NIST' }).ControlsHit | Should -BeGreaterThan 0
        foreach ($row in $cov) {
            $row.PercentCovered | Should -BeGreaterOrEqual 0
            $row.PercentCovered | Should -BeLessOrEqual 100
            $row.Status | Should -BeIn @('green','yellow','red')
        }
    }
}
