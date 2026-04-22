#Requires -Version 7.4

BeforeAll {
    $repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..')
    . (Join-Path $repoRoot 'modules\shared\Sanitize.ps1')
    . (Join-Path $repoRoot 'modules\shared\Canonicalize.ps1')
    . (Join-Path $repoRoot 'modules\shared\Schema.ps1')
    . (Join-Path $repoRoot 'modules\shared\EntityStore.ps1')
}

Describe 'entities.json dual-read compatibility' {
    It 'reads legacy v3.0 bare-array payload' {
        $path = Join-Path $TestDrive 'entities-v3.0.json'
        @(
            [pscustomobject]@{
                EntityId = 'subscription:aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'
                EntityType = 'Subscription'
                Platform = 'Azure'
            }
        ) | ConvertTo-Json -Depth 8 | Set-Content -Path $path -Encoding UTF8

        $loaded = Import-EntitiesFile -Path $path
        $loaded.SchemaVersion | Should -Be '3.0'
        @($loaded.Entities).Count | Should -Be 1
        @($loaded.Edges).Count | Should -Be 0
    }

    It 'reads v3.1 envelope payload with edges' {
        $path = Join-Path $TestDrive 'entities-v3.1.json'
        [pscustomobject]@{
            SchemaVersion = '3.1'
            Entities = @(
                [pscustomobject]@{
                    EntityId = 'tenant:aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'
                    EntityType = 'Tenant'
                    Platform = 'Entra'
                }
            )
            Edges = @(
                [pscustomobject]@{
                    EdgeId = 'edge:a|MemberOf|b'
                    Source = 'a'
                    Target = 'b'
                    Relation = 'MemberOf'
                }
            )
        } | ConvertTo-Json -Depth 8 | Set-Content -Path $path -Encoding UTF8

        $loaded = Import-EntitiesFile -Path $path
        $loaded.SchemaVersion | Should -Be '3.1'
        @($loaded.Entities).Count | Should -Be 1
        @($loaded.Edges).Count | Should -Be 1
    }
}
