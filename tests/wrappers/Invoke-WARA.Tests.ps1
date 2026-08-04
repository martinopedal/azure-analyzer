#Requires -Version 7.4
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# See tests/wrappers/Invoke-AlzQueries.Tests.ps1 header -- single-file run guard.
$env:AZURE_ANALYZER_TEST_PRIOR_SUPPRESS = if ($null -eq $env:AZURE_ANALYZER_SUPPRESS_TOOL_MISSING_WARNINGS) { '__unset__' } else { $env:AZURE_ANALYZER_SUPPRESS_TOOL_MISSING_WARNINGS }
$env:AZURE_ANALYZER_SUPPRESS_TOOL_MISSING_WARNINGS = '1'

BeforeAll {
    $script:Here = Split-Path $PSCommandPath -Parent
    $script:RepoRoot = Resolve-Path (Join-Path $script:Here '..' '..')
    $script:Wrapper = Join-Path $script:RepoRoot 'modules' 'Invoke-WARA.ps1'

    # Builds a stand-in WARA module. The collector writes its output the way the real one
    # does (wara.psm1 emits '.\WARA-File-<timestamp>.json' relative to the working directory),
    # so the wrapper is exercised against collector-produced files rather than files the test
    # placed on disk beforehand. That distinction is the whole point of these tests: the
    # underscore-vs-dash bug survived precisely because the old fixture pre-placed the file.
    function New-WaraStubModule {
        param(
            [Parameter(Mandatory)] [string] $Root,
            [string] $CollectorThrows
        )
        $moduleRoot = Join-Path $Root 'WARA'
        New-Item -ItemType Directory -Path $moduleRoot -Force | Out-Null

        $collectorBody = if ($CollectorThrows) {
            "    throw '$($CollectorThrows.Replace("'", "''"))'"
        } else {
            @'
    $name = 'WARA-File-' + (Get-Date -Format 'yyyy-MM-dd-HH-mm-ss-fff') + '.json'
    Copy-Item -Path $env:WARA_TEST_TEMPLATE -Destination (Join-Path (Get-Location).Path $name) -Force
'@
        }

        $psm1 = @"
function Start-WARACollector {
    param([string]`$TenantID,[string]`$SubscriptionIds)
$collectorBody
}
function Start-WARAAnalyzer {
    param([Parameter(Mandatory)][string]`$JSONFile,[string]`$ExpertAnalysisFile,`$RecommendationDataUri,`$CustomRecommendationObject)
    Set-Content -Path (Join-Path (Get-Location).Path 'analyzer-call.txt') -Value `$JSONFile -Encoding UTF8
    New-Item -ItemType File -Path (Join-Path (Get-Location).Path ('Expert-Analysis-' + (Get-Date -Format 'yyyy-MM-dd-HH-mm-ss-fff') + '.xlsx')) -Force | Out-Null
}
function Import-Excel {
    param([string]`$Path,[string]`$WorksheetName)
    return @(
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
Export-ModuleMember -Function Start-WARACollector, Start-WARAAnalyzer, Import-Excel
"@
        $psm1 | Set-Content -Path (Join-Path $moduleRoot 'WARA.psm1') -Encoding UTF8
        if (-not (Test-Path (Join-Path $moduleRoot 'WARA.psd1'))) {
            New-ModuleManifest -Path (Join-Path $moduleRoot 'WARA.psd1') -RootModule 'WARA.psm1' -ModuleVersion '2.4.0' -Guid '96f1db7a-1888-4c3a-826f-db98f4e8af09' | Out-Null
        }
        return $moduleRoot
    }
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
        $templatePath = Join-Path $TestDrive 'collector-template.json'

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
'@ | Set-Content -Path $templatePath -Encoding UTF8

        $moduleRoot = New-WaraStubModule -Root $TestDrive
        $env:WARA_TEST_TEMPLATE = $templatePath
        $originalModulePath = $env:PSModulePath
        $env:PSModulePath = "$TestDrive$([IO.Path]::PathSeparator)$env:PSModulePath"

        try {
            $result = & $script:Wrapper -SubscriptionId '00000000-0000-0000-0000-000000000001' -TenantId '11111111-1111-1111-1111-111111111111' -OutputPath $outputDir

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
            Remove-Module WARA -ErrorAction SilentlyContinue
            $env:PSModulePath = $originalModulePath
            Remove-Item Env:WARA_TEST_TEMPLATE -ErrorAction SilentlyContinue
            $moduleRoot | Out-Null
        }
    }
}

Describe 'Invoke-WARA: collector output contract' {
    Context 'when the collector writes the current dash-form filename with v2 arrays' {
        BeforeAll {
            $script:OutDir = Join-Path $TestDrive 'wara-v2'
            New-Item -ItemType Directory -Path $script:OutDir -Force | Out-Null
            $template = Join-Path $TestDrive 'collector-v2.json'

            # Shape emitted by WARA collector v2: no 'Recommendations' key at all. APRL query
            # hits land in 'impactedResources', Azure Advisor hits in 'advisory'.
            @'
{
  "impactedResources": [
    {
      "recommendationId": "aprl-001",
      "id": "/subscriptions/00000000-0000-0000-0000-000000000002/resourceGroups/rg-a/providers/Microsoft.Storage/storageAccounts/stprod"
    }
  ],
  "advisory": [
    {
      "recommendationId": "adv-001",
      "id": "/subscriptions/00000000-0000-0000-0000-000000000002/resourceGroups/rg-a/providers/Microsoft.Compute/virtualMachines/vm-adv",
      "description": "Enable backup on this virtual machine",
      "impact": "High"
    }
  ]
}
'@ | Set-Content -Path $template -Encoding UTF8

            $null = New-WaraStubModule -Root $TestDrive
            $env:WARA_TEST_TEMPLATE = $template
            $script:PriorModulePath = $env:PSModulePath
            $env:PSModulePath = "$TestDrive$([IO.Path]::PathSeparator)$env:PSModulePath"
            $script:Result = & $script:Wrapper -SubscriptionId '00000000-0000-0000-0000-000000000002' -TenantId '11111111-1111-1111-1111-111111111111' -OutputPath $script:OutDir
        }

        AfterAll {
            Remove-Module WARA -ErrorAction SilentlyContinue
            $env:PSModulePath = $script:PriorModulePath
            Remove-Item Env:WARA_TEST_TEMPLATE -ErrorAction SilentlyContinue
        }

        It 'succeeds even though the file uses dashes rather than underscores' {
            $script:Result.Status | Should -Be 'Success'
        }

        It 'emits findings from both impactedResources and advisory' {
            @($script:Result.Findings).Count | Should -Be 2
        }

        It 'keeps the Advisor description rather than falling back to Unknown' {
            $advisor = @($script:Result.Findings | Where-Object { $_.ResourceId -match 'vm-adv' })
            $advisor.Count | Should -Be 1
            $advisor[0].Title | Should -Be 'Enable backup on this virtual machine'
        }

        It 'passes the collector output to the analyzer via -JSONFile' {
            $sentinel = Join-Path $script:OutDir 'analyzer-call.txt'
            Test-Path $sentinel | Should -BeTrue
            (Get-Content $sentinel -Raw).Trim() | Should -Match 'WARA-File-.*\.json$'
        }
    }

    Context 'when the collector fails and a stale file from an earlier run is present' {
        BeforeAll {
            $script:StaleDir = Join-Path $TestDrive 'wara-stale'
            New-Item -ItemType Directory -Path $script:StaleDir -Force | Out-Null

            # Left behind by a previous successful scan. output/ is never cleaned between
            # runs, so this must not be mistaken for output the collector just produced.
            @'
{
  "impactedResources": [
    {
      "recommendationId": "stale-001",
      "id": "/subscriptions/00000000-0000-0000-0000-000000000003/resourceGroups/rg-old/providers/Microsoft.Storage/storageAccounts/stold"
    }
  ]
}
'@ | Set-Content -Path (Join-Path $script:StaleDir 'WARA-File-2026-01-01-08-00.json') -Encoding UTF8

            $null = New-WaraStubModule -Root $TestDrive -CollectorThrows 'Authorization failed for subscription'
            $script:PriorModulePath2 = $env:PSModulePath
            $env:PSModulePath = "$TestDrive$([IO.Path]::PathSeparator)$env:PSModulePath"
            $script:StaleResult = & $script:Wrapper -SubscriptionId '00000000-0000-0000-0000-000000000003' -TenantId '11111111-1111-1111-1111-111111111111' -OutputPath $script:StaleDir -WarningAction SilentlyContinue
        }

        AfterAll {
            Remove-Module WARA -ErrorAction SilentlyContinue
            $env:PSModulePath = $script:PriorModulePath2
        }

        It 'reports Failed instead of re-reporting the previous run' {
            $script:StaleResult.Status | Should -Be 'Failed'
        }

        It 'returns no findings from the stale file' {
            @($script:StaleResult.Findings).Count | Should -Be 0
        }
    }
}

AfterAll {
    if ($env:AZURE_ANALYZER_TEST_PRIOR_SUPPRESS -eq '__unset__') {
        Remove-Item Env:AZURE_ANALYZER_SUPPRESS_TOOL_MISSING_WARNINGS -ErrorAction SilentlyContinue
    } elseif ($null -ne $env:AZURE_ANALYZER_TEST_PRIOR_SUPPRESS) {
        $env:AZURE_ANALYZER_SUPPRESS_TOOL_MISSING_WARNINGS = $env:AZURE_ANALYZER_TEST_PRIOR_SUPPRESS
    }
    Remove-Item Env:AZURE_ANALYZER_TEST_PRIOR_SUPPRESS -ErrorAction SilentlyContinue
}
