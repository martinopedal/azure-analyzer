#Requires -Version 7.4

BeforeAll {
    $repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..')
    . (Join-Path $repoRoot 'modules\shared\Sanitize.ps1')
    . (Join-Path $repoRoot 'modules\shared\Canonicalize.ps1')
    . (Join-Path $repoRoot 'modules\shared\Schema.ps1')
    . (Join-Path $repoRoot 'modules\normalizers\Normalize-IdentityGraphExpansion.ps1')
}

Describe 'Normalize-IdentityGraphExpansion' {
    It 'returns empty when status is not Success' {
        $r = Normalize-IdentityGraphExpansion -ToolResult ([PSCustomObject]@{ Status = 'Failed'; Findings = @() })
        @($r).Count | Should -Be 0
    }

    It 'passes through valid findings with canonicalised EntityId' {
        $finding = New-FindingRow `
            -Id ([guid]::NewGuid().ToString()) -Source 'identity-graph-expansion' `
            -EntityId 'objectId:11111111-2222-3333-4444-555555555555' -EntityType 'User' `
            -Title 'Dormant guest' -Compliant $false -ProvenanceRunId ([guid]::NewGuid().ToString()) `
            -Severity 'Low' -Category 'B2B Guest Hygiene'
        $tr = [PSCustomObject]@{ Status = 'Success'; Findings = @($finding) }
        $out = @(Normalize-IdentityGraphExpansion -ToolResult $tr)
        $out.Count | Should -Be 1
        $out[0].EntityId | Should -Be 'objectId:11111111-2222-3333-4444-555555555555'
    }

    It 'coerces unknown severities to Info AND emits a warning (#187 F4)' {
        $finding = New-FindingRow `
            -Id ([guid]::NewGuid().ToString()) -Source 'identity-graph-expansion' `
            -EntityId 'objectId:11111111-2222-3333-4444-555555555555' -EntityType 'User' `
            -Title 'X' -Compliant $true -ProvenanceRunId ([guid]::NewGuid().ToString()) `
            -Severity 'Info'
        $finding.Severity = 'Bogus'
        $tr = [PSCustomObject]@{ Status = 'Success'; Findings = @($finding) }
        $out = @(Normalize-IdentityGraphExpansion -ToolResult $tr -WarningVariable warn -WarningAction SilentlyContinue)
        $out[0].Severity | Should -Be 'Info'
        $warn.Count | Should -BeGreaterThan 0
        ($warn -join ' ') | Should -Match "unknown severity 'Bogus'"
        ($warn -join ' ') | Should -Match 'identity-graph-expansion'
    }

    It 'coerces unknown severities to Info' {
        $finding = New-FindingRow `
            -Id ([guid]::NewGuid().ToString()) -Source 'identity-graph-expansion' `
            -EntityId 'objectId:11111111-2222-3333-4444-555555555555' -EntityType 'User' `
            -Title 'X' -Compliant $true -ProvenanceRunId ([guid]::NewGuid().ToString()) `
            -Severity 'Info'
        $finding.Severity = 'Bogus'
        $tr = [PSCustomObject]@{ Status = 'Success'; Findings = @($finding) }
        $out = @(Normalize-IdentityGraphExpansion -ToolResult $tr)
        $out[0].Severity | Should -Be 'Info'
    }

    It 'handles all five canonical severity levels' {
        foreach ($sev in @('Critical','High','Medium','Low','Info')) {
            $f = New-FindingRow `
                -Id ([guid]::NewGuid().ToString()) -Source 'identity-graph-expansion' `
                -EntityId 'objectId:11111111-2222-3333-4444-555555555555' -EntityType 'User' `
                -Title "T-$sev" -Compliant $false -ProvenanceRunId ([guid]::NewGuid().ToString()) `
                -Severity $sev
            $tr = [PSCustomObject]@{ Status = 'Success'; Findings = @($f) }
            $out = @(Normalize-IdentityGraphExpansion -ToolResult $tr)
            $out[0].Severity | Should -Be $sev
        }
    }
}

