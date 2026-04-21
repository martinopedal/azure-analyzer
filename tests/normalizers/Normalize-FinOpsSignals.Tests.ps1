#Requires -Version 7.4
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

BeforeAll {
    $repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..')
    . (Join-Path $repoRoot 'modules\shared\Canonicalize.ps1')
    . (Join-Path $repoRoot 'modules\shared\Schema.ps1')
    . (Join-Path $repoRoot 'modules\normalizers\Normalize-FinOpsSignals.ps1')

    $script:FixtureDisk = Get-Content (Join-Path $PSScriptRoot '..\fixtures\finops\finops-output-unattached-disk.json') -Raw | ConvertFrom-Json
    $script:FixtureVm = Get-Content (Join-Path $PSScriptRoot '..\fixtures\finops\finops-output-stopped-vm.json') -Raw | ConvertFrom-Json
    $script:FixturePip = Get-Content (Join-Path $PSScriptRoot '..\fixtures\finops\finops-output-unused-pip.json') -Raw | ConvertFrom-Json
    $script:FixtureMixed = Get-Content (Join-Path $PSScriptRoot '..\fixtures\finops\finops-output-mixed.json') -Raw | ConvertFrom-Json
    $script:FixtureSnapshot = Get-Content (Join-Path $PSScriptRoot '..\fixtures\finops\finops-output-ungoverned-snapshot.json') -Raw | ConvertFrom-Json
    $script:FixtureAppServiceCpu = Get-Content (Join-Path $PSScriptRoot '..\fixtures\finops-app-service-cpu.json') -Raw | ConvertFrom-Json
}

Describe 'Normalize-FinOpsSignals' {
    It 'returns empty array for non-success status' {
        $rows = @(Normalize-FinOpsSignals -ToolResult ([pscustomobject]@{ Status = 'Failed'; Findings = @() }))
        $rows.Count | Should -Be 0
    }

    It 'normalizes unattached disk fixture to AzureResource finding' {
        $rows = @(Normalize-FinOpsSignals -ToolResult $script:FixtureDisk)
        $rows.Count | Should -Be 1
        $rows[0].Source | Should -Be 'finops'
        $rows[0].EntityType | Should -Be 'AzureResource'
        $rows[0].Platform | Should -Be 'Azure'
        $rows[0].Compliant | Should -BeFalse
        $rows[0].Pillar | Should -Be 'Cost Optimization'
        $rows[0].Impact | Should -Be 'Low'
        $rows[0].Effort | Should -Be 'Low'
        $rows[0].DeepLinkUrl | Should -Match 'portal\.azure\.com'
        @($rows[0].EvidenceUris).Count | Should -BeGreaterThan 1
        @($rows[0].RemediationSnippets | Where-Object { $_.language -eq 'bash' }).Count | Should -Be 1
        @($rows[0].EntityRefs).Count | Should -Be 2
        $rows[0].PSObject.Properties['ToolVersion'] | Should -Not -BeNullOrEmpty
    }

    It 'canonicalizes ARM IDs for VM and Public IP fixtures' {
        $vmRows = @(Normalize-FinOpsSignals -ToolResult $script:FixtureVm)
        $pipRows = @(Normalize-FinOpsSignals -ToolResult $script:FixturePip)
        foreach ($r in @($vmRows + $pipRows)) {
            $r.EntityId | Should -BeExactly $r.EntityId.ToLowerInvariant()
            $r.EntityId | Should -Match '^/subscriptions/'
        }
    }

    It 'maps severity from monthly cost thresholds (Info/Low/Medium)' {
        $rows = @(Normalize-FinOpsSignals -ToolResult $script:FixtureMixed)
        ($rows | Where-Object { $_.MonthlyCost -lt 50 }).Severity | Should -Contain 'Info'
        ($rows | Where-Object { $_.MonthlyCost -ge 50 -and $_.MonthlyCost -le 500 }).Severity | Should -Contain 'Low'
        ($rows | Where-Object { $_.MonthlyCost -gt 500 }).Severity | Should -Contain 'Medium'
    }

    It 'maps impact from estimated monthly cost tiers' {
        $impactInput = [PSCustomObject]@{
            Status = 'Success'
            ToolVersion = '1.2.0'
            Findings = @(
                [PSCustomObject]@{
                    Id='f-low'; Source='finops'; Category='Cost'; Severity='Info'; Compliant=$false; Title='low'
                    ResourceId='/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg/providers/Microsoft.Compute/disks/d1'
                    EstimatedMonthlyCost=25; Currency='USD'; LearnMoreUrl=''; DetectionCategory='Unattached managed disks'
                },
                [PSCustomObject]@{
                    Id='f-medium'; Source='finops'; Category='Cost'; Severity='Info'; Compliant=$false; Title='medium'
                    ResourceId='/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg/providers/Microsoft.Compute/disks/d2'
                    EstimatedMonthlyCost=250; Currency='USD'; LearnMoreUrl=''; DetectionCategory='Unattached managed disks'
                },
                [PSCustomObject]@{
                    Id='f-high'; Source='finops'; Category='Cost'; Severity='Info'; Compliant=$false; Title='high'
                    ResourceId='/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg/providers/Microsoft.Compute/disks/d3'
                    EstimatedMonthlyCost=750; Currency='USD'; LearnMoreUrl=''; DetectionCategory='Unattached managed disks'
                }
            )
        }
        $rows = @(Normalize-FinOpsSignals -ToolResult $impactInput)
        ($rows | Where-Object { $_.MonthlyCost -lt 100 }).Impact | Should -Contain 'Low'
        ($rows | Where-Object { $_.MonthlyCost -ge 100 -and $_.MonthlyCost -le 500 }).Impact | Should -Contain 'Medium'
        ($rows | Where-Object { $_.MonthlyCost -gt 500 }).Impact | Should -Contain 'High'
    }

    It 'supports all five severity labels case-insensitively when raw severity is provided' {
        $rawSeverityInput = [PSCustomObject]@{
            Status = 'Success'
            Findings = @(
                @('CRITICAL','High','medium','LOW','info') | ForEach-Object {
                    [PSCustomObject]@{
                        Id = [guid]::NewGuid().ToString()
                        Source = 'finops'
                        Category = 'Cost'
                        Severity = $_
                        Compliant = $false
                        Title = "Severity $_ sample"
                        Detail = 'sample'
                        ResourceId = "/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-finops/providers/Microsoft.Compute/disks/sev-$($_.ToLowerInvariant())"
                        EstimatedMonthlyCost = 0
                        Currency = 'USD'
                        LearnMoreUrl = ''
                    }
                }
            )
        }
        $rows = @(Normalize-FinOpsSignals -ToolResult $rawSeverityInput)
        ($rows | Where-Object { $_.Severity -eq 'Critical' }).Count | Should -Be 1
        ($rows | Where-Object { $_.Severity -eq 'High' }).Count | Should -Be 1
        ($rows | Where-Object { $_.Severity -eq 'Medium' }).Count | Should -Be 1
        ($rows | Where-Object { $_.Severity -eq 'Low' }).Count | Should -Be 1
        ($rows | Where-Object { $_.Severity -eq 'Info' }).Count | Should -Be 1
    }

    It 'normalizes ungoverned-snapshot fixture: Medium severity, RuleId stamped, grouped by subscription' {
        $rows = @(Normalize-FinOpsSignals -ToolResult $script:FixtureSnapshot)
        $rows.Count | Should -Be 2
        @($rows | Where-Object { $_.Severity -ne 'Medium' }).Count | Should -Be 0
        @($rows | Where-Object { $_.RuleId -ne 'finops-ungoverned-snapshot' }).Count | Should -Be 0
        $rows[0].EntityType | Should -Be 'AzureResource'
        $rows[0].Platform | Should -Be 'Azure'
        $rows[0].Compliant | Should -BeFalse
        $rows[0].EntityId | Should -Match '/providers/microsoft\.compute/snapshots/'
        $bySub = @($rows | Group-Object SubscriptionId)
        $bySub.Count | Should -Be 2
        @($bySub | Where-Object { $_.Name -eq '11111111-1111-1111-1111-111111111111' }).Count | Should -Be 1
        @($bySub | Where-Object { $_.Name -eq '22222222-2222-2222-2222-222222222222' }).Count | Should -Be 1
    }

    It 'normalizes AppServicePlanIdleCpu with Low severity and rightsize remediation' {
        $rows = @(Normalize-FinOpsSignals -ToolResult $script:FixtureAppServiceCpu)
        $idleRow = @($rows | Where-Object { $_.DetectionCategory -eq 'AppServicePlanIdleCpu' })[0]
        $idleRow.Severity | Should -Be 'Low'
        $idleRow.RuleId | Should -Be 'finops-appserviceplan-idle-cpu'
        $idleRow.Remediation | Should -Match 'rightsize'
        $idleRow.Effort | Should -Be 'Medium'
        $idleRow.ScoreDelta | Should -BeGreaterThan 0
    }

    It 'normalizes degraded App Service metrics path as Info with access guidance' {
        $rows = @(Normalize-FinOpsSignals -ToolResult $script:FixtureAppServiceCpu)
        $degradedRow = @($rows | Where-Object { $_.DetectionCategory -eq 'AppServicePlanIdleCpuMetricsDegraded' })[0]
        $degradedRow.Severity | Should -Be 'Info'
        $degradedRow.Remediation | Should -Match 'Monitoring Reader'
        $degradedRow.Effort | Should -Be 'Medium'
        $degradedRow.ScoreDelta | Should -BeNullOrEmpty
    }
}
