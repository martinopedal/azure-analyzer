#Requires -Version 7.4
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:Cases = @(
    @{
        Name            = 'trivy'
        WrapperRelativePath = 'modules/Invoke-Trivy.ps1'
        WrapperArgs     = @{}
        ExpectedSource  = 'trivy'
        WarningContains = 'trivy is not installed'
        MessageContains = 'trivy CLI not installed'
    },
    @{
        Name            = 'kubescape'
        WrapperRelativePath = 'modules/Invoke-Kubescape.ps1'
        WrapperArgs     = @{ SubscriptionId = '00000000-0000-0000-0000-000000000000' }
        ExpectedSource  = 'kubescape'
        WarningContains = 'kubescape is not installed'
        MessageContains = 'kubescape CLI not installed'
    },
    @{
        Name            = 'scorecard'
        WrapperRelativePath = 'modules/Invoke-Scorecard.ps1'
        WrapperArgs     = @{ Repository = 'github.com/example/repo' }
        ExpectedSource  = 'scorecard'
        WarningContains = 'scorecard is not installed'
        MessageContains = 'scorecard CLI not installed'
    }
)

BeforeAll {
    $script:RepoRoot = (Resolve-Path (Join-Path (Split-Path $PSCommandPath -Parent) '..' '..')).Path
    . (Join-Path $script:RepoRoot 'modules' 'shared' 'MissingToolTestHarness.ps1')
}

Describe 'Wrapper runtime missing-tool integration' {
    It '<Name> emits missing-tool notice and clean skipped v1 envelope with MissingTool diagnostic' -ForEach $script:Cases {
        $wrapperPath = Join-Path $script:RepoRoot $WrapperRelativePath
        $run = Invoke-WrapperWithoutTool -WrapperPath $wrapperPath -ToolName $Name -WrapperArguments $WrapperArgs

        $run.ExitCode | Should -Be 0
        $run.StdOut | Should -Not -Match '(?i)(stack trace|at .+\.ps1:\d+|terminating error|exception:)'
        $run.StdErr | Should -Not -Match '(?i)(stack trace|at .+\.ps1:\d+|terminating error|exception:)'

        @($run.Warnings).Count | Should -BeGreaterThan 0
        (@($run.Warnings) -join "`n") | Should -Match ([regex]::Escape($WarningContains))

        $run.Envelope | Should -Not -BeNullOrEmpty
        $run.Envelope.SchemaVersion | Should -Be '1.0'
        $run.Envelope.Source | Should -Be $ExpectedSource
        $run.Envelope.Status | Should -Be 'Skipped'
        $run.Envelope.Message | Should -Match ([regex]::Escape($MessageContains))
        @($run.Envelope.Findings).Count | Should -Be 0

        $diagnostics = @($run.Envelope.Diagnostics)
        $diagnostics.Count | Should -BeGreaterThan 0
        $missingToolDiagnostic = @($diagnostics | Where-Object { $_.Code -eq 'MissingTool' -and $_.Tool -eq $Name })[0]
        $missingToolDiagnostic | Should -Not -BeNullOrEmpty
    }
}
