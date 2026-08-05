#Requires -Version 7.4
Set-StrictMode -Version Latest

BeforeAll {
    $repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..' '..')
    $samplesDir = Join-Path $repoRoot 'samples'
    $tempDir = Join-Path $repoRoot 'output-test' 'interactive-report'

    if (Test-Path $tempDir) {
        Remove-Item $tempDir -Recurse -Force
    }
    New-Item -Path $tempDir -ItemType Directory -Force | Out-Null

    $committedFindings = Join-Path $samplesDir 'sample-findings-v2.json'
    $staticHtml  = Join-Path $tempDir 'static.html'
    $interactive = Join-Path $tempDir 'interactive.html'

    & (Join-Path $repoRoot 'New-HtmlReport.ps1') -InputPath $committedFindings -OutputPath $staticHtml   -ErrorAction Stop
    & (Join-Path $repoRoot 'New-HtmlReport.ps1') -InputPath $committedFindings -OutputPath $interactive -Interactive -ErrorAction Stop

    $script:staticContent      = Get-Content $staticHtml   -Raw -Encoding UTF8
    $script:interactiveContent = Get-Content $interactive  -Raw -Encoding UTF8
}

Describe 'interactive HTML report' {
    It 'static mode is byte-identical to committed sample' {
        $committed = (Get-Content (Join-Path $samplesDir 'sample-report-v2-mockup.html') -Raw -Encoding UTF8) `
            -replace '\d{4}-\d{2}-\d{2} \d{2}:\d{2} UTC', 'TIMESTAMP' -replace "`r`n", "`n"
        $fresh = $script:staticContent -replace '\d{4}-\d{2}-\d{2} \d{2}:\d{2} UTC', 'TIMESTAMP' -replace "`r`n", "`n"
        $fresh | Should -BeExactly $committed -Because 'static renderer must not drift'
    }

    It 'interactive mode emits fp-filter toolbar' {
        $script:interactiveContent | Should -Match "id='fpFilter'"
    }

    It 'interactive mode emits FP filter buttons (All / Hide FP / Only FP)' {
        $script:interactiveContent | Should -Match "data-fp='all'"
        $script:interactiveContent | Should -Match "data-fp='hide'"
        $script:interactiveContent | Should -Match "data-fp='only'"
    }

    It 'interactive mode emits Triage column header' {
        $script:interactiveContent | Should -Match "<th>Triage</th>"
    }

    It 'interactive mode emits fp-btn on each finding row' {
        $script:interactiveContent | Should -Match "class='fp-btn btn'"
    }

    It 'interactive mode emits data-fk attributes on finding rows' {
        $script:interactiveContent | Should -Match "data-fk='[0-9a-f]{16}'"
    }

    It 'interactive mode does NOT emit data-fk in static mode' {
        $script:staticContent | Should -Not -Match 'data-fk='
    }

    It 'interactive mode includes localStorage persistence script' {
        $script:interactiveContent | Should -Match "STORE_KEY='aa-triage-v1-'"
        $script:interactiveContent | Should -Match 'localStorage.getItem'
        $script:interactiveContent | Should -Match 'localStorage.setItem'
    }

    It 'interactive mode includes ORIG severity counts in JS' {
        $script:interactiveContent | Should -Match 'const ORIG=\{crit:\d+'
    }

    It 'interactive mode includes export suppression JSON button' {
        $script:interactiveContent | Should -Match "id='exportFpJson'"
    }

    It 'interactive mode includes export CSV button' {
        $script:interactiveContent | Should -Match "id='exportFpCsv'"
    }

    It 'interactive mode includes import JSON file input' {
        $script:interactiveContent | Should -Match "id='importFpJson'"
    }

    It 'interactive mode export JS emits schemaVersion 1.0' {
        $script:interactiveContent | Should -Match "schemaVersion:'1\.0'"
    }

    It 'interactive mode export JS includes reason field' {
        $script:interactiveContent | Should -Match "Marked false-positive in interactive report"
    }

    It 'interactive mode interactive CSS rules are present' {
        $script:interactiveContent | Should -Match 'html\.fp-hide tr\.row\.fp-marked'
        $script:interactiveContent | Should -Match 'html\.fp-only tr\.row:not\(\.fp-marked\)'
    }

    It 'interactive mode expand rows use dynamic colspan' {
        $script:interactiveContent | Should -Match "colspan='7'"
        $script:staticContent     | Should -Not -Match "colspan='7'"
    }
}

AfterAll {
    if (Test-Path $tempDir) {
        Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}