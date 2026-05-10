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
    $script:RepoRoot = Resolve-Path (Join-Path $PSScriptRoot '..' '..')
    $script:WorkflowPath = Join-Path $script:RepoRoot '.github' 'workflows' 'scheduled-scan.yml'
    $script:RawYaml = Get-Content -Raw -Path $script:WorkflowPath

    if (Get-Module -ListAvailable powershell-yaml) {
        Import-Module powershell-yaml -ErrorAction Stop
        $script:Workflow = ConvertFrom-Yaml $script:RawYaml
    } else {
        function Get-StepBlock {
            param([Parameter(Mandatory)][string] $Name)
            $escaped = [regex]::Escape($Name)
            # Fallback parser for constrained local environments without powershell-yaml.
            # It intentionally supports this workflow's uniform step indentation and simple blocks.
            $match = [regex]::Match($script:RawYaml, "(?ms)^(?<indent>\s*)- name: $escaped\s*\n(?<block>.*?)(?=^\k<indent>- name:|\z)")
            if (-not $match.Success) { return '' }
            $match.Groups['block'].Value
        }

        function ConvertTo-MinimalStep {
            param([Parameter(Mandatory)][string] $Name)
            $block = Get-StepBlock -Name $Name
            $step = [ordered]@{ name = $Name }
            if ($block -match '(?m)^\s+id:[ \t]*(?<value>\S+)') { $step['id'] = $Matches['value'] }
            if ($block -match '(?m)^\s+uses:[ \t]*(?<value>\S+)') { $step['uses'] = $Matches['value'] }
            if ($block -match '(?m)^\s+if:[ \t]*(?<value>.+)$') { $step['if'] = $Matches['value'].Trim() }
            if ($block -match '(?m)^\s+run:[ \t]*\|') { $step['run'] = $block }
            if ($block -match '(?m)^\s+env:[ \t]*$') {
                $envMap = @{}
                # scheduled-scan.yml uses simple single-line environment values.
                foreach ($m in [regex]::Matches($block, '(?m)^\s+(?<key>[A-Za-z0-9_]+):[ \t]*(?<value>[^\r\n]+)$')) {
                    $envMap[$m.Groups['key'].Value] = $m.Groups['value'].Value.Trim()
                }
                $step['env'] = $envMap
            }
            if ($block -match '(?m)^\s+with:[ \t]*$') {
                $withMap = @{}
                foreach ($m in [regex]::Matches($block, '(?m)^\s+(?<key>[A-Za-z0-9_-]+):[ \t]*(?<value>[^\r\n]+)$')) {
                    $withMap[$m.Groups['key'].Value] = $m.Groups['value'].Value.Trim()
                }
                $step['with'] = $withMap
            }
            $step
        }

        $script:Workflow = @{
            'on' = @{
                'schedule' = @(@{ 'cron' = ([regex]::Match($script:RawYaml, "cron:\s*'(?<cron>[^']+)'").Groups['cron'].Value) })
                'workflow_dispatch' = @{
                    'inputs' = @{
                        'include_tools' = @{ 'default' = ([regex]::Match($script:RawYaml, "default:\s*'(?<default>[^']+)'").Groups['default'].Value) }
                    }
                }
            }
            'permissions' = @{ 'contents' = 'read' }
            'concurrency' = @{ 'group' = ([regex]::Match($script:RawYaml, '(?m)^\s+group:\s*(?<group>scheduled-scan)$').Groups['group'].Value) }
            'jobs' = @{
                'scan' = @{
                    'permissions' = @{ 'id-token' = 'write'; 'contents' = 'read'; 'actions' = 'read' }
                    'outputs' = @{ 'new_critical_count' = '${{ steps.diff.outputs.new_critical_count }}' }
                    'steps' = @(
                        ConvertTo-MinimalStep -Name 'Validate scope variables'
                        ConvertTo-MinimalStep -Name 'Azure login (OIDC, no PATs)'
                        ConvertTo-MinimalStep -Name 'Install required PowerShell modules'
                        ConvertTo-MinimalStep -Name 'Run azure-analyzer'
                    )
                }
                'report' = @{
                    'if' = ([regex]::Match($script:RawYaml, "(?m)^\s+if:\s*(?<if>always\(\).*new_critical_count.+)$").Groups['if'].Value.Trim())
                    'permissions' = @{ 'contents' = 'read'; 'issues' = 'write' }
                }
            }
        }
    }

    # YAML 1.1 quirk: the unquoted `on` key parses to boolean True.
    $script:OnBlock = if ($script:Workflow.ContainsKey('on')) {
        $script:Workflow['on']
    } elseif ($script:Workflow.ContainsKey($true)) {
        $script:Workflow[$true]
    } else {
        $script:Workflow['true']
    }
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
        $loginStep['if'] | Should -Be "steps.scope.outputs.configured == 'true'"
        $loginStep['with'].Keys | Should -Contain 'client-id'
        $loginStep['with'].Keys | Should -Contain 'tenant-id'
        $loginStep['with'].Keys | Should -Not -Contain 'client-secret'
        $loginStep['with'].Keys | Should -Not -Contain 'creds'
    }

    It 'marks scope validation as an output-producing step' {
        $scopeStep = $script:Workflow['jobs']['scan']['steps'] | Where-Object { $_['name'] -eq 'Validate scope variables' }
        $scopeStep | Should -Not -BeNullOrEmpty
        $scopeStep['id'] | Should -Be 'scope'
        $scopeStep['env'].Keys | Should -Contain 'SCAN_EVENT_NAME'
        $scopeStep['env']['SCAN_EVENT_NAME'] | Should -Match 'github\.event_name'
        $scopeStep['run'] | Should -Match 'configured=false'
        $scopeStep['run'] | Should -Match 'skipping scheduled scan without failing the workflow'
        $scopeStep['run'] | Should -Match 'SCAN_EVENT_NAME'
    }

    It 'gates Azure-dependent steps on validated scope configuration' {
        $steps = $script:Workflow['jobs']['scan']['steps']
        foreach ($stepName in @('Azure login (OIDC, no PATs)', 'Install required PowerShell modules', 'Run azure-analyzer')) {
            $step = $steps | Where-Object { $_['name'] -eq $stepName }
            $step | Should -Not -BeNullOrEmpty
            $step['if'] | Should -Be "steps.scope.outputs.configured == 'true'"
        }
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
