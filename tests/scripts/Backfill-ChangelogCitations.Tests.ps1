BeforeAll {
    $scriptPath = Join-Path $PSScriptRoot '..\..\scripts\Backfill-ChangelogCitations.ps1'
}

Describe 'Backfill-ChangelogCitations' {

    Context 'Idempotency — already-cited PRs are not duplicated' {
        It 'produces no changes when every PR is already cited' {
            # Build a minimal CHANGELOG that already cites #42
            $tmpDir  = Join-Path $PSScriptRoot '..\..\output-test'
            if (-not (Test-Path $tmpDir)) { New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null }
            $tmpFile = Join-Path $tmpDir 'CHANGELOG-idem.md'

            @(
                '## [1.0.0](https://github.com/martinopedal/azure-analyzer/compare/v0.0.1...v1.0.0) (2026-04-23)'
                ''
                '### Features'
                ''
                '* add widget ([#42](https://github.com/martinopedal/azure-analyzer/issues/42)) ([abc1234](https://github.com/martinopedal/azure-analyzer/commit/abc1234))'
                ''
            ) | Set-Content $tmpFile -Encoding UTF8

            $before = Get-Content $tmpFile -Raw

            # Run the script with -WhatIf
            $result = & $scriptPath -ChangelogPath $tmpFile -WhatIf 4>&1 2>&1

            $after = Get-Content $tmpFile -Raw
            $after | Should -BeExactly $before
        }
    }

    Context 'Get-ConventionalType extraction' {
        BeforeAll {
            # Dot-source the script to get inner functions
            # We need to extract the function — use a module scope trick
            $scriptContent = Get-Content $scriptPath -Raw
            # Extract Get-ConventionalType function
            if ($scriptContent -match '(?s)(function Get-ConventionalType \{.+?\n\})') {
                $funcDef = $Matches[1]
                Invoke-Expression $funcDef
            }
        }

        It 'recognizes feat prefix' {
            Get-ConventionalType -Subject 'feat(reports): add filter bar' | Should -Be 'feat'
        }

        It 'recognizes fix prefix' {
            Get-ConventionalType -Subject 'fix(ci): stabilize lychee' | Should -Be 'fix'
        }

        It 'recognizes docs prefix' {
            Get-ConventionalType -Subject 'docs: update README' | Should -Be 'docs'
        }

        It 'recognizes test prefix' {
            Get-ConventionalType -Subject 'test(e2e): add batch coverage' | Should -Be 'test'
        }

        It 'recognizes chore prefix' {
            Get-ConventionalType -Subject 'chore(deps): bump actions' | Should -Be 'chore'
        }

        It 'infers fix from keyword' {
            Get-ConventionalType -Subject 'hotfix concurrency group' | Should -Be 'fix'
        }

        It 'defaults to chore for unknown' {
            Get-ConventionalType -Subject 'Merge branch main into feature' | Should -Be 'chore'
        }
    }

    Context 'Get-SectionHeading mapping' {
        BeforeAll {
            $scriptContent = Get-Content $scriptPath -Raw
            if ($scriptContent -match '(?s)(function Get-SectionHeading \{.+?\n\})') {
                Invoke-Expression $Matches[1]
            }
        }

        It 'maps feat to Features'      { Get-SectionHeading -Type 'feat'     | Should -Be 'Features' }
        It 'maps fix to Fixes'          { Get-SectionHeading -Type 'fix'      | Should -Be 'Fixes' }
        It 'maps docs to Documentation' { Get-SectionHeading -Type 'docs'     | Should -Be 'Documentation' }
        It 'maps ci to CI'              { Get-SectionHeading -Type 'ci'       | Should -Be 'CI' }
        It 'maps test to Tests'         { Get-SectionHeading -Type 'test'     | Should -Be 'Tests' }
        It 'maps refactor to Refactors' { Get-SectionHeading -Type 'refactor' | Should -Be 'Refactors' }
        It 'maps unknown to Chores'     { Get-SectionHeading -Type 'blah'     | Should -Be 'Chores' }
    }

    Context 'Get-CitedPRsPerSection parsing' {
        BeforeAll {
            $scriptContent = Get-Content $scriptPath -Raw
            if ($scriptContent -match '(?s)(function Get-CitedPRsPerSection \{.+?\n\})') {
                Invoke-Expression $Matches[1]
            }
        }

        It 'extracts PR numbers from [#NNN] links' {
            $lines = @(
                '## [1.0.0](url) (2026-04-23)'
                '### Features'
                '* desc ([#42](url)) ([abc](url))'
                '* more ([#99](url)) ([def](url))'
            )
            $result = Get-CitedPRsPerSection -Lines $lines
            $result['1.0.0'] | Should -Contain 42
            $result['1.0.0'] | Should -Contain 99
        }

        It 'extracts PR numbers from bare (#NNN) patterns' {
            $lines = @(
                '## [2.0.0](url) (2026-05-01)'
                '### Fixes'
                '* fix something (#123)'
            )
            $result = Get-CitedPRsPerSection -Lines $lines
            $result['2.0.0'] | Should -Contain 123
        }

        It 'handles Unreleased section' {
            $lines = @(
                '## Unreleased'
                '### Fixed'
                '- fix something (#55)'
                ''
                '## [1.0.0](url) (2026-04-23)'
            )
            $result = Get-CitedPRsPerSection -Lines $lines
            $result['Unreleased'] | Should -Contain 55
        }
    }

    Context 'Format-CitationBullet output' {
        BeforeAll {
            $scriptContent = Get-Content $scriptPath -Raw
            if ($scriptContent -match '(?s)(function Format-CitationBullet \{.+?\n\})') {
                Invoke-Expression $Matches[1]
            }
        }

        It 'generates a well-formed bullet with PR and SHA links' {
            $bullet = Format-CitationBullet `
                -Subject 'feat(reports): add filter bar (#42)' `
                -PRNumbers @(42) `
                -SHA 'abcdef1234567890abcdef1234567890abcdef12' `
                -RepoUrl 'https://github.com/martinopedal/azure-analyzer'

            $bullet | Should -Match '\[#42\]'
            $bullet | Should -Match '\[abcdef1\]'
            $bullet | Should -Match '^\* '
        }
    }
}
