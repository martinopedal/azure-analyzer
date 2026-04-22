#Requires -Version 7.4
<#
.SYNOPSIS
    End-to-end harness for Invoke-AzureAnalyzer.
.DESCRIPTION
    Drives the analyzer's output pipeline end-to-end across three surfaces
    (Azure subscription, GitHub repo, Tenant / management group) plus a
    multi-axis tier-selection matrix, without hitting real Azure / Graph /
    GitHub. Az, Graph, and git clone dependencies are pinned via Pester Mock.

    Schema invariants asserted on every surface:
      * results.json is valid JSON (v1-compat FindingRow array)
      * entities.json uses v3.1 shape { SchemaVersion, Entities, Edges }
      * HTML and Markdown reports render without PS errors
      * Credential scrubbing removes planted secrets from every artifact

    Mirrors Invoke-AzureAnalyzer.ps1:1328-1362 via the Invoke-E2EPipeline
    helper in _E2EHelpers.ps1.
.NOTES
    Directive: .squad/decisions/inbox/copilot-directive-e2e-test-2026-04-23T00-50-00Z.md
#>
Set-StrictMode -Version Latest

BeforeDiscovery {
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
}

BeforeAll {
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
    $env:AZURE_ANALYZER_SUPPRESS_TOOL_MISSING_WARNINGS = '1'

    Get-Module AzureAnalyzer -ErrorAction SilentlyContinue | Remove-Module -Force -ErrorAction SilentlyContinue
    Import-Module (Join-Path $script:RepoRoot 'AzureAnalyzer.psd1') -Force

    # Also dot-source the shared modules into THIS (test) scope so Pester It
    # blocks can call internal helpers (Remove-Credentials, New-FindingRow,
    # Select-ReportArchitecture, ConvertTo-CanonicalEntityId, Test-RemoteRepoUrl,
    # EntityStore class, etc.) the same way the orchestrator does.
    $sharedDir = Join-Path $script:RepoRoot 'modules\shared'
    foreach ($sharedScript in (Get-ChildItem -Path $sharedDir -Filter '*.ps1' -File)) {
        . $sharedScript.FullName
    }

    . (Join-Path $PSScriptRoot '_E2EHelpers.ps1')

    $script:FixtureDir = Join-Path $PSScriptRoot 'fixtures'
    $script:ArgSmall   = Get-Content (Join-Path $script:FixtureDir 'arg-subscription-small.json') -Raw | ConvertFrom-Json
    $script:GhListing  = Get-Content (Join-Path $script:FixtureDir 'github-repo-listing.json')    -Raw | ConvertFrom-Json
    $script:MgTree     = Get-Content (Join-Path $script:FixtureDir 'mgmt-group-tree.json')        -Raw | ConvertFrom-Json

    $script:PlantedLiterals = @(
        'ghp_FAKE1234567890abcdef1234567890abcdef',
        'xoxb-FAKE-111111111111-222222222222-abcdefghijklmnopqrstuvwx',
        'AKIAFAKE000000000000',
        'pat-FAKE-abcd-1234-efgh-5678-ijkl-9012-mnop'
    )

    # Helper to walk the MG tree and collect subscriptions.
    function Get-AllSubscriptions {
        param ($Node, [System.Collections.Generic.List[object]] $Acc)
        if ($Node.PSObject.Properties['subscriptions']) {
            foreach ($s in $Node.subscriptions) { $Acc.Add($s) }
        }
        if ($Node.PSObject.Properties['children']) {
            foreach ($c in $Node.children) { Get-AllSubscriptions -Node $c -Acc $Acc }
        }
    }
    $script:GetAllSubscriptions = ${function:Get-AllSubscriptions}
}

Describe 'E2E: Invoke-AzureAnalyzer' {

    Context 'Azure subscription surface (mocked ARG)' {
        BeforeAll {
            foreach ($cmd in @('Search-AzGraph','Connect-AzAccount','Get-AzSubscription','Get-AzContext')) {
                if (Get-Command $cmd -ErrorAction SilentlyContinue) {
                    Mock -CommandName $cmd -MockWith { @() }
                }
            }

            $script:AzOut = Join-Path $TestDrive 'azure'
            $subscriptionId = $script:ArgSmall.subscriptionId

            $findings = foreach ($raw in $script:ArgSmall.findings) {
                $canonicalResId = ConvertTo-CanonicalArmId -ArmId $raw.resourceId
                New-E2EFinding `
                    -RuleId $raw.ruleId `
                    -Title  $raw.title `
                    -Source 'e2e-arg' `
                    -EntityId $canonicalResId `
                    -EntityType 'AzureResource' `
                    -Compliant ([bool]$raw.compliant) `
                    -Severity $raw.severity `
                    -Category $(if ($raw.PSObject.Properties['category']) { $raw.category } else { '' }) `
                    -Detail $(if ($raw.PSObject.Properties['detail']) { $raw.detail } else { '' }) `
                    -Remediation $(if ($raw.PSObject.Properties['remediation']) { $raw.remediation } else { '' }) `
                    -ResourceId $canonicalResId `
                    -LearnMoreUrl $(if ($raw.PSObject.Properties['learnMoreUrl']) { $raw.learnMoreUrl } else { '' }) `
                    -Platform 'Azure' `
                    -SubscriptionId $subscriptionId `
                    -ResourceGroup $(if ($raw.PSObject.Properties['resourceGroup']) { $raw.resourceGroup } else { '' }) `
                    -Pillar $(if ($raw.PSObject.Properties['pillar']) { $raw.pillar } else { '' })
            }
            $script:AzResult = Invoke-E2EPipeline -Findings @($findings) -OutputPath $script:AzOut
        }

        It 'produces results.json with a schema version (v1-compatible findings)' {
            Test-Path $script:AzResult.ResultsFile | Should -BeTrue
            $parsed = Get-Content $script:AzResult.ResultsFile -Raw | ConvertFrom-Json
            @($parsed).Count | Should -BeGreaterOrEqual 10
            ($parsed | Select-Object -First 1).PSObject.Properties.Name | Should -Contain 'SchemaVersion'
        }

        It 'produces entities.json with v3.1 envelope' {
            Test-Path $script:AzResult.EntitiesFile | Should -BeTrue
            $parsed = Get-Content $script:AzResult.EntitiesFile -Raw | ConvertFrom-Json
            $parsed.SchemaVersion | Should -Match '^3\.'
            $parsed.PSObject.Properties.Name | Should -Contain 'Entities'
            $parsed.PSObject.Properties.Name | Should -Contain 'Edges'
            @($parsed.Entities).Count | Should -BeGreaterThan 0
        }

        It 'HTML report renders for small fixture (Tier 1 PureJson)' {
            Test-Path $script:AzResult.HtmlFile | Should -BeTrue
            (Get-Item $script:AzResult.HtmlFile).Length | Should -BeGreaterThan 1024
            $html = Get-Content $script:AzResult.HtmlFile -Raw
            $html | Should -Match '<!DOCTYPE html>'
        }

        It 'MD report renders for small fixture' {
            Test-Path $script:AzResult.MdFile | Should -BeTrue
            (Get-Item $script:AzResult.MdFile).Length | Should -BeGreaterThan 128
        }

        It 'scrubs planted ghp_*/xoxb-*/AKIA*/pat-* from all outputs' {
            Assert-NoPlantedSecrets `
                -Files @($script:AzResult.ResultsFile, $script:AzResult.EntitiesFile, $script:AzResult.HtmlFile, $script:AzResult.MdFile) `
                -PlantedLiterals $script:PlantedLiterals
        }
    }

    Context 'GitHub repo surface (-RepoUrl, mocked clone)' {
        BeforeAll {
            # Invoke-RemoteRepoClone lives in the AzureAnalyzer module scope
            # (dot-sourced from modules/shared/RemoteClone.ps1). We do NOT
            # mock it across the whole suite because the "respects host
            # allow-list" and "scrubs token from .git/config" tests exercise
            # the real implementation. The fixture-driven pipeline does not
            # need a mocked clone.

            $script:GhOut = Join-Path $TestDrive 'github'
            $findings = foreach ($repo in $script:GhListing.repos) {
                $repoEntityId = ConvertTo-CanonicalRepoId -RepoId ("github.com/" + $repo.slug)
                foreach ($f in $repo.findings) {
                    New-E2EFinding `
                        -RuleId $f.ruleId `
                        -Title  $f.title `
                        -Source 'e2e-github' `
                        -EntityId $repoEntityId `
                        -EntityType 'Repository' `
                        -Compliant ([bool]$f.compliant) `
                        -Severity $f.severity `
                        -Category $(if ($f.PSObject.Properties['category']) { $f.category } else { '' }) `
                        -Detail $(if ($f.PSObject.Properties['detail']) { $f.detail } else { '' }) `
                        -Platform 'GitHub'
                }
            }
            $script:GhResult = Invoke-E2EPipeline -Findings @($findings) -OutputPath $script:GhOut
        }

        It 'scans a mock repo and emits findings for each repo slug' {
            $parsed = Get-Content $script:GhResult.ResultsFile -Raw | ConvertFrom-Json
            @($parsed).Count | Should -BeGreaterOrEqual 4
            ($parsed.Source | Select-Object -Unique) | Should -Contain 'e2e-github'
        }

        It 'respects host allow-list (Invoke-RemoteRepoClone rejects example.com)' {
            $warnings = $null
            $res = Invoke-RemoteRepoClone -RepoUrl 'https://example.com/fake/repo.git' -WarningVariable warnings -WarningAction SilentlyContinue
            $res | Should -BeNullOrEmpty
            ($warnings -join ' ') | Should -Match 'disallowed host|Refusing to clone'
        }

        It 'scrubs token from a planted .git/config fixture (Remove-Credentials)' {
            $fakeRepo = Join-Path $TestDrive 'fake-clone'
            $null = New-Item -ItemType Directory -Path (Join-Path $fakeRepo '.git') -Force
            $configPath = Join-Path $fakeRepo '.git/config'
            $planted = @'
[remote "origin"]
    url = https://x-access-token:ghp_FAKE1234567890abcdef1234567890abcdef@github.com/contoso-fake/app-alpha.git
'@
            Set-Content -Path $configPath -Value $planted -Encoding UTF8
            $raw = Get-Content $configPath -Raw
            $raw | Should -Match 'ghp_FAKE1234567890abcdef1234567890abcdef'
            $scrubbed = Remove-Credentials $raw
            $scrubbed | Should -Not -Match 'ghp_FAKE1234567890abcdef1234567890abcdef'
            $scrubbed | Should -Match '\[GITHUB-PAT-REDACTED\]'
        }

        It 'produces valid v3 entities.json with Repository entities' {
            $parsed = Get-Content $script:GhResult.EntitiesFile -Raw | ConvertFrom-Json
            $parsed.SchemaVersion | Should -Match '^3\.'
            $repos = @($parsed.Entities | Where-Object { $_.EntityType -eq 'Repository' })
            $repos.Count | Should -BeGreaterOrEqual 3
        }

        It 'HTML report includes GitHub findings' {
            Test-Path $script:GhResult.HtmlFile | Should -BeTrue
            $html = Get-Content $script:GhResult.HtmlFile -Raw
            $html | Should -Match 'contoso-fake'
        }
    }

    Context 'Tenant / Management Group surface (mocked)' {
        BeforeAll {
            foreach ($cmd in @('Get-AzManagementGroup','Get-MgDirectoryRole')) {
                if (Get-Command $cmd -ErrorAction SilentlyContinue) {
                    Mock -CommandName $cmd -MockWith { @() }
                }
            }

            $script:TenantOut = Join-Path $TestDrive 'tenant'
            $tenantId         = $script:MgTree.tenantId

            $findings = [System.Collections.Generic.List[object]]::new()

            # Tenant-scoped finding
            $tenantCanonical = (ConvertTo-CanonicalEntityId -RawId $tenantId -EntityType 'Tenant').CanonicalId
            $findings.Add((New-E2EFinding `
                -RuleId 'MT.Tenant.Defender' `
                -Title 'Defender for Identity plan missing at tenant' `
                -Source 'e2e-maester' `
                -EntityId $tenantCanonical `
                -EntityType 'Tenant' `
                -Compliant $false `
                -Severity 'High' `
                -Category 'Identity' `
                -Platform 'Entra'))

            # Subscription-scoped findings across the tree
            $allSubs = [System.Collections.Generic.List[object]]::new()
            & $script:GetAllSubscriptions $script:MgTree.root $allSubs
            foreach ($sub in $allSubs) {
                $subCanonical = (ConvertTo-CanonicalEntityId -RawId $sub.id -EntityType 'Subscription').CanonicalId
                $findings.Add((New-E2EFinding `
                    -RuleId 'Azure.Policy.Assignment' `
                    -Title ("Policy baseline not assigned on " + $sub.displayName) `
                    -Source 'e2e-policy' `
                    -EntityId $subCanonical `
                    -EntityType 'Subscription' `
                    -Compliant $false `
                    -Severity 'Medium' `
                    -Category 'Governance' `
                    -Platform 'Azure' `
                    -SubscriptionId $sub.id))
            }

            # Management group entity represented as a finding
            $mgCanonical = (ConvertTo-CanonicalEntityId -RawId "/providers/Microsoft.Management/managementGroups/$($script:MgTree.root.id)" -EntityType 'ManagementGroup').CanonicalId
            $findings.Add((New-E2EFinding `
                -RuleId 'Azure.MG.RootAssignment' `
                -Title 'Tenant root management group lacks a policy assignment' `
                -Source 'e2e-policy' `
                -EntityId $mgCanonical `
                -EntityType 'ManagementGroup' `
                -Compliant $false `
                -Severity 'High' `
                -Platform 'Azure'))

            $script:TenantResult = Invoke-E2EPipeline -Findings @($findings) -OutputPath $script:TenantOut
        }

        It 'enumerates tenant with Tenant entity type' {
            $parsed = Get-Content $script:TenantResult.EntitiesFile -Raw | ConvertFrom-Json
            $tenants = @($parsed.Entities | Where-Object { $_.EntityType -eq 'Tenant' })
            $tenants.Count | Should -BeGreaterOrEqual 1
        }

        It 'enumerates management group tree' {
            $parsed = Get-Content $script:TenantResult.EntitiesFile -Raw | ConvertFrom-Json
            $mgs = @($parsed.Entities | Where-Object { $_.EntityType -eq 'ManagementGroup' })
            $mgs.Count | Should -BeGreaterOrEqual 1
        }

        It 'produces results.json spanning multiple subscriptions' {
            $parsed = Get-Content $script:TenantResult.ResultsFile -Raw | ConvertFrom-Json
            $subs = @($parsed | Where-Object { $_.SubscriptionId } | Select-Object -ExpandProperty SubscriptionId -Unique)
            $subs.Count | Should -BeGreaterOrEqual 4
        }

        It 'canonicalizes entity IDs (tenant:{guid}, ARM resource IDs lowercased)' {
            $tenantId = $script:MgTree.tenantId
            $tenantCanon = ConvertTo-CanonicalEntityId -RawId $tenantId -EntityType 'Tenant'
            $tenantCanon.CanonicalId | Should -Match '^tenant:[0-9a-f]{8}-'

            $armCanon = ConvertTo-CanonicalEntityId `
                -RawId '/Subscriptions/00000000-0000-0000-0000-000000000002/ResourceGroups/RG-MIXED/providers/Microsoft.Storage/storageAccounts/stMixed' `
                -EntityType 'AzureResource'
            $armCanon.CanonicalId | Should -Match '^/subscriptions/'
            # Case must be fully lowered (compare against invariant-lowercase).
            $armCanon.CanonicalId | Should -BeExactly ($armCanon.CanonicalId.ToLowerInvariant())
        }

        It 'credential scrub applies to tenant surface output' {
            Assert-NoPlantedSecrets `
                -Files @($script:TenantResult.ResultsFile, $script:TenantResult.EntitiesFile, $script:TenantResult.HtmlFile, $script:TenantResult.MdFile) `
                -PlantedLiterals $script:PlantedLiterals
        }
    }

    Context 'Tier selection (multi-axis Select-ReportArchitecture)' {

        It 'selects Tier 1 (PureJson) for small dataset (10 findings)' {
            $selection = Select-ReportArchitecture -FindingCount 10 -EntityCount 5 -EdgeCount 0
            $selection.Tier | Should -Be 'PureJson'
        }

        It 'selects Tier 2 (EmbeddedSqlite) for 10k findings' {
            $selection = Select-ReportArchitecture -FindingCount 10000 -EntityCount 0 -EdgeCount 0 -HeadroomFactor 1.0
            $selection.Tier | Should -Be 'EmbeddedSqlite'
        }

        It 'selects Tier 3 (SidecarSqlite) for 100k findings' {
            $selection = Select-ReportArchitecture -FindingCount 100000 -EntityCount 0 -EdgeCount 0 -HeadroomFactor 1.0
            $selection.Tier | Should -Be 'SidecarSqlite'
        }
    }

    Context 'Cross-cutting invariants' {

        It 'Remove-Credentials redacts ghp_/xoxb-/JWT/OpenAI planted strings' {
            $planted = (Get-Content (Join-Path $PSScriptRoot 'fixtures/planted-secrets.txt') -Raw)
            $scrubbed = Remove-Credentials $planted
            $scrubbed | Should -Not -Match 'ghp_FAKE1234567890abcdef1234567890abcdef'
            $scrubbed | Should -Not -Match 'xoxb-FAKE-111111111111'
            $scrubbed | Should -Not -Match 'sk-FAKEabcdefghijklmnopqrstuvwxyz'
            $scrubbed | Should -Not -Match 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9\.'
        }

        It 'Test-RemoteRepoUrl enforces HTTPS-only and the host allow-list' {
            Test-RemoteRepoUrl -Url 'https://github.com/org/repo.git'            | Should -BeTrue
            Test-RemoteRepoUrl -Url 'https://dev.azure.com/org/proj/_git/repo'   | Should -BeTrue
            Test-RemoteRepoUrl -Url 'https://contoso.ghe.com/org/repo.git'       | Should -BeTrue
            Test-RemoteRepoUrl -Url 'http://github.com/org/repo.git'             | Should -BeFalse
            Test-RemoteRepoUrl -Url 'ssh://github.com/org/repo.git'              | Should -BeFalse
            Test-RemoteRepoUrl -Url 'https://example.com/org/repo.git'           | Should -BeFalse
        }
    }
}

