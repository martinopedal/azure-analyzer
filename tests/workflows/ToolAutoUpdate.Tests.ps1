Describe 'Update-ToolPins.ps1 / manifest upstream metadata' {
    BeforeAll {
        $script:ManifestPath = Join-Path $PSScriptRoot '..' '..' 'tools' 'tool-manifest.json'
        $script:ScriptPath   = Join-Path $PSScriptRoot '..' '..' 'tools' 'Update-ToolPins.ps1'
        $script:Manifest     = Get-Content $script:ManifestPath -Raw | ConvertFrom-Json
    }

    It 'driver script exists and parses' {
        Test-Path $script:ScriptPath | Should -BeTrue
        { [System.Management.Automation.Language.Parser]::ParseFile(
            $script:ScriptPath, [ref]$null, [ref]$null) } | Should -Not -Throw
    }

    It 'every tool with an external upstream has an upstream block with required fields' {
        $externalTools = @('azqr','psrule','azgovviz','alz-queries','wara','maester','scorecard','zizmor','gitleaks','trivy')
        foreach ($name in $externalTools) {
            $t = $script:Manifest.tools | Where-Object { $_.name -eq $name }
            $t          | Should -Not -BeNullOrEmpty -Because "tool $name must exist"
            $t.upstream | Should -Not -BeNullOrEmpty -Because "$name needs upstream metadata"
            $t.upstream.repo        | Should -Not -BeNullOrEmpty
            $t.upstream.releaseApi  | Should -Match '^https://api\.github\.com/'
            $t.upstream.pinType     | Should -BeIn @('semver','cli-version','psmodule-version','sha')
            $t.upstream.currentPin  | Should -Not -BeNullOrEmpty
        }
    }

    It 'custom in-repo tools do NOT declare upstream' {
        foreach ($name in 'ado-connections','identity-correlator') {
            $t = $script:Manifest.tools | Where-Object { $_.name -eq $name }
            $t.PSObject.Properties.Name | Should -Not -Contain 'upstream'
        }
    }

    It 'weekly workflow is SHA-pinned and triggers on schedule + dispatch' {
        $wf = Get-Content (Join-Path $PSScriptRoot '..' '..' '.github' 'workflows' 'tool-auto-update.yml') -Raw
        $wf | Should -Match 'cron:'
        $wf | Should -Match 'workflow_dispatch'
        $wf | Should -Match 'actions/checkout@[a-f0-9]{40}'
    }
}
