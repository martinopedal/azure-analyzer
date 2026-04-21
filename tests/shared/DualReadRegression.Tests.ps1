#Requires -Version 7.4

BeforeAll {
    $repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..')
    . (Join-Path $repoRoot 'modules\shared\EntityStore.ps1')
    $script:htmlScript = Join-Path $repoRoot 'New-HtmlReport.ps1'
}

Describe 'Dual-read regression for legacy payloads' {
    It 'reads v3.0 entities bare array shape with missing new fields' {
        $entitiesPath = Join-Path $TestDrive 'entities.json'
        @(
            [pscustomobject]@{
                EntityId = 'subscription:aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'
                EntityType = 'Subscription'
                Platform = 'Azure'
            }
        ) | ConvertTo-Json -Depth 10 | Set-Content -Path $entitiesPath -Encoding UTF8

        $loaded = Import-EntitiesFile -Path $entitiesPath
        $loaded.SchemaVersion | Should -Be '3.0'
        @($loaded.Entities).Count | Should -Be 1
        @($loaded.Edges).Count | Should -Be 0
    }

    It 'renders report from v2 results with missing additive fields' {
        $dir = Join-Path $TestDrive 'legacy-results'
        $null = New-Item -ItemType Directory -Path $dir -Force
        @(
            [pscustomobject]@{
                Id='legacy-1'; Source='azqr'; Title='legacy finding'; Severity='High'; Compliant=$false
                EntityId='/subscriptions/aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee/resourcegroups/rg/providers/microsoft.storage/storageaccounts/sa'
                EntityType='AzureResource'; Platform='Azure'; SchemaVersion='2.0'
            }
        ) | ConvertTo-Json -Depth 10 | Set-Content -Path (Join-Path $dir 'results.json') -Encoding UTF8

        { & $script:htmlScript -InputPath (Join-Path $dir 'results.json') -OutputPath (Join-Path $dir 'report.html') | Out-Null } | Should -Not -Throw
        Test-Path (Join-Path $dir 'report.html') | Should -BeTrue
    }
}
