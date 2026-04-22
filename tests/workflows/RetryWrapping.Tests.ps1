# Auto-retry contract for .github/workflows/*.yml
#
# Repo directive 2026-04-22T23:26:00Z: every step that performs network I/O
# must either be wrapped with `nick-fields/retry@<sha>` so transient failures
# self-heal, or carry an explicit `# no-retry: <reason>` comment justifying
# the opt-out (typically: non-idempotent side effect, or step has its own
# internal retry / try-catch resilience).
#
# Two assertions per workflow file:
#   1. Every step whose `run:` block contains a deny-listed network pattern
#      is either wrapped by `nick-fields/retry` OR carries `# no-retry:`.
#   2. Every third-party `uses:` reference is SHA-pinned (40-char hex).
#
# Workflows owned by other agents are excluded:
#   - markdown-link-check.yml  (Forge)
#   - ci-failure-watchdog.yml  (Forge)

Describe 'Workflow auto-retry contract' {

    BeforeDiscovery {
        $script:WorkflowDir = Join-Path $PSScriptRoot '..' '..' '.github' 'workflows'
        $script:WorkflowDir = (Resolve-Path $script:WorkflowDir).Path

        $script:ExcludedWorkflows = @(
            'markdown-link-check.yml',
            'ci-failure-watchdog.yml'
        )

        $script:WorkflowFiles = Get-ChildItem -Path $script:WorkflowDir -Filter '*.yml' |
            Where-Object { $script:ExcludedWorkflows -notcontains $_.Name } |
            ForEach-Object { @{ Path = $_.FullName; Name = $_.Name } }

        # Network-I/O deny list. A line containing one of these patterns inside
        # a step's `run:` block triggers the retry-or-justify requirement.
        $script:DenyPatterns = @(
            'Invoke-WebRequest',
            'Invoke-RestMethod',
            'Install-Module',
            '\bgh\s+api\b',
            '\bgh\s+issue\b',
            '\bgh\s+pr\b',
            '\bgh\s+run\b',
            '\bgh\s+release\b',
            '\bgh\s+repo\b',
            '\bgh\s+label\b',
            '\bgit\s+clone\b',
            '\bnpm\s+install\b',
            '\bpip\s+install\b',
            '\bwinget\s+install\b',
            '\bcurl\s',
            '\bwget\s',
            '\bapt-get\b',
            '\baz\s+bicep\b',
            '\baz\s+login\b'
        )

        $script:RetryAction = 'nick-fields/retry@'
        $script:NoRetryMarker = '# no-retry:'
    }

    Context 'Network-I/O steps must be retry-wrapped or explicitly opted out' {

        It 'wraps every network step in <Name> with nick-fields/retry or marks it # no-retry' -ForEach $script:WorkflowFiles {
            param($Path, $Name)

            $lines = Get-Content -Path $Path

            # A "step start" is a line of the form `    - name:` or `    - uses:`
            # or `    - run:` or `    - id:` -- a YAML sequence item directly
            # under `steps:`. We track step ranges by scanning for those.
            $stepStarts = New-Object System.Collections.Generic.List[int]
            for ($i = 0; $i -lt $lines.Count; $i++) {
                if ($lines[$i] -match '^(\s+)-\s+(name|uses|run|id):\s') {
                    $stepStarts.Add($i)
                }
            }

            $offenders = New-Object System.Collections.Generic.List[string]

            for ($s = 0; $s -lt $stepStarts.Count; $s++) {
                $start = $stepStarts[$s]
                $end = if ($s -lt $stepStarts.Count - 1) { $stepStarts[$s + 1] - 1 } else { $lines.Count - 1 }
                $stepText = ($lines[$start..$end] -join "`n")

                # Locate the `run:` block within the step (if any). We only flag
                # deny-listed patterns that appear inside a run block, not inside
                # `script:` (github-script JS) or other action `with:` parameters.
                $runBlock = $null
                $runStart = -1
                for ($j = $start; $j -le $end; $j++) {
                    if ($lines[$j] -match '^\s+run:\s*\|?\s*$' -or $lines[$j] -match '^\s+run:\s+\S') {
                        $runStart = $j
                        break
                    }
                }
                if ($runStart -ge 0) {
                    $runBlock = ($lines[$runStart..$end] -join "`n")
                }

                $hasDenyHit = $false
                if ($runBlock) {
                    foreach ($pattern in $script:DenyPatterns) {
                        if ($runBlock -match $pattern) {
                            $hasDenyHit = $true
                            break
                        }
                    }
                }

                if (-not $hasDenyHit) { continue }

                $isWrapped = $stepText -match [regex]::Escape($script:RetryAction)
                $hasOptOut = $stepText -match [regex]::Escape($script:NoRetryMarker)

                if (-not ($isWrapped -or $hasOptOut)) {
                    $stepName = if ($lines[$start] -match 'name:\s*(.+?)\s*$') { $matches[1] } else { "(line $($start + 1))" }
                    $offenders.Add("step '$stepName' at line $($start + 1)")
                }
            }

            $offenders | Should -BeNullOrEmpty -Because "every network step in $Name must be wrapped with $($script:RetryAction)<sha> or carry a '# no-retry: <reason>' comment"
        }
    }

    Context 'Third-party actions must be SHA-pinned' {

        It 'pins every uses: reference in <Name> to a 40-char SHA' -ForEach $script:WorkflowFiles {
            param($Path, $Name)

            $lines = Get-Content -Path $Path
            $offenders = New-Object System.Collections.Generic.List[string]

            for ($i = 0; $i -lt $lines.Count; $i++) {
                $line = $lines[$i]
                if ($line -match '^\s+(?:-\s+)?uses:\s*([^\s#]+)') {
                    $ref = $matches[1]
                    if ($ref.StartsWith('./') -or $ref.StartsWith('.\')) { continue }
                    if ($ref -notmatch '@([0-9a-f]{40})$') {
                        $offenders.Add("line $($i + 1): $ref")
                    }
                }
            }

            $offenders | Should -BeNullOrEmpty -Because "every third-party action in $Name must be SHA-pinned (@<40-char-hex>); tags like @v1 or @main are forbidden"
        }
    }
}
