#Requires -Version 7.4
Set-StrictMode -Version Latest

BeforeAll {
    $repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..')
    . (Join-Path $repoRoot 'modules\shared\Canonicalize.ps1')
    . (Join-Path $repoRoot 'modules\shared\EntityStore.ps1')
    . (Join-Path $repoRoot 'modules\shared\Schema.ps1')
    . (Join-Path $repoRoot 'modules\normalizers\Normalize-Scorecard.ps1')
}

Describe 'Normalize-Scorecard' {
    BeforeAll {
        $fixture = Get-Content (Join-Path $PSScriptRoot '..\fixtures\scorecard-output.json') -Raw | ConvertFrom-Json
        $failedFixture = Get-Content (Join-Path $PSScriptRoot '..\fixtures\failed-output.json') -Raw | ConvertFrom-Json
    }

    Context 'v3 schema conversion' {
        BeforeAll {
            $results = Normalize-Scorecard -ToolResult $fixture
        }

        It 'returns the correct number of findings' {
            @($results).Count | Should -Be 4
        }

        It 'sets SchemaVersion to 2.0' {
            foreach ($r in $results) {
                $r.SchemaVersion | Should -Be '2.2'
            }
        }

        It 'sets Source to scorecard' {
            foreach ($r in $results) {
                $r.Source | Should -Be 'scorecard'
            }
        }

        It 'sets Platform to GitHub' {
            foreach ($r in $results) {
                $r.Platform | Should -Be 'GitHub'
            }
        }

        It 'sets EntityType to Repository' {
            foreach ($r in $results) {
                $r.EntityType | Should -Be 'Repository'
            }
        }
    }

    Context 'CanonicalId normalization' {
        BeforeAll {
            $results = Normalize-Scorecard -ToolResult $fixture
        }

        It 'lowercases EntityId' {
            foreach ($r in $results) {
                $r.EntityId | Should -BeExactly $r.EntityId.ToLowerInvariant()
            }
        }

        It 'has a non-empty EntityId even for empty ResourceId inputs' {
            foreach ($r in $results) {
                $r.EntityId | Should -Not -BeNullOrEmpty
            }
        }
    }

    Context 'category mapping preservation' {
        BeforeAll {
            $results = Normalize-Scorecard -ToolResult $fixture
        }

        It 'preserves per-check scorecard categories from wrapper' {
            @($results.Category | Sort-Object -Unique) | Should -Be @('Code-Review', 'Dependencies', 'SAST')
        }
    }

    Context 'score in Detail' {
        BeforeAll {
            $results = Normalize-Scorecard -ToolResult $fixture
        }

        It 'preserves score information in Detail' {
            $results[0].Detail | Should -Match 'Score \d+/\d+'
        }
    }

    Context 'field preservation' {
        BeforeAll {
            $results = Normalize-Scorecard -ToolResult $fixture
        }

        It 'preserves Compliant boolean correctly' {
            $results[0].Compliant | Should -BeFalse
            $results[1].Compliant | Should -BeTrue
            $results[2].Compliant | Should -BeFalse
            $results[3].Compliant | Should -BeTrue
        }

        It 'maps severity from Score using the locked ladder' {
            $results[0].Severity | Should -Be 'Critical'
            $results[1].Severity | Should -Be 'Info'
            $results[2].Severity | Should -Be 'Medium'
            $results[3].Severity | Should -Be 'Low'
        }

        It 'preserves Title' {
            $results[0].Title | Should -Not -BeNullOrEmpty
        }

        It 'preserves Detail' {
            $results[0].Detail | Should -Not -BeNullOrEmpty
        }

        It 'plumbs Schema 2.2 metadata fields through New-FindingRow' {
            foreach ($r in $results) {
                $r.Pillar | Should -Be 'Security'
                $r.ToolVersion | Should -Match 'v4\.13\.0'
                @($r.Frameworks).Count | Should -BeGreaterThan 0
                @($r.BaselineTags).Count | Should -BeGreaterThan 0
                $r.DeepLinkUrl | Should -Match '^https://github\.com/ossf/scorecard/blob/main/docs/checks\.md#'
            }
        }

        It 'derives EvidenceUris from check details (commit SHAs, file paths, and URLs)' {
            $branch = @($results | Where-Object { $_.Title -eq 'Branch-Protection' })[0]
            $branch.EvidenceUris | Should -Contain 'https://github.com/test-org/test-repo/blob/HEAD/.github/workflows/ci.yml'
            $branch.EvidenceUris | Should -Contain 'https://github.com/test-org/test-repo/commit/1111111'
        }
    }

    Context 'Scorecard has no Azure subscription context' {
        BeforeAll {
            $results = Normalize-Scorecard -ToolResult $fixture
        }

        It 'does not set SubscriptionId for GitHub checks' {
            foreach ($r in $results) {
                $r.SubscriptionId | Should -BeNullOrEmpty
            }
        }

        It 'does not set ResourceGroup for GitHub checks' {
            foreach ($r in $results) {
                $r.ResourceGroup | Should -BeNullOrEmpty
            }
        }
    }

    Context 'error handling' {
        It 'returns empty array for failed tool output' {
            $results = Normalize-Scorecard -ToolResult $failedFixture
            @($results).Count | Should -Be 0
        }

        It 'returns empty array for null Findings' {
            $emptyResult = [PSCustomObject]@{ Source = 'scorecard'; Status = 'Success'; Findings = $null }
            $results = Normalize-Scorecard -ToolResult $emptyResult
            @($results).Count | Should -Be 0
        }

        It 'returns empty array for empty Findings' {
            $emptyResult = [PSCustomObject]@{ Source = 'scorecard'; Status = 'Success'; Findings = @() }
            $results = Normalize-Scorecard -ToolResult $emptyResult
            @($results).Count | Should -Be 0
        }

        It 'handles missing optional fields gracefully' {
            $minimalInput = [PSCustomObject]@{
                Source   = 'scorecard'
                Status   = 'Success'
                Findings = @(
                    [PSCustomObject]@{
                        Source       = 'scorecard'
                        ResourceId   = 'github.com/test-org/test-repo'
                        Category     = 'Supply Chain'
                        Title        = 'Test scorecard check'
                        Compliant    = $false
                        Severity     = 'Medium'
                        Detail       = 'Score 5/10. Test detail'
                        SchemaVersion = '1.0'
                    }
                )
            }
            $results = Normalize-Scorecard -ToolResult $minimalInput
            @($results).Count | Should -Be 1
        }
    }

    Context 'enterprise GitHub host (GHEC-DR / GHES)' {
        It 'canonicalizes GHES repository URL with enterprise host' {
            $ghesInput = [PSCustomObject]@{
                Source   = 'scorecard'
                Status   = 'Success'
                Findings = @(
                    [PSCustomObject]@{
                        Source       = 'scorecard'
                        ResourceId   = 'github.contoso.com/org/repo'
                        Category     = 'Supply Chain'
                        Title        = 'Branch protection check'
                        Compliant    = $false
                        Severity     = 'High'
                        Detail       = 'Score 3/10. Enterprise repo check'
                        SchemaVersion = '1.0'
                    }
                )
            }
            $results = Normalize-Scorecard -ToolResult $ghesInput
            @($results).Count | Should -Be 1
            $results[0].EntityId | Should -BeExactly 'github.contoso.com/org/repo'
        }

        It 'canonicalizes GHEC-DR repository URL' {
            $ghecDrInput = [PSCustomObject]@{
                Source   = 'scorecard'
                Status   = 'Success'
                Findings = @(
                    [PSCustomObject]@{
                        Source       = 'scorecard'
                        ResourceId   = 'github.eu.acme.com/team/project'
                        Category     = 'Supply Chain'
                        Title        = 'Dependency pinning'
                        Compliant    = $true
                        Severity     = 'Info'
                        Detail       = 'Score 10/10. All pinned'
                        SchemaVersion = '1.0'
                    }
                )
            }
            $results = Normalize-Scorecard -ToolResult $ghecDrInput
            @($results).Count | Should -Be 1
            $results[0].EntityId | Should -BeExactly 'github.eu.acme.com/team/project'
        }

        It 'lowercases enterprise EntityId' {
            $upperInput = [PSCustomObject]@{
                Source   = 'scorecard'
                Status   = 'Success'
                Findings = @(
                    [PSCustomObject]@{
                        Source       = 'scorecard'
                        ResourceId   = 'GitHub.Contoso.Com/MyOrg/MyRepo'
                        Category     = 'Supply Chain'
                        Title        = 'Check'
                        Compliant    = $false
                        Severity     = 'Medium'
                        Detail       = 'Score 5/10.'
                        SchemaVersion = '1.0'
                    }
                )
            }
            $results = Normalize-Scorecard -ToolResult $upperInput
            $results[0].EntityId | Should -BeExactly 'github.contoso.com/myorg/myrepo'
        }

        It 'still works with standard github.com ResourceId' {
            $standardInput = [PSCustomObject]@{
                Source   = 'scorecard'
                Status   = 'Success'
                Findings = @(
                    [PSCustomObject]@{
                        Source       = 'scorecard'
                        ResourceId   = 'github.com/martinopedal/azure-analyzer'
                        Category     = 'Supply Chain'
                        Title        = 'Check'
                        Compliant    = $true
                        Severity     = 'Info'
                        Detail       = 'Score 10/10.'
                        SchemaVersion = '1.0'
                    }
                )
            }
            $results = Normalize-Scorecard -ToolResult $standardInput
            $results[0].EntityId | Should -BeExactly 'github.com/martinopedal/azure-analyzer'
        }
    }

    Context 'score-to-severity boundary mapping' {
        It 'maps all score boundaries correctly including errored checks (-1)' {
            $scores = @(-1, 0, 2, 3, 5, 6, 7, 8, 9, 10)
            $testInput = [PSCustomObject]@{
                Source   = 'scorecard'
                Status   = 'Success'
                Findings = @(
                    foreach ($score in $scores) {
                        [PSCustomObject]@{
                            Source       = 'scorecard'
                            ResourceId   = 'github.com/test-org/test-repo'
                            Category     = 'Supply Chain'
                            Title        = "check-$score"
                            CheckName    = "check-$score"
                            Score        = $score
                            Compliant    = $false
                            Severity     = 'Medium'
                            Detail       = "Score $score/10."
                            SchemaVersion = '1.0'
                        }
                    }
                )
            }

            $results = Normalize-Scorecard -ToolResult $testInput
            $expected = @{
                '-1' = 'Info'
                '0'  = 'Critical'
                '2'  = 'Critical'
                '3'  = 'High'
                '5'  = 'High'
                '6'  = 'Medium'
                '7'  = 'Medium'
                '8'  = 'Low'
                '9'  = 'Low'
                '10' = 'Info'
            }

            foreach ($row in $results) {
                $score = [string]$row.Title.Replace('check-', '')
                $row.Severity | Should -Be $expected[$score]
            }
        }
    }

    Context 'repository entity dedup contract' {
        It 'merges duplicate repository entities by EntityId with Merge-UniqueByKey' {
            $firstPass = Normalize-Scorecard -ToolResult $fixture
            $secondPass = Normalize-Scorecard -ToolResult $fixture
            $entityStubs = @(
                foreach ($finding in @($firstPass) + @($secondPass)) {
                    New-EntityStub -CanonicalId $finding.EntityId -EntityType 'Repository' -Platform 'GitHub'
                }
            )

            $mergedEntities = Merge-UniqueByKey -Existing @() -Incoming $entityStubs -KeySelector { param($entity) $entity.EntityId }
            @($mergedEntities).Count | Should -Be 1
        }
    }
}
