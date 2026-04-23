#Requires -Modules Pester

BeforeAll {
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
    $script:WorkflowPath = [IO.Path]::Combine($script:RepoRoot, '.github', 'workflows', 'markdown-check.yml')
    $script:LintConfigPath = [IO.Path]::Combine($script:RepoRoot, '.markdownlint-cli2.jsonc')
    $script:LycheeConfigPath = [IO.Path]::Combine($script:RepoRoot, '.lychee.toml')
    $script:LegacyWorkflowPath = [IO.Path]::Combine($script:RepoRoot, '.github', 'workflows', 'markdown-link-check.yml')
    $script:WorkflowText = if (Test-Path $script:WorkflowPath) { Get-Content $script:WorkflowPath -Raw } else { '' }
    $script:LintConfigText = if (Test-Path $script:LintConfigPath) { Get-Content $script:LintConfigPath -Raw } else { '' }
    $script:LycheeConfigText = if (Test-Path $script:LycheeConfigPath) { Get-Content $script:LycheeConfigPath -Raw } else { '' }
}

Describe 'markdown-check workflow shape' {
    It 'workflow file exists' {
        Test-Path $script:WorkflowPath | Should -BeTrue
    }

    It 'legacy markdown-link-check.yml has been removed' {
        Test-Path $script:LegacyWorkflowPath | Should -BeFalse
    }

    It 'declares all three jobs (lint, links, em-dash)' {
        $script:WorkflowText | Should -Match '(?m)^\s{2}lint:\s*$'
        $script:WorkflowText | Should -Match '(?m)^\s{2}links:\s*$'
        $script:WorkflowText | Should -Match '(?m)^\s{2}em-dash:\s*$'
    }

    It 'declares concurrency with cancel-in-progress' {
        $script:WorkflowText | Should -Match 'concurrency:'
        $script:WorkflowText | Should -Match 'cancel-in-progress:\s*true'
        $script:WorkflowText | Should -Match 'group:\s*markdown-check-'
    }

    It 'restricts permissions to contents: read' {
        $script:WorkflowText | Should -Match 'permissions:\s*\r?\n\s*contents:\s*read'
    }

    It 'SHA-pins every uses: directive (40-char hex)' {
        $usesLines = $script:WorkflowText -split "`n" | Where-Object { $_ -match 'uses:\s*\S+@' }
        $usesLines | Should -Not -BeNullOrEmpty
        foreach ($line in $usesLines) {
            $line | Should -Match 'uses:\s*[^@\s]+@[0-9a-f]{40}'
        }
    }
}

Describe 'lychee retry + cache configuration' {
    It '.lychee.toml exists' {
        Test-Path $script:LycheeConfigPath | Should -BeTrue
    }

    It 'enables persistent cache with 7d max age' {
        $script:LycheeConfigText | Should -Match '(?m)^\s*cache\s*=\s*true\s*$'
        $script:LycheeConfigText | Should -Match '(?m)^\s*max_cache_age\s*=\s*"7d"\s*$'
    }

    It 'retries at least 3 times with backoff' {
        if ($script:LycheeConfigText -match '(?m)^\s*max_retries\s*=\s*(\d+)') {
            [int]$Matches[1] | Should -BeGreaterOrEqual 3
        } else {
            throw 'max_retries not configured'
        }
    }

    It 'accepts 429 (rate-limited) as success' {
        $script:LycheeConfigText | Should -Match '"429"'
    }

    It 'excludes ephemeral squad-inbox paths' {
        $script:LycheeConfigText | Should -Match '\.squad/decisions/inbox/'
    }

    It 'workflow invokes lychee with --cache' {
        $script:WorkflowText | Should -Match '--cache'
    }

    It 'workflow scopes lychee to changed markdown on pull requests' {
        $script:WorkflowText | Should -Match 'Resolve markdown scope for lychee'
        $script:WorkflowText | Should -Match 'id:\s*lychee-scope'
        $script:WorkflowText | Should -Match 'if \[ "\$EVENT_NAME" = "pull_request" \]'
        $script:WorkflowText | Should -Match 'git diff --name-only --diff-filter=ACMR'
    }

    It 'workflow scans full markdown corpus for non-PR events' {
        $script:WorkflowText | Should -Match "git ls-files '\*\*/\*\.md'"
    }

    It 'workflow wraps lychee in nick-fields/retry' {
        $script:WorkflowText | Should -Match 'nick-fields/retry@[0-9a-f]{40}'
    }

    It 'workflow clears lychee cache between retry attempts' {
        $script:WorkflowText | Should -Match 'on_retry_command:\s*rm -rf \.lycheecache'
    }

    It 'workflow passes GitHub token to lychee for GitHub URL reliability' {
        $script:WorkflowText | Should -Match 'GITHUB_TOKEN:\s*\$\{\{\s*github\.token\s*\}\}'
        $script:WorkflowText | Should -Match '--github-token\s+"\$GITHUB_TOKEN"'
    }

    It 'workflow skips lychee run when markdown scope is empty' {
        $script:WorkflowText | Should -Match "if:\s*steps\.lychee-scope\.outputs\.has_targets == 'true'"
    }
}

Describe 'em-dash policy gate' {
    It 'has an Em-dash gate step' {
        $script:WorkflowText | Should -Match 'name:\s*Em-dash gate'
    }

    It 'uses ripgrep (rg)' {
        $script:WorkflowText | Should -Match '\brg\s+-n\b'
    }

    It 'is restricted to added lines on pull_request events' {
        $script:WorkflowText | Should -Match "if:\s*github\.event_name\s*==\s*'pull_request'"
        $script:WorkflowText | Should -Match 'git diff --unified=0'
    }

    It 'matches both U+2014 (em dash) and U+2013 (en dash)' {
        $script:WorkflowText | Should -Match 'u2014'
        $script:WorkflowText | Should -Match 'u2013'
    }

    It 'excludes ephemeral agent-state markdown paths from PR scan scope' {
        $script:WorkflowText | Should -Match ':\(exclude\)\.copilot/audits/\*\*'
        $script:WorkflowText | Should -Match ':\(exclude\)\.copilot/status/\*\*'
        $script:WorkflowText | Should -Match ':\(exclude\)\.copilot/session-state/\*\*'
        $script:WorkflowText | Should -Match ':\(exclude\)\.squad/decisions/inbox/\*\*'
        $script:WorkflowText | Should -Match ':\(exclude\)\.atlas-stash/\*\*'
    }

    It 'has an advisory backlog scan for non-PR events' {
        $script:WorkflowText | Should -Match "if:\s*github\.event_name\s*!=\s*'pull_request'"
        $script:WorkflowText | Should -Match 'Em-dash backlog'
    }
}

Describe 'markdownlint-cli2 ignore list' {
    It '.markdownlint-cli2.jsonc exists' {
        Test-Path $script:LintConfigPath | Should -BeTrue
    }

    It 'is valid JSON (after stripping // and /* */ comments)' {
        $stripped = $script:LintConfigText -replace '(?m)//[^\r\n]*', '' -replace '/\*[\s\S]*?\*/', ''
        { $stripped | ConvertFrom-Json -ErrorAction Stop } | Should -Not -Throw
    }

    It 'ignores auto-generated permissions docs' {
        $script:LintConfigText | Should -Match 'docs/reference/permissions/'
        $script:LintConfigText | Should -Match 'docs/consumer/permissions/'
    }

    It 'ignores auto-generated tool-catalog docs' {
        $script:LintConfigText | Should -Match 'docs/reference/tool-catalog\*\.md'
    }

    It 'ignores ephemeral agent trees (.copilot/, .squad/, .atlas-stash/)' {
        $script:LintConfigText | Should -Match '\.copilot/\*\*'
        $script:LintConfigText | Should -Match '\.squad/\*\*'
        $script:LintConfigText | Should -Match '\.atlas-stash/'
    }

    It 'ignores node_modules and output directories' {
        $script:LintConfigText | Should -Match 'node_modules/'
        $script:LintConfigText | Should -Match 'output/'
    }

    It 'disables cosmetic rules that drown signal (MD022/MD031/MD032/MD060)' {
        $script:LintConfigText | Should -Match '"MD022":\s*false'
        $script:LintConfigText | Should -Match '"MD031":\s*false'
        $script:LintConfigText | Should -Match '"MD032":\s*false'
        $script:LintConfigText | Should -Match '"MD060":\s*false'
    }
}
