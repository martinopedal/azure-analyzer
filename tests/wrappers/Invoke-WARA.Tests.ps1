#Requires -Version 7.4
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

BeforeAll {
    $script:Here = Split-Path $PSCommandPath -Parent
    $script:RepoRoot = Resolve-Path (Join-Path $script:Here '..' '..')
    $script:Wrapper = Join-Path $script:RepoRoot 'modules' 'Invoke-WARA.ps1'
}

Describe 'Invoke-WARA: error paths' {
    Context 'when WARA module is missing' {
        BeforeAll {
            Mock Get-Module { return $null }
            $result = & $script:Wrapper -SubscriptionId '00000000-0000-0000-0000-000000000000'
        }

        It 'returns Status = Skipped' {
            $result.Status | Should -Be 'Skipped'
        }

        It 'returns empty Findings' {
            @($result.Findings).Count | Should -Be 0
        }

        It 'includes message about WARA not installed' {
            $result.Message | Should -Match 'not installed|not found'
        }

        It 'sets Source to wara' {
            $result.Source | Should -Be 'wara'
        }

        It 'includes SchemaVersion 1.0 in the v1 envelope' {
            $result.SchemaVersion | Should -Be '1.0'
        }
    }
}

Describe 'Invoke-WARA: success paths' {
    It 'emits one finding per impacted resource and captures Schema 2.2 inputs' {
        $outputDir = Join-Path $TestDrive 'wara'
        New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
        $jsonPath = Join-Path $outputDir 'WARA_File_20260422.json'
        $xlsxPath = Join-Path $outputDir 'Expert-Analysis-20260422.xlsx'

        @'
{
  "Recommendations": [
    {
      "GUID": "rec-001",
      "Recommendation": "Use zone-redundant services",
      "Category": "Reliability",
      "Severity": "High",
      "Impact": "High",
      "Effort": "Low",
      "Service": "compute",
      "Description": { "Steps": [ "Enable zone redundancy", "Validate failover paths" ] },
      "ImpactedResources": [
        { "ResourceId": "/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/rg-prod/providers/Microsoft.Compute/virtualMachines/vm-a" },
        { "ResourceId": "/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/rg-prod/providers/Microsoft.Compute/virtualMachines/vm-b" }
      ],
      "LearnMoreLink": "https://learn.microsoft.com/azure/well-architected/reliability"
    }
  ]
}
'@ | Set-Content -Path $jsonPath -Encoding UTF8
        New-Item -ItemType File -Path $xlsxPath -Force | Out-Null

        function global:Get-Module {
            param([switch] $ListAvailable, [string] $Name)
            if ($ListAvailable -and $Name -eq 'WARA') {
                return [PSCustomObject]@{ Name = 'WARA'; Version = [version]'2.4.0' }
            }
            return $null
        }
        function global:Import-Module { }
        function global:Get-Command {
            param([string] $Name)
            if ($Name -in @('Start-WARACollector', 'Start-WARAAnalyzer', 'Import-Excel')) {
                return [PSCustomObject]@{ Name = $Name }
            }
            return $null
        }
        function global:Get-AzContext { [PSCustomObject]@{ Tenant = [PSCustomObject]@{ Id = '11111111-1111-1111-1111-111111111111' } } }
        function global:Start-WARACollector { }
        function global:Start-WARAAnalyzer { }
        function global:Import-Excel {
            @(
                [PSCustomObject]@{
                    RecommendationId = 'rec-001'
                    Pillar = 'Reliability'
                    PotentialBenefit = 'Improves recovery posture'
                    Status = 'Pending'
                    Impact = 'High'
                    Effort = 'Low'
                    ServiceCategory = 'compute'
                    DeepLinkUrl = 'https://learn.microsoft.com/azure/well-architected/reliability/design-redundancy'
                    'Remediation Steps' = 'Enable zone redundancy;Validate failover paths'
                }
            )
        }

        try {
            $result = & $script:Wrapper -SubscriptionId '00000000-0000-0000-0000-000000000001' -OutputPath $outputDir

            $result.Status | Should -Be 'Success'
            $result.ToolVersion | Should -Be '2.4.0'
            @($result.Findings).Count | Should -Be 2
            @($result.Findings | ForEach-Object { $_.ResourceId.ToLowerInvariant() } | Sort-Object) | Should -Be @(
                '/subscriptions/00000000-0000-0000-0000-000000000001/resourcegroups/rg-prod/providers/microsoft.compute/virtualmachines/vm-a',
                '/subscriptions/00000000-0000-0000-0000-000000000001/resourcegroups/rg-prod/providers/microsoft.compute/virtualmachines/vm-b'
            )
            $result.Findings[0].Pillar | Should -Be 'Reliability'
            $result.Findings[0].Impact | Should -Be 'High'
            $result.Findings[0].Effort | Should -Be 'Low'
            $result.Findings[0].DeepLinkUrl | Should -Be 'https://learn.microsoft.com/azure/well-architected/reliability/design-redundancy'
            $result.Findings[0].BaselineTags | Should -Contain 'service-category:compute'
            @($result.Findings[0].EntityRefs).Count | Should -Be 2
        }
        finally {
            foreach ($fn in @('Get-Module', 'Import-Module', 'Get-Command', 'Get-AzContext', 'Start-WARACollector', 'Start-WARAAnalyzer', 'Import-Excel')) {
                if (Test-Path "Function:global:$fn") { Remove-Item "Function:global:$fn" -ErrorAction SilentlyContinue }
            }
        }
    }
}

