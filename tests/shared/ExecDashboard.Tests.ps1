Describe 'ExecDashboard' {
    BeforeAll {
        $script:RootDir = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
        . (Join-Path $RootDir 'modules' 'shared' 'RunHistory.ps1')

        function NewFinding {
            param($Source, $Rid, $Sev, $Cat = 'Security', $Compliant = $false)
            [pscustomobject]@{
                Source     = $Source
                ResourceId = $Rid
                Category   = $Cat
                Title      = "T-$Rid-$Cat"
                Severity   = $Sev
                Compliant  = $Compliant
            }
        }
    }

    It 'generates a self-contained dashboard.html with trend sparklines from 3+ historical runs' {
        $tmp = Join-Path $TestDrive 'dashboard-3runs'
        $null = New-Item -ItemType Directory -Path $tmp -Force
        $resultsPath = Join-Path $tmp 'results.json'

        $sub = '11111111-1111-1111-1111-111111111111'
        $rows1 = @(
            NewFinding 'azqr'   "/subscriptions/$sub/rg/a/storage/x" 'Critical'
            NewFinding 'azqr'   "/subscriptions/$sub/rg/a/storage/y" 'High'
            NewFinding 'psrule' "/subscriptions/$sub/rg/a/keyvault/z" 'Medium'
        )
        $rows2 = @(
            NewFinding 'azqr'   "/subscriptions/$sub/rg/a/storage/x" 'Critical'
            NewFinding 'psrule' "/subscriptions/$sub/rg/a/keyvault/z" 'Medium'
            NewFinding 'gitleaks' "/subscriptions/$sub/rg/b/repo/r" 'High' 'Secrets'
        )
        $rows3 = @(
            NewFinding 'psrule' "/subscriptions/$sub/rg/a/keyvault/z" 'Medium'
            NewFinding 'gitleaks' "/subscriptions/$sub/rg/b/repo/r" 'High' 'Secrets'
            NewFinding 'azqr'   "/subscriptions/$sub/rg/a/storage/x" 'Critical' 'Security' $true
        )

        # Snapshot 3 historical runs.
        $rows1 | ConvertTo-Json -Depth 5 | Set-Content -Path $resultsPath -Encoding UTF8
        $null = Save-RunSnapshot -OutputPath $tmp -ResultsPath $resultsPath -Timestamp ([datetime]'2025-01-01T00:00:00Z')
        $rows2 | ConvertTo-Json -Depth 5 | Set-Content -Path $resultsPath -Encoding UTF8
        $null = Save-RunSnapshot -OutputPath $tmp -ResultsPath $resultsPath -Timestamp ([datetime]'2025-01-02T00:00:00Z')
        $rows3 | ConvertTo-Json -Depth 5 | Set-Content -Path $resultsPath -Encoding UTF8
        $null = Save-RunSnapshot -OutputPath $tmp -ResultsPath $resultsPath -Timestamp ([datetime]'2025-01-03T00:00:00Z')

        $output = Join-Path $tmp 'dashboard.html'
        & (Join-Path $RootDir 'New-ExecDashboard.ps1') -InputPath $resultsPath -OutputPath $output | Out-Null

        Test-Path $output | Should -BeTrue
        $html = Get-Content $output -Raw

        # Self-contained: no external <script src> or <link href> with http(s)
        $html | Should -Not -Match '<script\s+src="https?:'
        $html | Should -Not -Match '<link\s+[^>]*href="https?:'

        # Sparkline svg present
        $html | Should -Match '<svg[^>]*viewBox'
        # Severity labels
        $html | Should -Match 'Critical'
        $html | Should -Match 'High'
        # Compliance score block
        $html | Should -Match 'Compliance score'
        # Top-10 risky resources table
        $html | Should -Match 'Top-10 risky resources'
        # WAF 5-pillar header
        $html | Should -Match 'WAF 5-pillar coverage'
        # MTTR table
        $html | Should -Match 'MTTR by severity'
        # Subscription heat map renders the sub guid prefix
        $html | Should -Match '11111111'
    }

    It 'still produces a dashboard with no history (single run, "first run" path)' {
        $tmp = Join-Path $TestDrive 'dashboard-norun'
        $null = New-Item -ItemType Directory -Path $tmp -Force
        $resultsPath = Join-Path $tmp 'results.json'
        '[]' | Set-Content -Path $resultsPath -Encoding UTF8

        $output = Join-Path $tmp 'dashboard.html'
        & (Join-Path $RootDir 'New-ExecDashboard.ps1') -InputPath $resultsPath -OutputPath $output | Out-Null

        Test-Path $output | Should -BeTrue
        $html = Get-Content $output -Raw
        $html | Should -Match 'first run|first snapshot|insufficient'
    }

    It 'renders a dashboard when every finding is Critical (edge case)' {
        $tmp = Join-Path $TestDrive 'dashboard-only-crit'
        $null = New-Item -ItemType Directory -Path $tmp -Force
        $resultsPath = Join-Path $tmp 'results.json'
        $sub = '22222222-2222-2222-2222-222222222222'
        $rows = @(
            NewFinding 'azqr' "/subscriptions/$sub/rg/a/x" 'Critical'
            NewFinding 'azqr' "/subscriptions/$sub/rg/a/y" 'Critical'
        )
        $rows | ConvertTo-Json -Depth 5 | Set-Content -Path $resultsPath -Encoding UTF8

        $output = Join-Path $tmp 'dashboard.html'
        & (Join-Path $RootDir 'New-ExecDashboard.ps1') -InputPath $resultsPath -OutputPath $output | Out-Null

        $html = Get-Content $output -Raw
        $html | Should -Match 'sev-critical'
        # The injection-shaped severity test separately proves the CSS class is whitelisted;
        # here we just confirm the dashboard renders cleanly with an all-Critical input.
        $html | Should -Match 'Compliance score'
    }

    It 'renders a dashboard when every finding is Info (low-risk-only edge case)' {
        $tmp = Join-Path $TestDrive 'dashboard-only-info'
        $null = New-Item -ItemType Directory -Path $tmp -Force
        $resultsPath = Join-Path $tmp 'results.json'
        $sub = '33333333-3333-3333-3333-333333333333'
        $rows = @(
            NewFinding 'azqr' "/subscriptions/$sub/rg/a/x" 'Info'
            NewFinding 'azqr' "/subscriptions/$sub/rg/a/y" 'Info'
        )
        $rows | ConvertTo-Json -Depth 5 | Set-Content -Path $resultsPath -Encoding UTF8

        $output = Join-Path $tmp 'dashboard.html'
        & (Join-Path $RootDir 'New-ExecDashboard.ps1') -InputPath $resultsPath -OutputPath $output | Out-Null

        $html = Get-Content $output -Raw
        $html | Should -Match 'sev-info'
        $html | Should -Match 'Compliance score'
    }

    It 'whitelist-normalizes unknown / injection-shaped severity into sev-info (CSS-class safety)' {
        $tmp = Join-Path $TestDrive 'dashboard-inject'
        $null = New-Item -ItemType Directory -Path $tmp -Force
        $resultsPath = Join-Path $tmp 'results.json'
        $sub = '44444444-4444-4444-4444-444444444444'
        # Severity contains a quote / class-break attempt - dashboard must NOT interpolate it.
        $rows = @(
            [pscustomobject]@{
                Source     = 'evil'
                ResourceId = "/subscriptions/$sub/rg/x/y"
                Category   = 'Security'
                Title      = 'tool-injected severity'
                Severity   = 'High"><script>alert(1)</script>'
                Compliant  = $false
            }
        )
        $rows | ConvertTo-Json -Depth 5 | Set-Content -Path $resultsPath -Encoding UTF8

        $output = Join-Path $tmp 'dashboard.html'
        & (Join-Path $RootDir 'New-ExecDashboard.ps1') -InputPath $resultsPath -OutputPath $output | Out-Null

        $html = Get-Content $output -Raw
        $html | Should -Not -Match '<script>alert\(1\)</script>'
        $html | Should -Match 'sev-info'
        # HTML-escaped severity text is rendered but the CSS class is whitelisted.
        $html | Should -Match 'sev sev-info'
    }

    It 'header timestamp is genuine UTC (not local time mislabeled)' {
        $tmp = Join-Path $TestDrive 'dashboard-utc'
        $null = New-Item -ItemType Directory -Path $tmp -Force
        $resultsPath = Join-Path $tmp 'results.json'
        '[]' | Set-Content -Path $resultsPath -Encoding UTF8

        # Window the dashboard render in true UTC min/max and assert the header
        # timestamp falls inside [min, max]. Gives the clock up to 2 minutes of drift
        # so a minute-boundary transition during the test does not flake.
        $before = (Get-Date).ToUniversalTime()
        $output = Join-Path $tmp 'dashboard.html'
        & (Join-Path $RootDir 'New-ExecDashboard.ps1') -InputPath $resultsPath -OutputPath $output | Out-Null
        $after = (Get-Date).ToUniversalTime()

        $html = Get-Content $output -Raw
        if ($html -notmatch '(\d{4}-\d{2}-\d{2} \d{2}:\d{2}) UTC') {
            throw "Expected header timestamp in 'YYYY-MM-DD HH:MM UTC' form; got none."
        }
        $rendered = [datetime]::ParseExact(
            $Matches[1], 'yyyy-MM-dd HH:mm',
            [System.Globalization.CultureInfo]::InvariantCulture)
        $rendered = [datetime]::SpecifyKind($rendered, [System.DateTimeKind]::Utc)

        $windowStart = $before.AddMinutes(-1)
        $windowEnd   = $after.AddMinutes(1)
        ($rendered -ge $windowStart) | Should -BeTrue -Because "rendered=$($rendered.ToString('o')) start=$($windowStart.ToString('o'))"
        ($rendered -le $windowEnd)   | Should -BeTrue -Because "rendered=$($rendered.ToString('o')) end=$($windowEnd.ToString('o'))"
    }

    It 'top-10 risky resources are ordered by finding count descending (AC #97)' {
        $tmp = Join-Path $TestDrive 'dashboard-top10-order'
        $null = New-Item -ItemType Directory -Path $tmp -Force
        $resultsPath = Join-Path $tmp 'results.json'
        $sub = '55555555-5555-5555-5555-555555555555'
        # LOW-severity resource gets 5 findings (highest count, lowest severity).
        # CRITICAL-severity resource gets 1 finding (lowest count, highest severity).
        # AC says count-descending, so LOW must appear BEFORE CRITICAL in the top-10.
        $rows = @(
            NewFinding 'azqr' "/subscriptions/$sub/rg/a/many" 'Low' 'Cat1'
            NewFinding 'azqr' "/subscriptions/$sub/rg/a/many" 'Low' 'Cat2'
            NewFinding 'azqr' "/subscriptions/$sub/rg/a/many" 'Low' 'Cat3'
            NewFinding 'azqr' "/subscriptions/$sub/rg/a/many" 'Low' 'Cat4'
            NewFinding 'azqr' "/subscriptions/$sub/rg/a/many" 'Low' 'Cat5'
            NewFinding 'azqr' "/subscriptions/$sub/rg/a/one"  'Critical' 'Cat1'
        )
        $rows | ConvertTo-Json -Depth 5 | Set-Content -Path $resultsPath -Encoding UTF8
        $output = Join-Path $tmp 'dashboard.html'
        & (Join-Path $RootDir 'New-ExecDashboard.ps1') -InputPath $resultsPath -OutputPath $output | Out-Null

        $html = Get-Content $output -Raw
        $manyIdx = $html.IndexOf('/rg/a/many')
        $oneIdx  = $html.IndexOf('/rg/a/one')
        $manyIdx | Should -BeGreaterThan -1
        $oneIdx  | Should -BeGreaterThan -1
        ($manyIdx -lt $oneIdx) | Should -BeTrue -Because "high-count resource must render before high-severity/low-count resource"
    }

    It 'WAF tiles render coverage %% and a trend arrow vs the previous run (AC #97)' {
        $tmp = Join-Path $TestDrive 'dashboard-waf-trend'
        $null = New-Item -ItemType Directory -Path $tmp -Force
        $resultsPath = Join-Path $tmp 'results.json'
        $sub = '66666666-6666-6666-6666-666666666666'

        # Prior run: 2 findings, both non-compliant (low coverage)
        $prev = @(
            NewFinding 'azqr' "/subscriptions/$sub/rg/a/x" 'Critical'
            NewFinding 'azqr' "/subscriptions/$sub/rg/a/y" 'High'
        )
        $prev | ConvertTo-Json -Depth 5 | Set-Content -Path $resultsPath -Encoding UTF8
        $null = Save-RunSnapshot -OutputPath $tmp -ResultsPath $resultsPath -Timestamp ([datetime]'2025-02-01T00:00:00Z')

        # Current run: same resources but now compliant (coverage improved)
        $curr = @(
            NewFinding 'azqr' "/subscriptions/$sub/rg/a/x" 'Critical' 'Security' $true
            NewFinding 'azqr' "/subscriptions/$sub/rg/a/y" 'High'     'Security' $true
        )
        $curr | ConvertTo-Json -Depth 5 | Set-Content -Path $resultsPath -Encoding UTF8

        $output = Join-Path $tmp 'dashboard.html'
        & (Join-Path $RootDir 'New-ExecDashboard.ps1') -InputPath $resultsPath -OutputPath $output | Out-Null

        $html = Get-Content $output -Raw
        # Coverage percent renders
        $html | Should -Match 'waf-num[^>]*>\s*\d+(\.\d+)?%'
        # At least one trend glyph rendered (↑ because prior was lower coverage)
        $html | Should -Match 'waf-trend'
        ($html -match '↑|↓|→') | Should -BeTrue
    }

    It 'severity trend sparklines are labeled as non-compliant (risk over time)' {
        $tmp = Join-Path $TestDrive 'dashboard-trend-label'
        $null = New-Item -ItemType Directory -Path $tmp -Force
        $resultsPath = Join-Path $tmp 'results.json'
        '[]' | Set-Content -Path $resultsPath -Encoding UTF8
        $output = Join-Path $tmp 'dashboard.html'
        & (Join-Path $RootDir 'New-ExecDashboard.ps1') -InputPath $resultsPath -OutputPath $output | Out-Null

        $html = Get-Content $output -Raw
        $html | Should -Match 'Non-compliant findings only'
    }
}
