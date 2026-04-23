#Requires -Version 7.4

BeforeAll {
    $repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..' '..')
    . (Join-Path $repoRoot 'modules' 'shared' 'AuditorReportBuilder.ps1')

    function New-TestFinding {
        param(
            [string]$Id,
            [string]$Severity = 'High',
            [bool]$Compliant = $false,
            [string]$Framework = 'CIS',
            [string]$ControlId = 'CIS 1.1',
            [string]$Remediation = 'Enable setting'
        )

        return [pscustomobject]@{
            Id = $Id
            Source = 'azqr'
            ToolVersion = '1.0.0'
            Severity = $Severity
            Compliant = $Compliant
            Title = "Title-$Id"
            EntityId = '/subscriptions/sub-001/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/vm1'
            SubscriptionId = 'sub-001'
            Remediation = $Remediation
            ComplianceMappings = @(
                [pscustomobject]@{
                    Framework = $Framework
                    ControlId = $ControlId
                    ControlTitle = "Control-$ControlId"
                }
            )
        }
    }
}

Describe 'AuditorReportBuilder' {
    It 'Resolve-AuditorContext prefers manifest SelectedTier over explicit -Tier' {
        $tmp = Join-Path $TestDrive 'ctx-tier'
        $null = New-Item -ItemType Directory -Path $tmp -Force

        @([pscustomobject]@{ Id='F1'; Severity='High'; Compliant=$false; SubscriptionId='sub1' }) | ConvertTo-Json -Depth 10 | Set-Content -Path (Join-Path $tmp 'results.json') -Encoding UTF8
        [pscustomobject]@{ SchemaVersion='3.1'; Entities=@(); Edges=@() } | ConvertTo-Json -Depth 10 | Set-Content -Path (Join-Path $tmp 'entities.json') -Encoding UTF8
        [pscustomobject]@{ SelectedTier='SidecarSqlite' } | ConvertTo-Json -Depth 10 | Set-Content -Path (Join-Path $tmp 'report-manifest.json') -Encoding UTF8

        $ctx = Resolve-AuditorContext -InputPath (Join-Path $tmp 'results.json') -EntitiesPath (Join-Path $tmp 'entities.json') -ManifestPath (Join-Path $tmp 'report-manifest.json') -Tier 'PureJson'
        $ctx.Tier | Should -Be 'SidecarSqlite'
    }

    It 'Get-AuditorExecutiveSummary computes severity counts and top risks' {
        $findings = @(
            New-TestFinding -Id 'F1' -Severity 'Critical' -ControlId 'CIS 1.1'
            New-TestFinding -Id 'F2' -Severity 'High' -ControlId 'CIS 1.2'
            New-TestFinding -Id 'F3' -Severity 'Low' -ControlId 'CIS 1.3' -Compliant $true
        )
        $summary = Get-AuditorExecutiveSummary -Findings $findings -ControlFrameworks @('CIS')

        $summary.severityCounts.Critical | Should -Be 1
        $summary.severityCounts.High | Should -Be 1
        $summary.severityCounts.Low | Should -Be 0
        @($summary.topRisks).Count | Should -Be 2
    }

    It 'Get-AuditorControlDomainSections groups controls per framework' {
        $findings = @(
            New-TestFinding -Id 'F1' -Framework 'CIS' -ControlId 'CIS 1.1'
            New-TestFinding -Id 'F2' -Framework 'NIST' -ControlId 'AC-1'
            New-TestFinding -Id 'F3' -Framework 'CIS' -ControlId 'CIS 1.1'
        )

        $sections = Get-AuditorControlDomainSections -Findings $findings -Frameworks @('CIS','NIST')
        @($sections).Count | Should -Be 2
        (@($sections | Where-Object { $_.framework -eq 'CIS' })[0].controls | Select-Object -First 1).id | Should -Be 'CIS 1.1'
    }

    It 'Get-AuditorRemediationAppendix groups and orders by aggregate severity' {
        $findings = @(
            New-TestFinding -Id 'F1' -Severity 'Critical' -Remediation 'A'
            New-TestFinding -Id 'F2' -Severity 'High' -Remediation 'A'
            New-TestFinding -Id 'F3' -Severity 'Low' -Remediation 'B'
        )

        $appendix = Get-AuditorRemediationAppendix -Findings $findings
        @($appendix.groupsByRemediation).Count | Should -Be 2
        $appendix.groupsByRemediation[0].remediation | Should -Be 'A'
    }

    It 'New-AuditorCitation emits single-line workpaper-ready format' {
        $citation = New-AuditorCitation -Finding (New-TestFinding -Id 'F1' -Severity 'High') -Style 'workpaper'
        $citation | Should -Match '^\[azqr 1.0.0\] F1: '
        $citation | Should -Match 'Resource:'
        $citation | Should -Match 'Severity: High'
    }

    It 'Get-AuditorEvidenceExport writes CSV JSON and citations' {
        $tmp = Join-Path $TestDrive 'evidence'
        $null = New-Item -ItemType Directory -Path $tmp -Force
        $findings = @(
            New-TestFinding -Id 'F1' -Framework 'CIS' -ControlId 'CIS 1.1'
            New-TestFinding -Id 'F2' -Framework 'NIST' -ControlId 'AC-1'
        )

        $paths = Get-AuditorEvidenceExport -Findings $findings -OutputDirectory $tmp -Formats @('csv','json')
        (Test-Path -LiteralPath (Join-Path $tmp 'audit-evidence' 'findings-all.csv')) | Should -BeTrue
        (Test-Path -LiteralPath (Join-Path $tmp 'audit-evidence' 'findings-all.json')) | Should -BeTrue
        (Test-Path -LiteralPath (Join-Path $tmp 'audit-evidence' 'citations.txt')) | Should -BeTrue
        @($paths).Count | Should -BeGreaterThan 2
    }

    It 'Build-AuditorReport writes reports and appends manifest profile.auditor' {
        $tmp = Join-Path $TestDrive 'build'
        $null = New-Item -ItemType Directory -Path $tmp -Force

        @(
            New-TestFinding -Id 'F1' -Severity 'Critical' -Framework 'CIS' -ControlId 'CIS 1.1'
            New-TestFinding -Id 'F2' -Severity 'High' -Framework 'NIST' -ControlId 'AC-1'
        ) | ConvertTo-Json -Depth 20 | Set-Content -Path (Join-Path $tmp 'results.json') -Encoding UTF8
        [pscustomobject]@{ SchemaVersion='3.1'; Entities=@(); Edges=@() } | ConvertTo-Json -Depth 10 | Set-Content -Path (Join-Path $tmp 'entities.json') -Encoding UTF8
        [pscustomobject]@{ SelectedTier='PureJson' } | ConvertTo-Json -Depth 10 | Set-Content -Path (Join-Path $tmp 'report-manifest.json') -Encoding UTF8

        $result = Build-AuditorReport -InputPath (Join-Path $tmp 'results.json') -EntitiesPath (Join-Path $tmp 'entities.json') -ManifestPath (Join-Path $tmp 'report-manifest.json') -OutputDirectory $tmp

        (Test-Path -LiteralPath (Join-Path $tmp 'audit-report.html')) | Should -BeTrue
        (Test-Path -LiteralPath (Join-Path $tmp 'audit-report.md')) | Should -BeTrue

        $manifest = Get-Content -LiteralPath (Join-Path $tmp 'report-manifest.json') -Raw | ConvertFrom-Json
        $manifest.report.profile.auditor.schemaVersion | Should -Be '1.0'
        @($manifest.report.profile.auditor.sections).Count | Should -BeGreaterThan 0
        @($manifest.report.profile.auditor.degradations).Count | Should -BeGreaterOrEqual 0

        $result.Tier | Should -Be 'PureJson'
    }
}
