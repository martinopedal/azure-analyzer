#Requires -Version 7.4

BeforeAll {
    $script:repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
    $script:generator = Join-Path $script:repoRoot 'tests\fixtures\Generate-SyntheticFixture.ps1'
    $script:phase0Root = Join-Path $script:repoRoot 'tests\fixtures\phase0'
}

Describe 'Generate-SyntheticFixture (#435)' {
    It 'creates the three artefacts and reports counts' {
        $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("phase0-gen-" + [guid]::NewGuid().ToString('N'))
        try {
            $result = & $script:generator -OutputRoot $tmp -Seed 7 -FindingCount 25 -EntityCount 6 -EdgeCount 10
            $result.Counts.Findings | Should -Be 25
            $result.Counts.Entities | Should -Be 6
            $result.Counts.Edges    | Should -Be 10
            Test-Path $result.FindingsPath | Should -BeTrue
            Test-Path $result.EntitiesPath | Should -BeTrue
            Test-Path $result.ManifestPath | Should -BeTrue
        } finally {
            if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
        }
    }

    It 'produces byte-identical output for the same seed' {
        $a = Join-Path ([System.IO.Path]::GetTempPath()) ("phase0-det-a-" + [guid]::NewGuid().ToString('N'))
        $b = Join-Path ([System.IO.Path]::GetTempPath()) ("phase0-det-b-" + [guid]::NewGuid().ToString('N'))
        try {
            & $script:generator -OutputRoot $a -Seed 42 -FindingCount 30 -EntityCount 8 -EdgeCount 12 | Out-Null
            & $script:generator -OutputRoot $b -Seed 42 -FindingCount 30 -EntityCount 8 -EdgeCount 12 | Out-Null
            (Get-FileHash (Join-Path $a 'findings.json')).Hash | Should -Be (Get-FileHash (Join-Path $b 'findings.json')).Hash
            (Get-FileHash (Join-Path $a 'entities.json')).Hash | Should -Be (Get-FileHash (Join-Path $b 'entities.json')).Hash
        } finally {
            foreach ($p in @($a,$b)) {
                if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Recurse -Force -ErrorAction SilentlyContinue }
            }
        }
    }

    It 'produces different output for different seeds' {
        $a = Join-Path ([System.IO.Path]::GetTempPath()) ("phase0-seed-a-" + [guid]::NewGuid().ToString('N'))
        $b = Join-Path ([System.IO.Path]::GetTempPath()) ("phase0-seed-b-" + [guid]::NewGuid().ToString('N'))
        try {
            & $script:generator -OutputRoot $a -Seed 1 -FindingCount 50 -EntityCount 10 -EdgeCount 20 | Out-Null
            & $script:generator -OutputRoot $b -Seed 2 -FindingCount 50 -EntityCount 10 -EdgeCount 20 | Out-Null
            (Get-FileHash (Join-Path $a 'findings.json')).Hash | Should -Not -Be (Get-FileHash (Join-Path $b 'findings.json')).Hash
        } finally {
            foreach ($p in @($a,$b)) {
                if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Recurse -Force -ErrorAction SilentlyContinue }
            }
        }
    }

    It 'rejects negative finding counts' {
        $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("phase0-neg-" + [guid]::NewGuid().ToString('N'))
        { & $script:generator -OutputRoot $tmp -Seed 1 -FindingCount -1 } | Should -Throw
    }

    Context 'committed phase0 fixtures' {
        It 'ships a small fixture that parses cleanly' {
            $small = Join-Path $script:phase0Root 'small'
            Test-Path $small | Should -BeTrue
            $manifest = Get-Content -LiteralPath (Join-Path $small 'manifest.json') -Raw | ConvertFrom-Json
            $manifest.Counts.Findings | Should -BeGreaterThan 0
            $entities = Get-Content -LiteralPath (Join-Path $small 'entities.json') -Raw | ConvertFrom-Json
            $entities.SchemaVersion | Should -Be '3.1'
        }

        It 'ships an edge-heavy fixture for tier-picker stress tests' {
            $eh = Join-Path $script:phase0Root 'edge-heavy'
            Test-Path $eh | Should -BeTrue
            $manifest = Get-Content -LiteralPath (Join-Path $eh 'manifest.json') -Raw | ConvertFrom-Json
            $manifest.Counts.Edges | Should -BeGreaterThan $manifest.Counts.Findings
        }
    }
}
