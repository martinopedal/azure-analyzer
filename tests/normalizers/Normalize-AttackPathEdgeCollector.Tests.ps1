#Requires -Version 7.4

BeforeAll {
    $repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..')
    . (Join-Path $repoRoot 'modules\shared\Sanitize.ps1')
    . (Join-Path $repoRoot 'modules\shared\Canonicalize.ps1')
    . (Join-Path $repoRoot 'modules\shared\Schema.ps1')
    . (Join-Path $repoRoot 'modules\normalizers\Normalize-Zizmor.ps1')
    . (Join-Path $repoRoot 'modules\normalizers\Normalize-Maester.ps1')
    . (Join-Path $repoRoot 'modules\normalizers\Normalize-IaCBicep.ps1')
    . (Join-Path $repoRoot 'modules\normalizers\Normalize-IaCTerraform.ps1')
    . (Join-Path $repoRoot 'modules\normalizers\Normalize-ADOPipelineSecurity.ps1')

    $script:TrackARelations = @('TriggeredBy', 'AuthenticatesAs', 'DeploysTo', 'UsesSecret', 'HasFederatedCredential', 'Declares')
    $script:SampleEdges = @(
        [pscustomobject]@{ Source = 'repo:github.com/contoso/app'; Target = 'workflow:deploy'; Relation = 'TriggeredBy' },
        [pscustomobject]@{ Source = 'workflow:deploy'; Target = 'spn:00000000-0000-0000-0000-000000000001'; Relation = 'AuthenticatesAs' },
        [pscustomobject]@{ Source = 'workflow:deploy'; Target = '/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/rg/providers/Microsoft.Web/sites/app'; Relation = 'DeploysTo' },
        [pscustomobject]@{ Source = 'workflow:deploy'; Target = 'secret:kv://contoso-kv/app-secret'; Relation = 'UsesSecret' },
        [pscustomobject]@{ Source = 'appId:00000000-0000-0000-0000-000000000099'; Target = 'repo:github.com/contoso/app'; Relation = 'HasFederatedCredential' },
        [pscustomobject]@{ Source = 'iac:file://infra/main.bicep'; Target = '/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/rg/providers/Microsoft.Web/sites/app'; Relation = 'Declares' }
    )
}

Describe 'Attack-path EdgeCollector wiring in normalizers' {
    It 'zizmor accepts and emits all six Track A relations' {
        $collector = [System.Collections.Generic.List[psobject]]::new()
        $toolResult = [pscustomobject]@{
            Status   = 'Success'
            Findings = @([pscustomobject]@{
                    Id = 'z1'; Title = 'z'; Compliant = $false; Severity = 'High'; AttackPathEdges = $script:SampleEdges
                })
        }

        $null = Normalize-Zizmor -ToolResult $toolResult -EdgeCollector $collector
        foreach ($relation in $script:TrackARelations) {
            @($collector.Relation) | Should -Contain $relation
        }
    }

    It 'maester accepts and emits Track A edge hints' {
        $collector = [System.Collections.Generic.List[psobject]]::new()
        $toolResult = [pscustomobject]@{
            Status   = 'Success'
            TenantId = '00000000-0000-0000-0000-000000000001'
            Findings = @([pscustomobject]@{
                    Id = 'm1'; Title = 'm'; Compliant = $false; Severity = 'Medium'; AttackPathEdges = @($script:SampleEdges[4], $script:SampleEdges[1])
                })
        }

        $null = Normalize-Maester -ToolResult $toolResult -EdgeCollector $collector
        @($collector.Relation) | Should -Contain 'HasFederatedCredential'
        @($collector.Relation) | Should -Contain 'AuthenticatesAs'
    }

    It 'iac normalizers accept Declares and DeploysTo edge hints' {
        $collector = [System.Collections.Generic.List[psobject]]::new()
        $bicepResult = [pscustomobject]@{
            Status   = 'Success'
            Findings = @([pscustomobject]@{
                    Id = 'b1'; Title = 'b'; Compliant = $false; Severity = 'High'; ResourceId = './infra/main.bicep'; AttackPathEdges = @($script:SampleEdges[2], $script:SampleEdges[5])
                })
        }
        $terraformResult = [pscustomobject]@{
            Status   = 'Success'
            Findings = @([pscustomobject]@{
                    Id = 't1'; Title = 't'; Compliant = $false; Severity = 'High'; ResourceId = './infra/main.tf'; AttackPathEdges = @($script:SampleEdges[2], $script:SampleEdges[5])
                })
        }

        $null = Normalize-IaCBicep -ToolResult $bicepResult -EdgeCollector $collector
        $null = Normalize-IaCTerraform -ToolResult $terraformResult -EdgeCollector $collector
        @($collector.Relation) | Should -Contain 'DeploysTo'
        @($collector.Relation) | Should -Contain 'Declares'
    }

    It 'ado pipeline normalizer accepts TriggeredBy and UsesSecret edge hints' {
        $collector = [System.Collections.Generic.List[psobject]]::new()
        $toolResult = [pscustomobject]@{
            Status   = 'Success'
            Findings = @([pscustomobject]@{
                    Id = 'a1'; Title = 'a'; Category = 'CI'; Compliant = $false; Severity = 'High'
                    Detail = 'd'; Remediation = 'r'; LearnMoreUrl = 'https://example.com'; ResourceId = 'ado://org/project/pipeline/1'
                    AttackPathEdges = @($script:SampleEdges[0], $script:SampleEdges[3])
                })
        }

        $null = Normalize-ADOPipelineSecurity -ToolResult $toolResult -EdgeCollector $collector
        @($collector.Relation) | Should -Contain 'TriggeredBy'
        @($collector.Relation) | Should -Contain 'UsesSecret'
    }
}
