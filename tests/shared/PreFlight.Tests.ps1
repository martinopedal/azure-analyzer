#Requires -Version 7.0
#Requires -Modules Pester

<#
    Pre-flight scaffold tests (#426).

    Every Describe block is intentionally marked -Skip. Full coverage lands
    once Foundation PR #435 merges and PreFlight.ps1 gets a real implementation.
    Keeping the file (and the Skip markers) in tree means Pester picks the
    suites up the moment the implementation lands, with zero discovery work.
#>

BeforeAll {
    $script:PreFlightPath = Join-Path $PSScriptRoot '..\..\modules\shared\PreFlight.ps1'
}

Describe 'PreFlight scaffold module is present' {
    It 'ships PreFlight.ps1 alongside the other shared modules' {
        Test-Path $script:PreFlightPath | Should -BeTrue
    }
}

Describe 'Get-RequiredInputsFromManifest' -Skip {
    It 'returns the union of required_inputs across the supplied tool list' {
        $true | Should -BeTrue
    }

    It 'deduplicates inputs that share a name across multiple tools' {
        $true | Should -BeTrue
    }

    It 'honours conditional gating expressions' {
        $true | Should -BeTrue
    }
}

Describe 'Resolve-PreFlightInputs' -Skip {
    It 'prefers CLI args over env vars over prompts' {
        $true | Should -BeTrue
    }

    It 'falls back to env var when CLI arg is absent' {
        $true | Should -BeTrue
    }

    It 'aggregates unresolved inputs into a single error in non-interactive mode' {
        $true | Should -BeTrue
    }

    It 'never prompts for tokens or PATs in plaintext' {
        $true | Should -BeTrue
    }

    It 'applies the per-input validator regex' {
        $true | Should -BeTrue
    }
}

Describe 'Test-NonInteractiveSession' -Skip {
    It 'returns true when stdin is redirected' {
        $true | Should -BeTrue
    }

    It 'returns true when -NonInteractive is passed to the orchestrator' {
        $true | Should -BeTrue
    }

    It 'returns true when CI env var is set' {
        $true | Should -BeTrue
    }

    It 'returns false in a normal interactive shell' {
        $true | Should -BeTrue
    }
}
