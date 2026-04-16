Describe 'Normalize-DefenderForCloud' {
    BeforeAll {
        . (Join-Path $PSScriptRoot '..' '..' 'modules' 'normalizers' 'Normalize-DefenderForCloud.ps1')
        $script:Fixture = Get-Content (Join-Path $PSScriptRoot '..' 'fixtures' 'defender-for-cloud-output.json') -Raw | ConvertFrom-Json
    }

    It 'returns empty array when Status is not Success' {
        $r = @(Normalize-DefenderForCloud -ToolResult ([pscustomobject]@{ Status = 'Skipped'; Findings = @() }))
        $r.Count | Should -Be 0
    }

    It 'emits findings split between Subscription (score + subscription-scoped assessment) and AzureResource' {
        $rows = @(Normalize-DefenderForCloud -ToolResult $script:Fixture)
        $rows.Count | Should -Be 3
        ($rows | Where-Object { $_.EntityType -eq 'Subscription' }).Count  | Should -Be 2
        ($rows | Where-Object { $_.EntityType -eq 'AzureResource' }).Count | Should -Be 1
    }

    It 'Secure Score surfaces as Severity=Info / Compliant=true with score fields attached' {
        $rows = @(Normalize-DefenderForCloud -ToolResult $script:Fixture)
        $score = $rows | Where-Object { $_.Title -like '*Secure Score*' }
        $score.Severity  | Should -Be 'Info'
        $score.Compliant | Should -BeTrue
        $score.ScoreCurrent | Should -Be 42
        $score.ScoreMax     | Should -Be 60
        $score.ScorePercent | Should -Be 70
    }

    It 'MFA assessment is High + Compliant=false + on subscription scope' {
        $rows = @(Normalize-DefenderForCloud -ToolResult $script:Fixture)
        $mfa = $rows | Where-Object { $_.Title -like '*MFA*' }
        $mfa.Severity  | Should -Be 'High'
        $mfa.Compliant | Should -BeFalse
        $mfa.EntityType | Should -Be 'Subscription'
        $mfa.Category  | Should -Be 'SecurityPosture'
    }

    It 'Storage assessment folds onto canonical AzureResource with SubscriptionId + ResourceGroup' {
        $rows = @(Normalize-DefenderForCloud -ToolResult $script:Fixture)
        $stor = $rows | Where-Object { $_.Title -like '*storage*' }
        $stor.EntityType     | Should -Be 'AzureResource'
        $stor.Severity       | Should -Be 'Medium'
        $stor.SubscriptionId | Should -Be '11111111-1111-1111-1111-111111111111'
        $stor.ResourceGroup  | Should -Be 'prod'
        $stor.Remediation    | Should -Match 'supportsHttpsTrafficOnly'
    }

    It 'every row has Source=defender-for-cloud and Platform=Azure' {
        $rows = @(Normalize-DefenderForCloud -ToolResult $script:Fixture)
        foreach ($r in $rows) {
            $r.Source   | Should -Be 'defender-for-cloud'
            $r.Platform | Should -Be 'Azure'
        }
    }
}
