#requires -Version 7.0
#requires -Modules Pester

Describe 'Track E LLM triage scaffold (#433)' {

    Context 'Trio selection by tier' {
        It 'picks the top three Pro-tier models by capability rank' -Skip {
            # Phase 2: assert Select-TriageTrio against a fixture roster.
        }

        It 'picks the top three Business-tier models with provider diversity tie-break' -Skip {
            # Phase 2.
        }

        It 'picks the top three Enterprise-tier models' -Skip {
            # Phase 2.
        }
    }

    Context 'Explicit model gating' {
        It 'refuses an explicit model that is not in the user tier roster' -Skip {
            # Phase 2: -TriageModel Explicit:<id> must validate against tier roster.
        }
    }

    Context 'Single-model fallback' {
        It 'warns the user when -SingleModel is used to opt out of rubberduck' -Skip {
            # Phase 2: assert stderr / Write-Warning emission.
        }
    }

    Context 'Fewer than three available models' {
        It 'refuses by default when the tier exposes fewer than three models' -Skip {
            # Phase 2.
        }

        It 'falls back to single-model mode when -SingleModel is also set, with warning' -Skip {
            # Phase 2.
        }
    }

    Context 'Tier discovery' {
        It 'requires explicit -CopilotTier when gh copilot status is unsupported' -Skip {
            # Phase 2: never silent fallback.
        }
    }
}
