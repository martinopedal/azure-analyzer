#Requires -Version 7.0
<#
Workflow hygiene invariant suite. Locks down four cross-cutting contracts
across every .github/workflows/*.yml so a future edit cannot silently:

  - drop the top-level concurrency block (or the equivalent job-scoped
    concurrency that some workflows pin for fan-out reasons)
  - drop the per-job `timeout-minutes:` guard (default cap 30; a short
    exempt list permits documented long-running jobs up to a hard max of 120)
  - replace a SHA-pinned action reference with a tag-only reference
  - drop the minimal `permissions:` block (C5 hygiene)

Exempt jobs live in $script:JobTimeoutExempt below. Keep that list short
and annotated with the justification.
#>

$WorkflowDir = Join-Path $PSScriptRoot '..' '..' '.github' 'workflows'
$WorkflowDir = (Resolve-Path $WorkflowDir).Path

# Discovery-time enumeration -- must be at script scope so -ForEach can
# expand cases before BeforeAll runs.
$WorkflowCases = Get-ChildItem -Path $WorkflowDir -Filter '*.yml' -File |
    Sort-Object Name |
    ForEach-Object { @{ Name = $_.Name; FullName = $_.FullName } }

Describe 'Workflow hygiene sweep' {

    Context 'every workflow has a concurrency block' {
        It 'top-level or job-scoped concurrency exists in <Name>' -ForEach $WorkflowCases {
            $text = Get-Content -Raw -LiteralPath $FullName
            ($text -match '(?m)^\s*concurrency:') |
                Should -BeTrue -Because "workflow $Name must declare concurrency to prevent redundant runs"
        }
    }

    Context 'every job declares timeout-minutes within cap' {
        It '<Name> has timeout-minutes on every runs-on job' -ForEach $WorkflowCases {
            $defaultCap = 30
            $hardMax    = 120
            # file => @(jobName, ...)  long-running exempt jobs (must still be <= $hardMax)
            $exempt = @{
                # ci.yml::test is the 3-OS Pester matrix (Ubuntu, Windows, macOS) and
                # has historically needed up to 45 min on slower runners. Pre-existed
                # on main before this sweep (added by PR #515).
                'ci.yml'             = @('test')
                # scheduled-scan.yml::scan runs real multi-subscription Azure scans.
                'scheduled-scan.yml' = @('scan')
            }

            $lines = Get-Content -Path $FullName

            # Inline job-block parser (scope-safe for Pester It blocks).
            $jobsIdx = -1
            for ($i = 0; $i -lt $lines.Count; $i++) {
                if ($lines[$i] -match '^jobs:\s*$') { $jobsIdx = $i; break }
            }
            $blocks = @()
            if ($jobsIdx -ge 0) {
                $current = $null
                for ($i = $jobsIdx + 1; $i -lt $lines.Count; $i++) {
                    $line = $lines[$i]
                    if ($line -match '^\S') { break }
                    if ($line -match '^  ([A-Za-z0-9_-]+):\s*$') {
                        if ($null -ne $current) { $blocks += $current }
                        $current = [pscustomobject]@{
                            Name      = $Matches[1]
                            BodyLines = [System.Collections.Generic.List[string]]::new()
                        }
                        continue
                    }
                    if ($null -ne $current) { $current.BodyLines.Add($line) | Out-Null }
                }
                if ($null -ne $current) { $blocks += $current }
            }

            foreach ($block in $blocks) {
                $body = ($block.BodyLines -join "`n")
                if ($body -notmatch '(?m)^\s+runs-on:') { continue }

                if ($body -notmatch '(?m)^\s+timeout-minutes:\s*(\d+)') {
                    throw "Job '$($block.Name)' in $Name has runs-on: but no timeout-minutes."
                }
                $minutes = [int]$Matches[1]

                $cap = $defaultCap
                if ($exempt.ContainsKey($Name) -and ($exempt[$Name] -contains $block.Name)) {
                    $cap = $hardMax
                }

                $minutes | Should -BeGreaterThan 0 -Because "$Name::$($block.Name) timeout must be positive"
                $minutes | Should -BeLessOrEqual $cap -Because "$Name::$($block.Name) timeout=$minutes exceeds cap=$cap"
            }
        }
    }

    Context 'every uses: reference is SHA-pinned' {
        It 'no tag-only action references in <Name>' -ForEach $WorkflowCases {
            $lines = Get-Content -Path $FullName
            foreach ($line in $lines) {
                if ($line -notmatch '(?m)^\s+uses:\s*(\S+)') { continue }
                $ref = $Matches[1].Trim('"', "'")
                if ($ref.StartsWith('./') -or $ref.StartsWith('.\')) { continue }
                if ($ref.StartsWith('docker://')) { continue }
                $ref | Should -Match '@[0-9a-f]{40}$' -Because "uses: '$ref' in $Name must be pinned to a 40-char commit SHA, not a tag"
            }
        }
    }

    Context 'every workflow declares minimal permissions' {
        It '<Name> declares permissions at workflow or job scope' -ForEach $WorkflowCases {
            $text = Get-Content -Raw -LiteralPath $FullName
            ($text -match '(?m)^\s*permissions:') |
                Should -BeTrue -Because "$Name must declare a minimal permissions block (C5 hygiene)"
        }
    }
}
