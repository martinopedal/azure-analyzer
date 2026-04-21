#Requires -Version 7.4
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

BeforeAll {
    $script:Here = Split-Path $PSCommandPath -Parent
    $script:RepoRoot = Resolve-Path (Join-Path $script:Here '..' '..')
    $script:Wrapper = Join-Path $script:RepoRoot 'modules' 'Invoke-ADOPipelineCorrelator.ps1'
    $script:SecretsFixture = Join-Path $script:RepoRoot 'tests' 'fixtures' 'ado-pipeline-correlation' 'secrets-findings.json'
}

Describe 'Invoke-ADOPipelineCorrelator' {
    Context 'when no input file exists' {
        It 'returns skipped' {
            $result = & $script:Wrapper -AdoOrg 'contoso' -SecretsFindingsPath 'C:\does-not-exist.json'
            $result.Status | Should -Be 'Skipped'
            @($result.Findings).Count | Should -Be 0
        }
    }

    Context 'when secret commit is not found in pipeline runs' {
        BeforeAll {
            $env:ADO_PAT_TOKEN = 'fake-token'
            Mock Invoke-WebRequest {
                param([string]$Uri)
                if ($Uri -match '_apis/build/builds\\?') {
                    $body = '{"value":[{"id":1001,"sourceVersion":"ffffffff99999999","definition":{"id":55,"name":"payments-ci"}}]}'
                    return [PSCustomObject]@{ Content = $body; Headers = @{} }
                }
                if ($Uri -match '/logs\\?') {
                    return [PSCustomObject]@{ Content = '{"value":[{"id":1}]}' ; Headers = @{} }
                }
                throw \"Unexpected URI: $Uri\"
            }
            $result = & $script:Wrapper -AdoOrg 'contoso' -SecretsFindingsPath $script:SecretsFixture
        }

        AfterAll {
            Remove-Item Env:\ADO_PAT_TOKEN -ErrorAction SilentlyContinue
        }

        It 'returns success with zero correlated findings' {
            $result.Status | Should -Be 'Success'
            @($result.Findings).Count | Should -Be 1
            $result.Findings[0].CorrelationStatus | Should -Be 'uncorrelated'
            $result.Findings[0].SecretFindingId | Should -Be 'secret-1'
            $result.Findings[0].Title | Should -Match '\[build:none secret:secret-1\]'
        }
    }

    Context 'when one leaked commit appears in three pipeline runs' {
        BeforeAll {
            $env:ADO_PAT_TOKEN = 'fake-token'
            Mock Invoke-WebRequest {
                param([string]$Uri)
                if ($Uri -match '_apis/build/builds\\?') {
                    $body = @'
{"value":[
  {"id":2001,"sourceVersion":"aaaaaaaa11111111","definition":{"id":55,"name":"payments-ci"},"_links":{"web":{"href":"https://dev.azure.com/contoso/payments/_build/results?buildId=2001"}}},
  {"id":2002,"sourceVersion":"aaaaaaaa11111111","definition":{"id":56,"name":"payments-pr"},"_links":{"web":{"href":"https://dev.azure.com/contoso/payments/_build/results?buildId=2002"}}},
  {"id":2003,"sourceVersion":"aaaaaaaa11111111","definition":{"id":57,"name":"payments-release"},"_links":{"web":{"href":"https://dev.azure.com/contoso/payments/_build/results?buildId=2003"}}}
]}
'@
                    return [PSCustomObject]@{ Content = $body; Headers = @{} }
                }
                if ($Uri -match '/logs\\?') {
                    return [PSCustomObject]@{ Content = '{"value":[{"id":1},{"id":2}]}' ; Headers = @{} }
                }
                throw \"Unexpected URI: $Uri\"
            }
            $result = & $script:Wrapper -AdoOrg 'contoso' -SecretsFindingsPath $script:SecretsFixture
        }

        AfterAll {
            Remove-Item Env:\ADO_PAT_TOKEN -ErrorAction SilentlyContinue
        }

        It 'emits one correlation finding per matching pipeline run' {
            $result.Status | Should -Be 'Success'
            @($result.Findings).Count | Should -Be 3
            @($result.Findings | Select-Object -ExpandProperty BuildId) | Should -Contain '2001'
            @($result.Findings | Select-Object -ExpandProperty BuildId) | Should -Contain '2002'
            @($result.Findings | Select-Object -ExpandProperty BuildId) | Should -Contain '2003'
            @($result.Findings | Select-Object -ExpandProperty CorrelationStatus -Unique) | Should -Contain 'correlated-direct'
            @($result.Findings | Select-Object -ExpandProperty SecretFindingId -Unique) | Should -Contain 'secret-1'
            @($result.Findings | Select-Object -ExpandProperty Title | Where-Object { $_ -match '\[build:2001 secret:secret-1\]' }).Count | Should -Be 1
        }
    }
}
