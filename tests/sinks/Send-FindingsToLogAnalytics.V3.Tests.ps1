#Requires -Version 7.4
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Issue #187 / B3: Send-FindingsToLogAnalytics.ps1::Read-EntitiesFromJson must
# transparently support both v3.0 (bare array) and v3.1 ({SchemaVersion,Entities,Edges})
# entities.json envelopes. Pre-fix, the sink wrapped the v3.1 envelope into a
# 1-element array and downstream `$entity.Observations` operated on the envelope
# instead of the entity list.

BeforeAll {
    $script:RepoRoot = Resolve-Path (Join-Path $PSScriptRoot '..' '..')
    . (Join-Path $script:RepoRoot 'modules' 'shared' 'Sanitize.ps1')
    . (Join-Path $script:RepoRoot 'modules' 'shared' 'Retry.ps1')
    . (Join-Path $script:RepoRoot 'modules' 'sinks' 'Send-FindingsToLogAnalytics.ps1')

    $script:LegacyFixture = Join-Path $script:RepoRoot 'tests' 'fixtures' 'identity-graph' 'entities-v3.0-legacy.json'
    $script:V31Fixture    = Join-Path $script:RepoRoot 'tests' 'fixtures' 'identity-graph' 'entities-v3.1.json'
}

Describe 'Read-EntitiesFromJson — v3.0/v3.1 envelope sniff (#187 B3)' {

    It 'reads v3.0 legacy bare-array fixture into entity objects' {
        $entities = @(Read-EntitiesFromJson -EntitiesJson $script:LegacyFixture)
        $entities.Count | Should -BeGreaterThan 0
        $entities[0].PSObject.Properties.Name | Should -Contain 'EntityId'
        $entities[0].PSObject.Properties.Name | Should -Contain 'EntityType'
        # v3.0 file is a bare array — must NOT have surfaced an envelope-shaped object.
        $entities[0].PSObject.Properties.Name | Should -Not -Contain 'Entities'
    }

    It 'reads v3.1 envelope fixture into entity objects (not envelope wrapper)' {
        $entities = @(Read-EntitiesFromJson -EntitiesJson $script:V31Fixture)
        $entities.Count | Should -BeGreaterThan 0
        # Should be the inner Entities[] array, NOT a 1-element wrapper of the envelope.
        $entities[0].PSObject.Properties.Name | Should -Contain 'EntityId'
        $entities[0].PSObject.Properties.Name | Should -Not -Contain 'SchemaVersion'
        $entities[0].PSObject.Properties.Name | Should -Not -Contain 'Edges'
        # And it must not have wrapped the whole envelope into Element[0].
        @($entities | Where-Object { $_.PSObject.Properties['SchemaVersion'] }).Count | Should -Be 0
    }

    It 'reads an empty v3.1 envelope (no entities) into an empty collection' {
        $tmp = Join-Path $TestDrive 'empty-v31.json'
        '{ "SchemaVersion": "3.1", "Entities": [], "Edges": [] }' | Set-Content -Path $tmp -Encoding UTF8
        $entities = @(Read-EntitiesFromJson -EntitiesJson $tmp)
        $entities.Count | Should -Be 0
    }

    It 'reads an empty v3.0 bare array into an empty collection' {
        $tmp = Join-Path $TestDrive 'empty-v30.json'
        '[]' | Set-Content -Path $tmp -Encoding UTF8
        $entities = @(Read-EntitiesFromJson -EntitiesJson $tmp)
        $entities.Count | Should -Be 0
    }
}
