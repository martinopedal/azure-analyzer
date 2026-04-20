Describe 'Normalize-AksRightsizing' {
    BeforeAll {
        . (Join-Path $PSScriptRoot '..' '..' 'modules' 'normalizers' 'Normalize-AksRightsizing.ps1')
        $script:Fixture = Get-Content (Join-Path $PSScriptRoot '..' 'fixtures' 'aks-rightsizing' 'wrapper-output.json') -Raw | ConvertFrom-Json
        $script:KqlOver = Get-Content (Join-Path $PSScriptRoot '..' 'fixtures' 'aks-rightsizing' 'kql-over-provisioned.json') -Raw | ConvertFrom-Json
        $script:KqlUnder = Get-Content (Join-Path $PSScriptRoot '..' 'fixtures' 'aks-rightsizing' 'kql-under-provisioned.json') -Raw | ConvertFrom-Json
        $script:KqlHpa = Get-Content (Join-Path $PSScriptRoot '..' 'fixtures' 'aks-rightsizing' 'kql-missing-hpa.json') -Raw | ConvertFrom-Json
        $script:KqlOom = Get-Content (Join-Path $PSScriptRoot '..' 'fixtures' 'aks-rightsizing' 'kql-oomkilled.json') -Raw | ConvertFrom-Json
    }

    It 'returns empty array when status is not successful' {
        $rows = @(Normalize-AksRightsizing -ToolResult ([pscustomobject]@{ Status = 'Skipped'; Findings = @() }))
        $rows.Count | Should -Be 0
    }

    It 'normalizes every fixture finding to AzureResource rows' {
        $rows = @(Normalize-AksRightsizing -ToolResult $script:Fixture)
        $rows.Count | Should -Be 4
        foreach ($row in $rows) {
            $row.EntityType | Should -Be 'AzureResource'
            $row.Platform | Should -Be 'Azure'
            $row.Source | Should -Be 'aks-rightsizing'
            $row.Category | Should -Be 'Performance'
        }
    }

    It 'preserves severity ladder for all categories' {
        $rows = @(Normalize-AksRightsizing -ToolResult $script:Fixture)
        ($rows | Where-Object { $_.FindingCategory -eq 'OverProvisionedCpu' }).Severity | Should -Be 'Medium'
        ($rows | Where-Object { $_.FindingCategory -eq 'UnderProvisionedMemory' }).Severity | Should -Be 'High'
        ($rows | Where-Object { $_.FindingCategory -eq 'MissingHpa' }).Severity | Should -Be 'Info'
        ($rows | Where-Object { $_.FindingCategory -eq 'OomKilled' }).Severity | Should -Be 'High'
    }

    It 'produces canonical lowercase entity IDs and extracts scope fields' {
        $rows = @(Normalize-AksRightsizing -ToolResult $script:Fixture)
        foreach ($row in $rows) {
            $row.EntityId | Should -Be $row.EntityId.ToLowerInvariant()
            $row.SubscriptionId | Should -Be '11111111-1111-1111-1111-111111111111'
            $row.ResourceGroup | Should -Be 'rg-aks'
        }
    }

    It 'contains representative KQL fixture rows for each category' {
        $script:KqlOver.Results.Count | Should -Be 1
        $script:KqlUnder.Results.Count | Should -Be 1
        $script:KqlHpa.Results.Count | Should -Be 1
        $script:KqlOom.Results.Count | Should -Be 1
    }
}
