#Requires -Version 7.4

BeforeAll {
    $repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..')
    . (Join-Path $repoRoot 'modules\shared\Sanitize.ps1')
    . (Join-Path $repoRoot 'modules\shared\Canonicalize.ps1')
    . (Join-Path $repoRoot 'modules\shared\Schema.ps1')
    . (Join-Path $repoRoot 'modules\shared\EntityStore.ps1')
    $script:fixtures = Join-Path $repoRoot 'tests\fixtures\identity-graph'
}

Describe 'EntityStore.AddEdge / GetEdges' {
    BeforeEach {
        $script:tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("estore-edges-" + [guid]::NewGuid().ToString())
        $script:store = [EntityStore]::new(50000, $script:tmp)
    }
    AfterEach {
        if ($script:store) { $script:store.CleanupSpillFiles() }
        if (Test-Path $script:tmp) { Remove-Item $script:tmp -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'adds and returns edges' {
        $e = New-Edge -Source 's1' -Target 't1' -Relation 'GuestOf' -Confidence 'Confirmed' -DiscoveredBy 'test'
        $script:store.AddEdge($e)
        @($script:store.GetEdges()).Count | Should -Be 1
    }

    It 'dedups edges with the same EdgeId' {
        $e1 = New-Edge -Source 's' -Target 't' -Relation 'MemberOf' -Confidence 'Confirmed' -DiscoveredBy 'test'
        $e2 = New-Edge -Source 's' -Target 't' -Relation 'MemberOf' -Confidence 'Likely' -DiscoveredBy 'test'
        $script:store.AddEdge($e1)
        $script:store.AddEdge($e2)
        @($script:store.GetEdges()).Count | Should -Be 1
        # Last-write-wins: confidence should reflect $e2
        @($script:store.GetEdges())[0].Confidence | Should -Be 'Likely'
    }

    It 'throws on null edge' {
        { $script:store.AddEdge($null) } | Should -Throw
    }

    It 'throws on edge with empty EdgeId' {
        $bad = [PSCustomObject]@{ EdgeId = ''; Source = 's'; Target = 't'; Relation = 'MemberOf' }
        { $script:store.AddEdge($bad) } | Should -Throw
    }

    It 'Export-Edges always returns an array (even when empty)' {
        $out = Export-Edges -Store $script:store
        ,$out | Should -BeOfType ([object[]])
        $out.Count | Should -Be 0
    }
}

Describe 'Import-EntitiesFile back-compat' {
    BeforeAll {
        $repoRoot2 = Resolve-Path (Join-Path $PSScriptRoot '..\..')
        $script:fixtures2 = Join-Path $repoRoot2 'tests\fixtures\identity-graph'
    }

    It 'reads the legacy v3.0 bare-array shape and synthesises an empty Edges list' {
        $file = Join-Path $script:fixtures2 'entities-v3.0-legacy.json'
        $loaded = Import-EntitiesFile -Path $file
        $loaded.SchemaVersion | Should -Be '3.0'
        @($loaded.Entities).Count | Should -Be 1
        @($loaded.Edges).Count   | Should -Be 0
    }

    It 'reads the new v3.1 object shape with Edges' {
        $file = Join-Path $script:fixtures2 'entities-v3.1.json'
        $loaded = Import-EntitiesFile -Path $file
        $loaded.SchemaVersion | Should -Be '3.1'
        @($loaded.Entities).Count | Should -Be 1
        @($loaded.Edges).Count    | Should -Be 1
        @($loaded.Edges)[0].Relation | Should -Be 'HasRoleOn'
    }

    It 'persistence round-trip preserves edge content' {
        $tmpFile = Join-Path ([System.IO.Path]::GetTempPath()) ("entities-rt-" + [guid]::NewGuid().ToString() + '.json')
        try {
            $payload = [PSCustomObject]@{
                SchemaVersion = '3.1'
                Entities = @()
                Edges = @(
                    (New-Edge -Source 's' -Target 't' -Relation 'OwnsAppRegistration' -Confidence 'Confirmed' -DiscoveredBy 'rt')
                )
            }
            $payload | ConvertTo-Json -Depth 10 | Set-Content -Path $tmpFile -Encoding UTF8
            $loaded = Import-EntitiesFile -Path $tmpFile
            @($loaded.Edges).Count | Should -Be 1
            @($loaded.Edges)[0].Relation | Should -Be 'OwnsAppRegistration'
        } finally {
            if (Test-Path $tmpFile) { Remove-Item $tmpFile -Force }
        }
    }

    It 'throws when the file is missing' {
        { Import-EntitiesFile -Path 'C:\does\not\exist\entities.json' } | Should -Throw
    }
}
