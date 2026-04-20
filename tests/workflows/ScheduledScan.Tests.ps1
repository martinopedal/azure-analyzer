#Requires -Version 7.4
<#
Tests for .github/workflows/scheduled-scan.yml.
Asserts policy invariants:
  - cron schedule + workflow_dispatch present
  - SHA-pinned actions (no @v* tag-only references)
  - id-token: write only on the scan job
  - issues: write only on the report job (which has NO id-token)
  - no PATs / GITHUB_TOKEN secret leaks
  - concurrency group present
  - allow-listed includeTools default
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

BeforeAll {
    if (-not (Get-Module -ListAvailable powershell-yaml)) {
        Install-Module powershell-yaml -Scope CurrentUser -Force -SkipPublisherCheck -ErrorAction Stop | Out-Null
    }
    Import-Module powershell-yaml -ErrorAction Stop

    $script:RepoRoot = Resolve-Path (Join-Path $PSScriptRoot '..' '..')
    $script:WorkflowPath = Join-Path $script:RepoRoot '.github' 'workflows' 'scheduled-scan.yml'
    $script:RawYaml = Get-Content -Raw -Path $script:WorkflowPath
    $script:Workflow = ConvertFrom-Yaml $script:RawYaml
    # YAML 1.1 quirk: the unquoted `on` key parses to boolean True.
    $script:OnBlock = if ($script:Workflow.ContainsKey('on')) { $script:Workflow['on'] } else { $script:Workflow[$true] }
}

Describe 'scheduled-scan.yml policy contract' {
    It 'declares schedule + workflow_dispatch triggers' {
        $script:OnBlock.Keys | Should -Contain 'schedule'
        $script:OnBlock.Keys | Should -Contain 'workflow_dispatch'
        @($script:OnBlock['schedule'])[0]['cron'] | Should -Be '0 6 * * *'
    }

    It 'sets a top-level read-only contents permission' {
        $script:Workflow['permissions']['contents'] | Should -Be 'read'
    }

    It 'declares a concurrency group to prevent parallel-rerun races' {
        $script:Workflow['concurrency'] | Should -Not -BeNullOrEmpty
        $script:Workflow['concurrency']['group'] | Should -Be 'scheduled-scan'
    }

    It 'grants id-token: write only on the scan job' {
        $scan = $script:Workflow['jobs']['scan']
        $scan['permissions']['id-token'] | Should -Be 'write'
        $scan['permissions'].Keys | Should -Not -Contain 'issues'

        $report = $script:Workflow['jobs']['report']
        $report['permissions']['issues'] | Should -Be 'write'
        $report['permissions'].Keys | Should -Not -Contain 'id-token'
    }

    It 'uses azure/login via OIDC (no client-secret input)' {
        $loginStep = $script:Workflow['jobs']['scan']['steps'] | Where-Object { $_['uses'] -and $_['uses'] -like 'azure/login@*' }
        $loginStep | Should -Not -BeNullOrEmpty
        $loginStep['with'].Keys | Should -Contain 'client-id'
        $loginStep['with'].Keys | Should -Contain 'tenant-id'
        $loginStep['with'].Keys | Should -Not -Contain 'client-secret'
        $loginStep['with'].Keys | Should -Not -Contain 'creds'
    }

    It 'pins every action by SHA (40 hex chars), never bare @v* tag' {
        $useLines = ($script:RawYaml -split "`n") | Where-Object { $_ -match '^\s*-?\s*uses:\s*\S+' }
        foreach ($line in $useLines) {
            if ($line -match 'uses:\s*([^\s#]+)') {
                $ref = $Matches[1]
                $ref | Should -Match '@[0-9a-f]{40}$' -Because "every action MUST be SHA-pinned (offender: $ref)"
            }
        }
    }

    It 'does not reference any PAT-style secrets' {
        $script:RawYaml | Should -Not -Match '(?i)\bsecrets\.(GH_PAT|PAT_TOKEN|PERSONAL_ACCESS_TOKEN)\b'
        $script:RawYaml | Should -Not -Match '(?i)client-secret\s*:'
    }

    It 'defaults workflow_dispatch include_tools to allow-listed names' {
        $allowed = @('azqr','psrule','alz-queries','wara','azure-cost','finops','defender-for-cloud','sentinel-incidents','sentinel-coverage','maester','identity-correlator')
        $default = $script:OnBlock['workflow_dispatch']['inputs']['include_tools']['default']
        foreach ($t in ($default -split ',\s*')) {
            $allowed | Should -Contain $t
        }
    }

    It 'guards report job with a non-zero critical_count expression' {
        $script:Workflow['jobs']['report']['if'] | Should -Match "critical_count.*!=.*'0'"
    }

    It 'scan job grants actions:read to download baseline artifacts' {
        $scan = $script:Workflow['jobs']['scan']
        $scan['permissions']['actions'] | Should -Be 'read'
    }

    It 'scan job exports new_critical_count output for diff-mode noise suppression' {
        $outputs = $script:Workflow['jobs']['scan']['outputs']
        $outputs.Keys | Should -Contain 'new_critical_count'
    }

    It 'report job uses new_critical_count (not total) to suppress standing-finding noise' {
        $reportIf = $script:Workflow['jobs']['report']['if']
        $reportIf | Should -Match 'new_critical_count'
    }
}
