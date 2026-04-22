# Convention test: every job in .github/workflows/*.yml must declare timeout-minutes
#
# Background: GitHub Actions defaults the per-job timeout to 6 hours. A stuck job
# (network hang, infinite retry loop, deadlocked process) burns the entire budget
# before failing. Declaring an explicit timeout-minutes per job bounds the blast
# radius and lets the scheduler reclaim the runner.
#
# Halberd contract (PR for issue #511): every job must declare timeout-minutes.
# Reusable workflow callers and matrix jobs both count.

Describe 'Workflow job timeout-minutes contract' {

    BeforeDiscovery {
        $script:WorkflowDir = Join-Path $PSScriptRoot '..' '..' '.github' 'workflows'
        $script:WorkflowDir = (Resolve-Path $script:WorkflowDir).Path

        $script:WorkflowFiles = Get-ChildItem -Path $script:WorkflowDir -Filter '*.yml' |
            ForEach-Object { @{ Path = $_.FullName; Name = $_.Name } }
    }

    It 'declares timeout-minutes on every job in <Name>' -ForEach $script:WorkflowFiles {

        param($Path, $Name)

        $lines = Get-Content -Path $Path

        # Locate the `jobs:` block, then enumerate top-level job keys (2-space
        # indent, no leading `#`, ends with `:`). For each job, scan forward
        # until the next job key or end-of-file and assert that one of those
        # lines matches `^    timeout-minutes:`.
        $jobsIdx = -1
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -match '^jobs:\s*$') { $jobsIdx = $i; break }
        }
        $jobsIdx | Should -BeGreaterOrEqual 0 -Because "$Name must declare a jobs: block"

        $jobStarts = @()
        for ($i = $jobsIdx + 1; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -match '^[a-zA-Z]') { break }  # next top-level key
            if ($lines[$i] -match '^  ([a-zA-Z][\w-]*):\s*$') {
                $jobStarts += @{ Index = $i; Name = $matches[1] }
            }
        }

        $jobStarts.Count | Should -BeGreaterThan 0 -Because "$Name must declare at least one job"

        $missing = @()
        for ($k = 0; $k -lt $jobStarts.Count; $k++) {
            $start = $jobStarts[$k].Index
            $end = if ($k -lt $jobStarts.Count - 1) { $jobStarts[$k + 1].Index } else { $lines.Count }
            $body = $lines[($start + 1)..($end - 1)]
            $hasTimeout = $body | Where-Object { $_ -match '^    timeout-minutes:\s*\d+' }
            if (-not $hasTimeout) {
                $missing += $jobStarts[$k].Name
            }
        }

        $missing | Should -BeNullOrEmpty -Because "every job in $Name must declare timeout-minutes (missing: $($missing -join ', '))"
    }
}
