#Requires -Version 7.4
Set-StrictMode -Version Latest

BeforeAll {
    $repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..')
    . (Join-Path $repoRoot 'modules\shared\Suppression.ps1')
}

Describe 'Suppression' {

    Context 'Get-FindingKey: stability' {
        It 'is identical across runs even though the finding Id differs' {
            # 37 of 38 normalizers fall back to [guid]::NewGuid() for the
            # finding Id, so Id is unique per run and cannot be the key.
            $a = [pscustomobject]@{ Source = 'wara'; RuleId = 'r1'; Title = 'T'; EntityId = '/subscriptions/aaa/rg/x'; Id = [guid]::NewGuid().ToString() }
            $b = [pscustomobject]@{ Source = 'wara'; RuleId = 'r1'; Title = 'T'; EntityId = '/subscriptions/aaa/rg/x'; Id = [guid]::NewGuid().ToString() }
            (Get-FindingKey -Finding $a) | Should -Be (Get-FindingKey -Finding $b)
        }

        It 'ignores casing drift in the entity id' {
            $a = [pscustomobject]@{ Source = 'wara'; RuleId = 'r1'; Title = 'T'; EntityId = '/subscriptions/AAA/RG/X' }
            $b = [pscustomobject]@{ Source = 'wara'; RuleId = 'r1'; Title = 'T'; EntityId = '/subscriptions/aaa/rg/x' }
            (Get-FindingKey -Finding $a) | Should -Be (Get-FindingKey -Finding $b)
        }

        It 'produces a 16-character lowercase hex key' {
            $f = [pscustomobject]@{ Source = 'wara'; RuleId = 'r1'; Title = 'T'; EntityId = '/subscriptions/aaa/rg/x' }
            Get-FindingKey -Finding $f | Should -Match '^[0-9a-f]{16}$'
        }

        It 'distinguishes different rules on the same entity' {
            $a = [pscustomobject]@{ Source = 'wara'; RuleId = 'r1'; Title = 'T'; EntityId = '/subscriptions/aaa/rg/x' }
            $b = [pscustomobject]@{ Source = 'wara'; RuleId = 'r2'; Title = 'T'; EntityId = '/subscriptions/aaa/rg/x' }
            (Get-FindingKey -Finding $a) | Should -Not -Be (Get-FindingKey -Finding $b)
        }

        It 'distinguishes the same rule on different entities' {
            $a = [pscustomobject]@{ Source = 'wara'; RuleId = 'r1'; Title = 'T'; EntityId = '/subscriptions/aaa/rg/x' }
            $b = [pscustomobject]@{ Source = 'wara'; RuleId = 'r1'; Title = 'T'; EntityId = '/subscriptions/aaa/rg/y' }
            (Get-FindingKey -Finding $a) | Should -Not -Be (Get-FindingKey -Finding $b)
        }

        It 'distinguishes the same rule id reported by different tools' {
            $a = [pscustomobject]@{ Source = 'wara'; RuleId = 'r1'; Title = 'T'; EntityId = '/subscriptions/aaa/rg/x' }
            $b = [pscustomobject]@{ Source = 'psrule'; RuleId = 'r1'; Title = 'T'; EntityId = '/subscriptions/aaa/rg/x' }
            (Get-FindingKey -Finding $a) | Should -Not -Be (Get-FindingKey -Finding $b)
        }

        It 'falls back to Title when RuleId is empty' {
            # 11 of 38 normalizers never populate RuleId, WARA among them.
            $f = [pscustomobject]@{ Source = 'wara'; RuleId = ''; Title = 'Use availability zones'; EntityId = '/subscriptions/aaa/rg/x' }
            Get-FindingKey -Finding $f | Should -Match '^[0-9a-f]{16}$'
        }

        It 'returns empty when identity is incomplete rather than a colliding key' {
            (Get-FindingKey -Finding ([pscustomobject]@{ Source = ''; RuleId = 'r'; Title = 'T'; EntityId = 'e' })) | Should -Be ''
            (Get-FindingKey -Finding ([pscustomobject]@{ Source = 's'; RuleId = 'r'; Title = 'T'; EntityId = '' })) | Should -Be ''
            (Get-FindingKey -Finding ([pscustomobject]@{ Source = 's'; RuleId = ''; Title = ''; EntityId = 'e' })) | Should -Be ''
        }

        It 'matches the hash computed from an explicit source/rule/entity triple' {
            # Hand-authored entries must resolve to the same key as live
            # findings, or they would silently never match.
            $f = [pscustomobject]@{ Source = 'wara'; RuleId = 'r1'; Title = 'T'; EntityId = '/subscriptions/aaa/rg/x' }
            (Get-FindingKey -Finding $f) | Should -Be (Get-SuppressionHash -Source 'wara' -Rule 'r1' -Entity '/subscriptions/aaa/rg/x')
        }
    }

    Context 'Import-SuppressionList' {
        BeforeEach {
            $script:listPath = Join-Path $TestDrive 'suppressions.json'
        }

        It 'loads key-form and triple-form entries' {
            @{ schemaVersion = '1.0'; suppressions = @(
                    @{ key = '0123456789abcdef'; reason = 'Accepted' },
                    @{ source = 'wara'; ruleId = 'r1'; entityId = '/subscriptions/aaa/rg/x'; reason = 'False positive' }
                ) } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $script:listPath
            $list = Import-SuppressionList -Path $script:listPath
            $list.Errors.Count | Should -Be 0
            $list.Entries.Count | Should -Be 2
            $list.Entries.ContainsKey((Get-SuppressionHash -Source 'wara' -Rule 'r1' -Entity '/subscriptions/aaa/rg/x')) | Should -BeTrue
        }

        It 'rejects an entry with no reason' {
            @{ suppressions = @(@{ key = '0123456789abcdef' }) } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $script:listPath
            $list = Import-SuppressionList -Path $script:listPath
            $list.Errors -join ' ' | Should -Match "missing a 'reason'"
            $list.Entries.Count | Should -Be 0
        }

        It 'rejects a malformed key' {
            @{ suppressions = @(@{ key = 'not-a-key'; reason = 'x' }) } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $script:listPath
            $list = Import-SuppressionList -Path $script:listPath
            $list.Errors -join ' ' | Should -Match 'not a 16-character hex'
        }

        It 'ignores and reports an expired entry rather than applying it' {
            @{ suppressions = @(@{ key = '0123456789abcdef'; reason = 'temp'; expires = '2020-01-01' }) } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $script:listPath
            $list = Import-SuppressionList -Path $script:listPath
            $list.Entries.Count | Should -Be 0
            $list.Expired.Count | Should -Be 1
            $list.Errors.Count | Should -Be 0
        }

        It 'keeps an entry whose expiry is still in the future' {
            @{ suppressions = @(@{ key = '0123456789abcdef'; reason = 'temp'; expires = '2999-01-01' }) } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $script:listPath
            $list = Import-SuppressionList -Path $script:listPath
            $list.Entries.Count | Should -Be 1
        }

        It 'rejects an unparseable expiry instead of treating it as absent' {
            @{ suppressions = @(@{ key = '0123456789abcdef'; reason = 'temp'; expires = 'soon' }) } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $script:listPath
            $list = Import-SuppressionList -Path $script:listPath
            $list.Errors -join ' ' | Should -Match 'unparseable'
            $list.Entries.Count | Should -Be 0
        }

        It 'reports a missing file' {
            $list = Import-SuppressionList -Path (Join-Path $TestDrive 'nope.json')
            $list.Errors -join ' ' | Should -Match 'not found'
        }

        It 'reports invalid JSON' {
            Set-Content -LiteralPath $script:listPath -Value '{ not json'
            $list = Import-SuppressionList -Path $script:listPath
            $list.Errors -join ' ' | Should -Match 'not valid JSON'
        }

        It 'reports an empty file' {
            Set-Content -LiteralPath $script:listPath -Value ''
            $list = Import-SuppressionList -Path $script:listPath
            $list.Errors -join ' ' | Should -Match 'empty'
        }

        It 'tolerates a bare array, which is the obvious thing to hand-write' {
            ,@(@{ key = '0123456789abcdef'; reason = 'Accepted' }) | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $script:listPath
            $list = Import-SuppressionList -Path $script:listPath
            $list.Errors.Count | Should -Be 0
            $list.Entries.Count | Should -Be 1
        }

        It 'collects every malformed entry in one pass instead of stopping at the first' {
            @{ suppressions = @(
                    @{ key = 'bad1' ; reason = 'x' },
                    @{ key = 'bad2' ; reason = 'y' },
                    @{ key = '0123456789abcdef'; reason = 'good' }
                ) } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $script:listPath
            $list = Import-SuppressionList -Path $script:listPath
            $list.Errors.Count | Should -Be 2
        }
    }

    Context 'Set-FindingSuppression' {
        It 'marks matching findings and leaves the rest alone' {
            $findings = @(
                [pscustomobject]@{ Source = 'wara'; RuleId = 'r1'; Title = 'T1'; EntityId = '/subscriptions/aaa/rg/x' },
                [pscustomobject]@{ Source = 'wara'; RuleId = 'r2'; Title = 'T2'; EntityId = '/subscriptions/aaa/rg/y' }
            )
            $key = Get-FindingKey -Finding $findings[0]
            $entries = @{ $key = [pscustomobject]@{ Key = $key; Reason = 'Accepted risk' } }
            $summary = Set-FindingSuppression -Findings $findings -Entries $entries
            $summary.Total | Should -Be 2
            $summary.Suppressed | Should -Be 1
            $findings[0].Suppressed | Should -BeTrue
            $findings[0].SuppressionReason | Should -Be 'Accepted risk'
            $findings[1].Suppressed | Should -BeFalse
        }

        It 'retains suppressed findings rather than dropping them' {
            $findings = @([pscustomobject]@{ Source = 'wara'; RuleId = 'r1'; Title = 'T1'; EntityId = '/subscriptions/aaa/rg/x' })
            $key = Get-FindingKey -Finding $findings[0]
            $null = Set-FindingSuppression -Findings $findings -Entries @{ $key = [pscustomobject]@{ Key = $key; Reason = 'x' } }
            $findings.Count | Should -Be 1
        }

        It 'stamps FindingKey on every finding, matched or not' {
            $findings = @(
                [pscustomobject]@{ Source = 'wara'; RuleId = 'r1'; Title = 'T1'; EntityId = '/subscriptions/aaa/rg/x' },
                [pscustomobject]@{ Source = 'wara'; RuleId = 'r2'; Title = 'T2'; EntityId = '/subscriptions/aaa/rg/y' }
            )
            $null = Set-FindingSuppression -Findings $findings -Entries @{}
            $findings[0].FindingKey | Should -Match '^[0-9a-f]{16}$'
            $findings[1].FindingKey | Should -Match '^[0-9a-f]{16}$'
        }

        It 'reports suppression keys that matched nothing' {
            $findings = @([pscustomobject]@{ Source = 'wara'; RuleId = 'r1'; Title = 'T1'; EntityId = '/subscriptions/aaa/rg/x' })
            $summary = Set-FindingSuppression -Findings $findings -Entries @{ 'ffffffffffffffff' = [pscustomobject]@{ Key = 'ffffffffffffffff'; Reason = 'stale' } }
            $summary.UnusedKeys.Count | Should -Be 1
        }

        It 'handles an empty finding set without throwing' {
            $summary = Set-FindingSuppression -Findings @() -Entries @{}
            $summary.Total | Should -Be 0
            $summary.Suppressed | Should -Be 0
        }

        It 'is idempotent when applied twice' {
            $findings = @([pscustomobject]@{ Source = 'wara'; RuleId = 'r1'; Title = 'T1'; EntityId = '/subscriptions/aaa/rg/x' })
            $key = Get-FindingKey -Finding $findings[0]
            $entries = @{ $key = [pscustomobject]@{ Key = $key; Reason = 'x' } }
            $null = Set-FindingSuppression -Findings $findings -Entries $entries
            $second = Set-FindingSuppression -Findings $findings -Entries $entries
            $second.Suppressed | Should -Be 1
            $findings[0].Suppressed | Should -BeTrue
        }
    }
}