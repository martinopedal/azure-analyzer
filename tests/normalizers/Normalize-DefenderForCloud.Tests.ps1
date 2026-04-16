#Requires -Version 7.4
Set-StrictMode -Version Latest

BeforeAll {
    $repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..')
    . (Join-Path $repoRoot 'modules\shared\Canonicalize.ps1')
    . (Join-Path $repoRoot 'modules\shared\Schema.ps1')
    . (Join-Path $repoRoot 'modules\normalizers\Normalize-DefenderForCloud.ps1')
}

Describe 'Normalize-DefenderForCloud' {
    BeforeAll {
        $fixture = Get-Content (Join-Path $PSScriptRoot '..\fixtures\defender-for-cloud-output.json') -Raw | ConvertFrom-Json
        $failedFixture = Get-Content (Join-Path $PSScriptRoot '..\fixtures\failed-output.json') -Raw | ConvertFrom-Json
    }

    Context 'v2 finding conversion' {
        BeforeAll {
            $results = Normalize-DefenderForCloud -ToolResult $fixture
        }

        It 'returns non-healthy assessments plus one secure score finding' {
            @($results).Count | Should -Be 3
        }

        It 'maps assessment findings to AzureResource' {
            $assessmentRows = @($results | Where-Object { $_.EntityType -eq 'AzureResource' })
            $assessmentRows.Count | Should -Be 2
            foreach ($row in $assessmentRows) {
                $row.Source | Should -Be 'defender-for-cloud'
                $row.Compliant | Should -BeFalse
                $row.Category | Should -Be 'Defender for Cloud'
            }
        }

        It 'maps secure score to informational Subscription finding' {
            $secureScore = @($results | Where-Object { $_.EntityType -eq 'Subscription' })[0]
            $secureScore | Should -Not -BeNullOrEmpty
            $secureScore.Compliant | Should -BeTrue
            $secureScore.Severity | Should -Be 'Info'
            $secureScore.Detail | Should -Match 'Current secure score: 42 of 60 \(70%\)\.'
        }

        It 'maps severity from Defender severity field' {
            $high = @($results | Where-Object { $_.Title -match 'Virtual machines should encrypt' })[0]
            $medium = @($results | Where-Object { $_.Title -match 'purge protection enabled' })[0]
            $high.Severity | Should -Be 'High'
            $medium.Severity | Should -Be 'Medium'
        }
    }

    Context 'error handling' {
        It 'returns empty array when wrapper status is failed' {
            $results = Normalize-DefenderForCloud -ToolResult $failedFixture
            @($results).Count | Should -Be 0
        }
    }
}
