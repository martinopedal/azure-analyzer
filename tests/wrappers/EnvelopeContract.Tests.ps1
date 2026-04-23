# EnvelopeContract.Tests.ps1
#
# Per-wrapper envelope contract enforcement (issue #907).
# Validates that New-WrapperEnvelope is available in every wrapper and
# that each wrapper calls it on at least one error/skip path.

BeforeAll {
    $script:SharedRoot  = Join-Path $PSScriptRoot '..' '..' 'modules' 'shared'
    $script:WrapperRoot = Join-Path $PSScriptRoot '..' '..' 'modules'

    . (Join-Path $script:SharedRoot 'New-WrapperEnvelope.ps1')
}

Describe 'New-WrapperEnvelope helper' {

    It 'returns a PSCustomObject with all required v1 fields' {
        $env = New-WrapperEnvelope -Source 'test-tool'
        $env | Should -Not -BeNullOrEmpty
        $env.Source        | Should -Be 'test-tool'
        $env.SchemaVersion | Should -Be '1.0'
        $env.Status        | Should -Be 'Failed'
        $env.Message       | Should -Be ''
        $env.Findings      | Should -HaveCount 0
        $env.Errors        | Should -HaveCount 0
    }

    It 'accepts Status parameter' {
        $env = New-WrapperEnvelope -Source 'x' -Status 'Skipped' -Message 'not available'
        $env.Status  | Should -Be 'Skipped'
        $env.Message | Should -Be 'not available'
    }

    It 'accepts FindingErrors parameter' {
        $err = [PSCustomObject]@{ Source='wrapper:x'; Category='MissingDependency'; Reason='not found'; Remediation='install it' }
        $env = New-WrapperEnvelope -Source 'x' -FindingErrors @($err)
        $env.Errors.Count | Should -Be 1
        $env.Errors[0].Category | Should -Be 'MissingDependency'
    }

    It 'Findings is always non-null' {
        $env = New-WrapperEnvelope -Source 'x'
        $null -ne $env.Findings | Should -BeTrue
    }

    It 'Errors is always non-null when no FindingErrors passed' {
        $env = New-WrapperEnvelope -Source 'x'
        $null -ne $env.Errors | Should -BeTrue
    }
}

Describe 'Per-wrapper envelope contract' {

    BeforeDiscovery {
        $script:WrapperRoot = Join-Path $PSScriptRoot '..' '..' 'modules'
        $script:WrapperFiles = @(
            Get-ChildItem -Path $script:WrapperRoot -Filter 'Invoke-*.ps1' -File |
                Sort-Object Name
        )
        $script:WrapperNames = $script:WrapperFiles | ForEach-Object { $_.Name }
    }

    BeforeAll {
        $script:WrapperRoot = Join-Path $PSScriptRoot '..' '..' 'modules'
    }

    Context 'Envelope infrastructure present in <_>' -ForEach $script:WrapperNames {
        It 'dot-sources or stubs New-WrapperEnvelope' {
            $path = Join-Path $script:WrapperRoot $_
            $text = Get-Content -LiteralPath $path -Raw
            $hasDotSource = $text -match 'New-WrapperEnvelope\.ps1'
            $hasStub      = $text -match 'function New-WrapperEnvelope'
            ($hasDotSource -or $hasStub) | Should -BeTrue -Because "$_ must import or define New-WrapperEnvelope"
        }

        It 'has a fallback stub for New-WrapperEnvelope' {
            $path = Join-Path $script:WrapperRoot $_
            $text = Get-Content -LiteralPath $path -Raw
            $text | Should -Match 'function New-WrapperEnvelope' -Because "$_ must have a fallback stub"
        }

        It 'uses New-WrapperEnvelope on at least one error/skip path' {
            $path = Join-Path $script:WrapperRoot $_
            $text = Get-Content -LiteralPath $path -Raw
            $callCount = ([regex]::Matches($text, 'New-WrapperEnvelope\s+-Source')).Count
            $callCount | Should -BeGreaterThan 0 -Because "$_ must call New-WrapperEnvelope on at least one error/skip path"
        }
    }
}
