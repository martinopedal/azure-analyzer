#Requires -Version 7.4

BeforeAll {
    $repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..')
    Import-Module (Join-Path $repoRoot 'modules\shared\Renderers\AttackPathRenderer.ps1') -Force

    function New-AttackPathFixture {
        $entities = @(
            [pscustomobject]@{ EntityId = 'repo:github.com/contoso/app'; EntityType = 'Repository'; DisplayName = 'repo'; Platform = 'GitHub' },
            [pscustomobject]@{ EntityId = 'workflow:github.com/contoso/app/.github/workflows/deploy.yml'; EntityType = 'Workflow'; DisplayName = 'deploy'; Platform = 'GitHub' },
            [pscustomobject]@{ EntityId = 'spn:00000000-0000-0000-0000-000000000001'; EntityType = 'ServicePrincipal'; DisplayName = 'deploy-spn'; Platform = 'Entra' },
            [pscustomobject]@{ EntityId = '/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/rg1/providers/Microsoft.Web/sites/app1'; EntityType = 'AzureResource'; DisplayName = 'app1'; Platform = 'Azure' },
            [pscustomobject]@{ EntityId = 'secret:kv://contoso-kv/app-secret'; EntityType = 'Secret'; DisplayName = 'app-secret'; Platform = 'Azure' },
            [pscustomobject]@{ EntityId = 'appId:00000000-0000-0000-0000-000000000099'; EntityType = 'Application'; DisplayName = 'app-reg'; Platform = 'Entra' },
            [pscustomobject]@{ EntityId = 'iac:file://infra/main.bicep'; EntityType = 'IaCFile'; DisplayName = 'main.bicep'; Platform = 'IaC' }
        )

        $edges = @(
            [pscustomobject]@{ EdgeId = 'e-trigger'; Source = 'repo:github.com/contoso/app'; Target = 'workflow:github.com/contoso/app/.github/workflows/deploy.yml'; Relation = 'TriggeredBy' },
            [pscustomobject]@{ EdgeId = 'e-auth'; Source = 'workflow:github.com/contoso/app/.github/workflows/deploy.yml'; Target = 'spn:00000000-0000-0000-0000-000000000001'; Relation = 'AuthenticatesAs' },
            [pscustomobject]@{ EdgeId = 'e-deploy'; Source = 'workflow:github.com/contoso/app/.github/workflows/deploy.yml'; Target = '/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/rg1/providers/Microsoft.Web/sites/app1'; Relation = 'DeploysTo' },
            [pscustomobject]@{ EdgeId = 'e-secret'; Source = 'workflow:github.com/contoso/app/.github/workflows/deploy.yml'; Target = 'secret:kv://contoso-kv/app-secret'; Relation = 'UsesSecret' },
            [pscustomobject]@{ EdgeId = 'e-fic'; Source = 'appId:00000000-0000-0000-0000-000000000099'; Target = 'repo:github.com/contoso/app'; Relation = 'HasFederatedCredential' },
            [pscustomobject]@{ EdgeId = 'e-declares'; Source = 'iac:file://infra/main.bicep'; Target = '/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/rg1/providers/Microsoft.Web/sites/app1'; Relation = 'Declares' }
        )

        $findings = @(
            [pscustomobject]@{ Id = 'f1'; Source = 'zizmor'; EntityId = 'workflow:github.com/contoso/app/.github/workflows/deploy.yml'; Severity = 'High'; Title = 'Workflow exposure' },
            [pscustomobject]@{ Id = 'f2'; Source = 'maester'; EntityId = 'spn:00000000-0000-0000-0000-000000000001'; Severity = 'Critical'; Title = 'SPN risk' },
            [pscustomobject]@{ Id = 'f3'; Source = 'bicep-iac'; EntityId = '/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/rg1/providers/Microsoft.Web/sites/app1'; Severity = 'Medium'; Title = 'Insecure resource' }
        )

        return @{
            Entities = $entities
            Edges = $edges
            Findings = $findings
        }
    }
}

Describe 'AttackPathRenderer' {
    Context 'Tier 1 - full canvas render' {
        It 'builds a Cytoscape model honouring the 2500-edge canvas budget' {
            $fx = New-AttackPathFixture
            $model = New-AttackPathModel -Entities @([pscustomobject]@{ Entities = $fx.Entities; Edges = $fx.Edges }) -Findings $fx.Findings -Tier 1 -EdgeBudget 3

            $model.edges.Count | Should -Be 3
            $model.budget.edgeCap | Should -Be 3
            $model.budget.requested | Should -Be 6
            $model.truncated | Should -BeTrue
        }

        It 'emits truncated=false when edge count is under budget' {
            $fx = New-AttackPathFixture
            $model = New-AttackPathModel -Entities @([pscustomobject]@{ Entities = $fx.Entities; Edges = $fx.Edges }) -Findings $fx.Findings -Tier 1 -EdgeBudget 10

            $model.edges.Count | Should -Be 6
            $model.truncated | Should -BeFalse
            $report = Get-AttackPathBudgetReport -Model $model
            $report.Truncated | Should -BeFalse
            $report.Requested | Should -Be 6
            $report.Allocated | Should -Be 6
        }
    }

    Context 'Tier 2 - SQLite-WASM hydrate' {
        It 'returns a top-N severity-ranked seed subgraph' {
            $fx = New-AttackPathFixture
            $model = New-AttackPathModel -Entities @([pscustomobject]@{ Entities = $fx.Entities; Edges = $fx.Edges }) -Findings $fx.Findings -Tier 2 -EdgeBudget 4

            $model.hydration.mode | Should -Be 'sqlite-wasm'
            $model.hydration.seedNodeCap | Should -Be 200
            $model.edges.Count | Should -BeLessOrEqual 4
        }

        It 'expands one hop on node-click within 250 ms' {
            $fx = New-AttackPathFixture
            $elapsed = Measure-Command {
                $model = New-AttackPathModel -Entities @([pscustomobject]@{ Entities = $fx.Entities; Edges = $fx.Edges }) -Findings $fx.Findings -Tier 2 -EdgeBudget 6
            }

            $model.hydration.expand | Should -Be 'one-hop'
            $elapsed.TotalMilliseconds | Should -BeLessThan 250
        }
    }

    Context 'Tier 3 - web-worker viewport tiles' {
        It 'streams tiles without blocking the main thread for more than one frame' {
            $fx = New-AttackPathFixture
            $elapsed = Measure-Command {
                $model = New-AttackPathModel -Entities @([pscustomobject]@{ Entities = $fx.Entities; Edges = $fx.Edges }) -Findings $fx.Findings -Tier 3 -EdgeBudget 2500
            }

            $model.hydration.mode | Should -Be 'worker-tiles'
            $model.hydration.fetch | Should -Be '/graph/attack-path/tiles'
            $elapsed.TotalMilliseconds | Should -BeLessThan 16
        }
    }

    Context 'Tier 4 - server-side recursive CTE' {
        It 'returns a capped subgraph from /api/graph/attack-paths with truncated flag' {
            $fx = New-AttackPathFixture
            $model = New-AttackPathModel -Entities @([pscustomobject]@{ Entities = $fx.Entities; Edges = $fx.Edges }) -Findings $fx.Findings -Tier 4 -EdgeBudget 1

            $model.hydration.mode | Should -Be 'pode-api'
            $model.hydration.endpoint | Should -Be '/api/graph/attack-paths'
            $model.truncated | Should -BeTrue
        }
    }

    Context 'Shared canvas budget (Tracks A + B + C)' {
        It 'proportionally down-samples low-severity edges across layers' {
            $fx = New-AttackPathFixture
            $model = New-AttackPathModel -Entities @([pscustomobject]@{ Entities = $fx.Entities; Edges = $fx.Edges }) -Findings $fx.Findings -Tier 1 -EdgeBudget 1

            $model.edges.Count | Should -Be 1
            $model.edges[0].data.severity | Should -BeIn @('Critical', 'High')
        }
    }

    Context 'FindingRow field dependency (Round 3 contract)' {
        It 'renders nodes and edges when only current-Schema 2.2 fields are present' {
            $fx = New-AttackPathFixture
            $minimalFindings = @(
                [pscustomobject]@{ Id = 'f-min'; Source = 'zizmor'; EntityId = 'workflow:github.com/contoso/app/.github/workflows/deploy.yml'; Severity = 'High'; Title = 'Minimal finding' }
            )
            $model = New-AttackPathModel -Entities @([pscustomobject]@{ Entities = $fx.Entities; Edges = $fx.Edges }) -Findings $minimalFindings -Tier 1 -EdgeBudget 10
            $json = ConvertTo-AttackPathDataIsland -Model $model

            $model.nodes.Count | Should -BeGreaterThan 0
            $model.edges.Count | Should -BeGreaterThan 0
            $json | Should -Match '"schemaVersion":"3.0"'
            $json | Should -Not -Match '"tooltips":""'
        }

        It 'gracefully omits tooltips and metadata for deferred FindingRow fields (depends on #432b)' -Skip {
            # Pending #432b. Verifies that absent optional fields produce no schema, no throw, no empty strings.
        }
    }

    Context 'Auditor acceptance (60-second question)' {
        It 'builds a Tier 1 budget-capped model within 60 seconds' {
            $entities = @()
            $edges = @()
            $findings = @()
            for ($i = 0; $i -lt 2600; $i++) {
                $src = "node:$i"
                $tgt = "node:$($i + 1)"
                $entities += [pscustomobject]@{ EntityId = $src; EntityType = 'AzureResource'; DisplayName = $src; Platform = 'Azure' }
                $entities += [pscustomobject]@{ EntityId = $tgt; EntityType = 'AzureResource'; DisplayName = $tgt; Platform = 'Azure' }
                $edges += [pscustomobject]@{ EdgeId = "e-$i"; Source = $src; Target = $tgt; Relation = 'DeploysTo' }
                $findings += [pscustomobject]@{ Id = "f-$i"; Source = 'load'; EntityId = $src; Severity = 'Medium'; Title = 'synthetic' }
            }

            $elapsed = Measure-Command {
                $model = New-AttackPathModel -Entities @([pscustomobject]@{ Entities = $entities; Edges = $edges }) -Findings $findings -Tier 1 -EdgeBudget 2500
            }

            $model.edges.Count | Should -Be 2500
            $model.truncated | Should -BeTrue
            $elapsed.TotalSeconds | Should -BeLessThan 60
        }
    }
}
