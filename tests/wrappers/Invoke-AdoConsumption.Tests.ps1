#Requires -Version 7.4
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

BeforeAll {
    $script:Here = Split-Path $PSCommandPath -Parent
    $script:RepoRoot = Resolve-Path (Join-Path $script:Here '..' '..')
    $script:Wrapper = Join-Path $script:RepoRoot 'modules' 'Invoke-AdoConsumption.ps1'

    function New-TestHttpException {
        param([int]$StatusCode, [string]$Message)
        $ex = [System.Exception]::new($Message)
        $ex | Add-Member -NotePropertyName Response -NotePropertyValue ([PSCustomObject]@{ StatusCode = $StatusCode }) -Force
        return $ex
    }
}

Describe 'Invoke-AdoConsumption' {
    BeforeEach {
        Remove-Item Env:\ADO_PAT_TOKEN -ErrorAction SilentlyContinue
        Remove-Item Env:\AZURE_DEVOPS_EXT_PAT -ErrorAction SilentlyContinue
        Remove-Item Env:\AZ_DEVOPS_PAT -ErrorAction SilentlyContinue
    }

    AfterAll {
        Remove-Variable -Name ProjectsAttempts -Scope Global -ErrorAction SilentlyContinue
    }

    Context 'when PAT is missing' {
        It 'returns Skipped' {
            $result = & $script:Wrapper -AdoOrg 'contoso'
            $result.Status | Should -Be 'Skipped'
            @($result.Findings).Count | Should -Be 0
        }
    }

    Context 'consumption findings are emitted' {
        BeforeAll {
            $env:ADO_PAT_TOKEN = 'fake-token'

            # Compute build times relative to "now" so the wrapper's midpoint
            # bisection (sinceUtc = now - DaysBack; midpoint = sinceUtc + DaysBack/2)
            # deterministically places the short builds in the first half and the
            # long builds in the second half. Hardcoded calendar dates drift out of
            # the window as wall-clock time advances.
            $script:NowUtc = (Get-Date).ToUniversalTime()
            $fmt = { param($d) $d.ToString("yyyy-MM-ddTHH:mm:ssZ") }
            $paymentsFirstStart  = & $fmt $script:NowUtc.AddDays(-25)
            $paymentsFirstFinish = & $fmt $script:NowUtc.AddDays(-25).AddMinutes(50)
            $paymentsFirst2Start  = & $fmt $script:NowUtc.AddDays(-23)
            $paymentsFirst2Finish = & $fmt $script:NowUtc.AddDays(-23).AddMinutes(40)
            $paymentsSecondStart  = & $fmt $script:NowUtc.AddDays(-5)
            $paymentsSecondFinish = & $fmt $script:NowUtc.AddDays(-5).AddMinutes(80)
            $paymentsSecond2Start  = & $fmt $script:NowUtc.AddDays(-3)
            $paymentsSecond2Finish = & $fmt $script:NowUtc.AddDays(-3).AddMinutes(70)
            $identityStart  = & $fmt $script:NowUtc.AddDays(-22)
            $identityFinish = & $fmt $script:NowUtc.AddDays(-22).AddMinutes(15)
            $identity2Start  = & $fmt $script:NowUtc.AddDays(-21)
            $identity2Finish = & $fmt $script:NowUtc.AddDays(-21).AddMinutes(12)

            $paymentsBuilds = @"
{"value":[
  {"id":1,"startTime":"$paymentsFirstStart","finishTime":"$paymentsFirstFinish","result":"failed"},
  {"id":2,"startTime":"$paymentsFirst2Start","finishTime":"$paymentsFirst2Finish","result":"succeeded"},
  {"id":3,"startTime":"$paymentsSecondStart","finishTime":"$paymentsSecondFinish","result":"failed"},
  {"id":4,"startTime":"$paymentsSecond2Start","finishTime":"$paymentsSecond2Finish","result":"succeeded"}
]}
"@
            $identityBuilds = @"
{"value":[
  {"id":10,"startTime":"$identityStart","finishTime":"$identityFinish","result":"succeeded"},
  {"id":11,"startTime":"$identity2Start","finishTime":"$identity2Finish","result":"succeeded"}
]}
"@

            Mock Invoke-WebRequest {
                if ($Uri -match '_apis/projects') {
                    return [PSCustomObject]@{
                        Content = '{"value":[{"name":"payments"},{"name":"identity"}]}'
                        Headers = @{}
                    }
                }
                if ($Uri -match 'payments/_apis/build/builds') {
                    return [PSCustomObject]@{ Content = $paymentsBuilds; Headers = @{} }
                }
                if ($Uri -match 'identity/_apis/build/builds') {
                    return [PSCustomObject]@{ Content = $identityBuilds; Headers = @{} }
                }
                throw "Unexpected URI: $Uri"
            }
            $result = & $script:Wrapper -AdoOrg 'contoso' -DaysBack 30
        }

        AfterAll {
            Remove-Item Env:\ADO_PAT_TOKEN -ErrorAction SilentlyContinue
        }

        It 'returns Success' {
            $result.Status | Should -Be 'Success'
        }

        It 'flags high share project' {
            @($result.Findings | Where-Object { $_.RuleId -eq 'Consumption-MinuteShareHigh' }).Count | Should -BeGreaterThan 0
        }

        It 'flags duration regression' {
            @($result.Findings | Where-Object { $_.RuleId -eq 'Consumption-DurationRegression' }).Count | Should -BeGreaterThan 0
        }

        It 'flags failed pipeline rate above threshold' {
            @($result.Findings | Where-Object { $_.RuleId -eq 'Consumption-FailRateHigh' }).Count | Should -BeGreaterThan 0
        }

        It 'emits schema 2.2 metadata on findings' {
            $share = $result.Findings | Where-Object RuleId -eq 'Consumption-MinuteShareHigh' | Select-Object -First 1
            $fail = $result.Findings | Where-Object RuleId -eq 'Consumption-FailRateHigh' | Select-Object -First 1

            $share.Pillar | Should -Be 'Cost Optimization'
            $share.Impact | Should -Not -BeNullOrEmpty
            $share.Effort | Should -Be 'Low'
            $share.DeepLinkUrl | Should -Match '_a=analytics'
            @($share.EvidenceUris).Count | Should -BeGreaterThan 0
            $share.BaselineTags | Should -Contain 'Consumption-MinuteShareHigh'
            @($share.EntityRefs | Where-Object { $_ -like 'AdoProject/*' }).Count | Should -Be 1
            $share.PSObject.Properties.Name | Should -Contain 'ToolVersion'
            $fail.Pillar | Should -Be 'Operational Excellence'
        }
    }

    Context 'retry and sanitization' {
        BeforeAll {
            $env:ADO_PAT_TOKEN = 'fake-token'
            $global:ProjectsAttempts = 0
            Mock Invoke-WebRequest {
                if ($Uri -match '_apis/projects') {
                    $global:ProjectsAttempts++
                    if ($global:ProjectsAttempts -eq 1) {
                        throw (New-TestHttpException -StatusCode 429 -Message 'Authorization: Basic c2VjcmV0')
                    }
                    return [PSCustomObject]@{ Content = '{"value":[]}'; Headers = @{} }
                }
                throw "Unexpected URI: $Uri"
            }
            $result = & $script:Wrapper -AdoOrg 'contoso'
        }

        AfterAll {
            Remove-Item Env:\ADO_PAT_TOKEN -ErrorAction SilentlyContinue
        }

        It 'retries after throttle and succeeds' {
            $result.Status | Should -Be 'Success'
            $global:ProjectsAttempts | Should -Be 2
        }

        It 'does not leak PAT markers in message' {
            $result.Message | Should -Not -Match 'Basic c2VjcmV0'
        }
    }
}
