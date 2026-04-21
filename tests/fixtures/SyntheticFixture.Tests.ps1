#Requires -Version 7.4

BeforeAll {
    $repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..')
    $scriptPath = Join-Path $repoRoot 'tests\fixtures\Generate-SyntheticFixture.ps1'
    . $scriptPath
}

Describe 'Generate-SyntheticFixture' {
    It 'maps Small Medium Large sizes to expected counts' {
        (Resolve-SyntheticFixtureCount -Size 'Small') | Should -Be 10000
        (Resolve-SyntheticFixtureCount -Size 'Medium') | Should -Be 100000
        (Resolve-SyntheticFixtureCount -Size 'Large') | Should -Be 500000
    }

    It 'is deterministic for the same seed' {
        $d1 = Join-Path $TestDrive 'synthetic-a'
        $d2 = Join-Path $TestDrive 'synthetic-b'
        & $scriptPath -Size Small -OutputDir $d1 -Seed 42
        & $scriptPath -Size Small -OutputDir $d2 -Seed 42

        (Get-FileHash (Join-Path $d1 'findings.json')).Hash | Should -Be (Get-FileHash (Join-Path $d2 'findings.json')).Hash
        (Get-FileHash (Join-Path $d1 'entities.json')).Hash | Should -Be (Get-FileHash (Join-Path $d2 'entities.json')).Hash
        (Get-FileHash (Join-Path $d1 'edges.json')).Hash | Should -Be (Get-FileHash (Join-Path $d2 'edges.json')).Hash
    }

    It 'emits graph-heavy edges with foundation relations' {
        $d = Join-Path $TestDrive 'synthetic-graph'
        & $scriptPath -Size Small -GraphHeavy -OutputDir $d -Seed 7
        $edges = @(Get-Content (Join-Path $d 'edges.json') -Raw | ConvertFrom-Json)
        $edges.Count | Should -BeGreaterThan 0
        (@($edges.Relation) -contains 'TriggeredBy') | Should -BeTrue
        (@($edges.Relation) -contains 'PolicyAssignedTo') | Should -BeTrue
    }
}
