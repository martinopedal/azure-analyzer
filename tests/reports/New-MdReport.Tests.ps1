#Requires -Version 7.4

Describe 'Markdown report generator alignment' {
    BeforeAll {
        $script:RootDir = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
        $script:MdReport = Join-Path $RootDir 'New-MdReport.ps1'
    }

    It 'renders section order, badge row, and heat map glyph legend' {
        $tmp = Join-Path $TestDrive 'md-structure'
        $null = New-Item -ItemType Directory -Path $tmp -Force
        $resultsPath = Join-Path $tmp 'results.json'
        $outputPath = Join-Path $tmp 'report.md'

        @(
            [pscustomobject]@{
                Id = 'f-1'; Source = 'azqr'; Category = 'Identity'; Title = 'Owner without PIM'; RuleId = 'MCSB.IM-1'
                Severity = 'Critical'; Compliant = $false; Detail = 'detail'; Remediation = 'fix'
                ResourceId = '/subscriptions/sub-a/resourceGroups/rg/providers/Microsoft.KeyVault/vaults/kv1'
                EntityId = 'user/a@contoso.com'; SubscriptionId = 'sub-a'; ToolVersion = '2.0.0'
                Frameworks = @([pscustomobject]@{ Name = 'CIS' }); Pillar = 'Identity & access'
            }
            [pscustomobject]@{
                Id = 'f-2'; Source = 'scorecard'; Category = 'Supply chain'; Title = 'Unpinned action'; RuleId = 'OSSF.PIN'
                Severity = 'High'; Compliant = $false; Detail = 'detail'; Remediation = 'fix'
                ResourceId = '/subscriptions/sub-b/resourceGroups/rg/providers/Microsoft.Web/sites/app1'
                EntityId = 'repo/contoso/app'; SubscriptionId = 'sub-b'; ToolVersion = '4.13.1'
            }
        ) | ConvertTo-Json -Depth 8 | Set-Content -Path $resultsPath -Encoding UTF8

        & $MdReport -InputPath $resultsPath -OutputPath $outputPath | Out-Null
        $md = Get-Content -Path $outputPath -Raw

        $md | Should -Match '!\[Critical\]'
        $md | Should -Match '!\[Posture\]'
        $md | Should -Match '!\[Tools\]'
        $md | Should -Match 'Legend: 🔴 Critical, 🟠 High, 🟡 Medium, 🟢 Low, ⚪ Info'

        $order = @(
            '## Executive summary',
            '## Tool coverage',
            '## Heat map',
            '## Top 10 risks',
            '## Findings (top 30)',
            '## Entity inventory',
            '## Run details'
        )
        $positions = @($order | ForEach-Object { $md.IndexOf($_) })
        foreach ($p in $positions) { $p | Should -BeGreaterThan -1 }
        for ($i = 1; $i -lt $positions.Count; $i++) {
            $positions[$i] | Should -BeGreaterThan $positions[$i - 1]
        }
    }

    It 'caps findings table at 30 rows' {
        $tmp = Join-Path $TestDrive 'md-top30'
        $null = New-Item -ItemType Directory -Path $tmp -Force
        $resultsPath = Join-Path $tmp 'results.json'
        $outputPath = Join-Path $tmp 'report.md'

        $findings = 1..35 | ForEach-Object {
            [pscustomobject]@{
                Id = "f-$_"; Source = 'azqr'; Category = 'Network security'; Title = "Rule $_"; RuleId = "AZR.$_"
                Severity = if ($_ -le 2) { 'Critical' } elseif ($_ -le 10) { 'High' } else { 'Medium' }
                Compliant = $false; Detail = 'detail'; Remediation = 'fix'
                ResourceId = "/subscriptions/sub-x/resourceGroups/rg/providers/Microsoft.Network/networkSecurityGroups/nsg$_"
                EntityId = "entity/$_"; SubscriptionId = 'sub-x'
            }
        }
        $findings | ConvertTo-Json -Depth 8 | Set-Content -Path $resultsPath -Encoding UTF8

        & $MdReport -InputPath $resultsPath -OutputPath $outputPath | Out-Null
        $md = Get-Content -Path $outputPath -Raw

        $topRows = @(
            ($md -split "`r?`n") |
                Where-Object { $_ -match '^\| \d+ \| .+\| `AZR\.' }
        )
        $topRows.Count | Should -Be 30
        $md | Should -Match '\[interactive HTML report\]\(report\.html\)'
    }

    It 'renders tool versions details block and avoids em dash characters' {
        $tmp = Join-Path $TestDrive 'md-details'
        $null = New-Item -ItemType Directory -Path $tmp -Force
        $resultsPath = Join-Path $tmp 'results.json'
        $outputPath = Join-Path $tmp 'report.md'

        @(
            [pscustomobject]@{
                Id = 'f-1'; Source = 'azqr'; Category = 'Security'; Title = 'Storage secure transfer disabled'
                Severity = 'High'; Compliant = $false; Detail = 'detail'; Remediation = 'fix'
                ResourceId = '/subscriptions/sub-z/resourceGroups/rg/providers/Microsoft.Storage/storageAccounts/st1'
                EntityId = 'res/st1'; ToolVersion = '2.6.1'
                Frameworks = @('CIS')
            }
        ) | ConvertTo-Json -Depth 8 | Set-Content -Path $resultsPath -Encoding UTF8

        & $MdReport -InputPath $resultsPath -OutputPath $outputPath | Out-Null
        $md = Get-Content -Path $outputPath -Raw

        $md | Should -Match '<summary>Tool versions</summary>'
        $md | Should -Match '\| azqr \| 2\.6\.1 \| azure \|'
        $md.Contains([char]0x2014) | Should -BeFalse
    }
}
