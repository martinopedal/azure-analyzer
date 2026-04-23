#Requires -Version 7.4
Set-StrictMode -Version Latest

BeforeAll {
    $repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..')
    . (Join-Path $repoRoot 'modules\shared\Policy\AlzMatcher.ps1')

    function New-HNode {
        param(
            [Parameter(Mandatory)] [string] $Name,
            [object[]] $Children = @()
        )
        [pscustomobject]@{
            Name = $Name
            Children = @($Children)
        }
    }

    $canonicalHierarchy = New-HNode 'Root' @(
        (New-HNode 'Platform' @(
            (New-HNode 'Management'),
            (New-HNode 'Connectivity'),
            (New-HNode 'Identity')
        )),
        (New-HNode 'Landing Zones' @(
            (New-HNode 'Corp'),
            (New-HNode 'Online')
        )),
        (New-HNode 'Decommissioned'),
        (New-HNode 'Sandbox')
    )

    $renamedHierarchy = New-HNode 'TenantRoot' @(
        (New-HNode 'Core' @(
            (New-HNode 'Mgmt'),
            (New-HNode 'Network'),
            (New-HNode 'IAM')
        )),
        (New-HNode 'Workloads' @(
            (New-HNode 'Internal'),
            (New-HNode 'External')
        )),
        (New-HNode 'Decom'),
        (New-HNode 'Dev')
    )

    $flatHierarchy = New-HNode 'Root' @(
        (New-HNode 'ProductionSubs'),
        (New-HNode 'DevSubs'),
        (New-HNode 'DataSubs'),
        (New-HNode 'LegacySubs')
    )
}

Describe 'AlzMatcher' -Tag 'policy' {
    Context 'Worked Example A: canonical ALZ tenant' {
        It 'scores >= 0.80 and activates Full' {
            $result = Invoke-AlzHierarchyMatch -TenantHierarchy $canonicalHierarchy -Mode Auto
            $result.Score | Should -BeGreaterOrEqual 0.80
            $result.Decision | Should -Be 'Full'
        }
    }

    Context 'Worked Example B: renamed ALZ tenant' {
        It 'scores in [0.50, 0.79] and activates Partial' {
            $result = Invoke-AlzHierarchyMatch -TenantHierarchy $renamedHierarchy -Mode Auto
            $result.Score | Should -BeGreaterOrEqual 0.50
            $result.Score | Should -BeLessThan 0.80
            $result.Decision | Should -Be 'Partial'
        }
    }

    Context 'Worked Example C: non-ALZ flat tenant' {
        It 'scores < 0.50 and falls back to AzAdvertizer only' {
            $result = Invoke-AlzHierarchyMatch -TenantHierarchy $flatHierarchy -Mode Auto
            $result.Score | Should -BeLessThan 0.50
            $result.Decision | Should -Be 'Fallback'
        }
    }

    Context 'CLI flag -AlzReferenceMode' {
        It 'Off mode skips computation entirely' {
            $result = Invoke-AlzHierarchyMatch -TenantHierarchy $canonicalHierarchy -Mode Off
            $result.Mode | Should -Be 'Off'
            $result.Score | Should -Be $null
            $result.Decision | Should -Be 'Off'
        }

        It 'Force mode activates regardless of score' {
            $result = Invoke-AlzHierarchyMatch -TenantHierarchy $flatHierarchy -Mode Force
            $result.Decision | Should -Be 'Full'
            $result.ForceOverridden | Should -BeTrue
        }
    }

    It 'applies the locked Round 2 weighted score formula' {
        Get-AlzMatchScore -ExactName 0.9 -Structural 1 -Renames 1 -Levenshtein 1 | Should -Be 0.96
    }
}
