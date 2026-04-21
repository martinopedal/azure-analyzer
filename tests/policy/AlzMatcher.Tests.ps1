# AlzMatcher.Tests.ps1
# Track C scaffold (#431). Pester placeholders. All tests -Skip until catalog ingestion lands.
# See docs/design/alz-scoring-algorithm.md for the worked examples that drive these cases.

Describe 'AlzMatcher (#431 scaffold)' -Tag 'policy','scaffold' {

    Context 'Worked Example A: canonical ALZ tenant' {
        It 'scores >= 0.80 and activates Full' -Skip {
            # Hierarchy: Root / Platform{Mgmt,Connectivity,Identity} / Landing Zones{Corp,Online} / Decommissioned / Sandbox
            # Expected: score ~0.96, decision Full.
            $true | Should -BeTrue
        }
    }

    Context 'Worked Example B: renamed ALZ tenant' {
        It 'scores in [0.50, 0.79] and activates Partial' -Skip {
            # Hierarchy: TenantRoot / Core{Mgmt,Network,IAM} / Workloads{Internal,External} / Decom / Dev
            # Expected: score in partial band, decision Partial.
            $true | Should -BeTrue
        }
    }

    Context 'Worked Example C: non-ALZ flat tenant' {
        It 'scores < 0.50 and falls back to AzAdvertizer only' -Skip {
            # Hierarchy: Root / ProductionSubs / DevSubs / DataSubs / LegacySubs
            # Expected: score ~0.23, decision Fallback.
            $true | Should -BeTrue
        }
    }

    Context 'CLI flag -AlzReferenceMode' {
        It 'Off mode skips computation entirely' -Skip {
            $true | Should -BeTrue
        }
        It 'Force mode activates regardless of score' -Skip {
            $true | Should -BeTrue
        }
    }
}
