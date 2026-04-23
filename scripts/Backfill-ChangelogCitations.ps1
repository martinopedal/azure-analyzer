<#
.SYNOPSIS
    Backfill CHANGELOG.md with missing PR citations from git history.

.DESCRIPTION
    Walks git log on the current branch, extracts commit subjects that
    reference PRs via (#NNN) patterns, determines which CHANGELOG version
    section each commit belongs to (by tag date), and appends a citation
    bullet for any PR not already mentioned in that section.

    The script is idempotent: re-running it produces no changes if every
    PR is already cited.

.PARAMETER ChangelogPath
    Path to the CHANGELOG.md file. Defaults to CHANGELOG.md in the repo root.

.PARAMETER RepoUrl
    GitHub repository URL for link generation. Defaults to
    https://github.com/martinopedal/azure-analyzer.

.PARAMETER WhatIf
    When set, prints the diff without writing to disk.

.EXAMPLE
    .\scripts\Backfill-ChangelogCitations.ps1
    .\scripts\Backfill-ChangelogCitations.ps1 -WhatIf
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$ChangelogPath = (Join-Path $PSScriptRoot '..\CHANGELOG.md'),
    [string]$RepoUrl       = 'https://github.com/martinopedal/azure-analyzer'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ── helpers ──────────────────────────────────────────────────────────────

function Get-TagDates {
    <# Returns @{ 'v1.0.0' = [datetime]; ... } for every annotated tag. #>
    $tags = @{}
    $raw = git --no-pager for-each-ref --sort=creatordate `
        --format='%(refname:short)|%(creatordate:iso8601)' refs/tags/ 2>&1
    foreach ($line in $raw) {
        if ($line -match '^([^\|]+)\|(.+)$') {
            $tags[$Matches[1]] = [datetime]::Parse($Matches[2])
        }
    }
    return $tags
}

function Get-CommitsWithPRs {
    <#
    Returns an array of objects:
      @{ SHA; Subject; PRNumbers; AuthorDate }
    Only includes commits whose subject contains (#NNN).
    #>
    $commits = @()
    # Use HEAD (current branch) not --all, to avoid stash/detached refs
    $raw = git --no-pager log --format='%H|%aI|%s' HEAD 2>&1
    foreach ($line in $raw) {
        if ($line -match '^([0-9a-f]{40})\|([^\|]+)\|(.+)$') {
            $sha     = $Matches[1]
            $dateStr = $Matches[2]
            $subject = $Matches[3]

            # Skip git stash entries
            if ($subject -match '^(WIP on |index on |On \w+:)') { continue }

            $prNums = [System.Collections.Generic.List[int]]::new()
            $m = [regex]::Matches($subject, '\(#(\d+)\)')
            foreach ($match in $m) {
                $prNums.Add([int]$match.Groups[1].Value)
            }
            if ($prNums.Count -gt 0) {
                $commits += [PSCustomObject]@{
                    SHA        = $sha
                    Subject    = $subject
                    PRNumbers  = $prNums.ToArray()
                    AuthorDate = [datetime]::Parse($dateStr)
                }
            }
        }
    }
    return $commits
}

function Get-VersionForCommit {
    <#
    Given sorted tag boundaries, returns the version section name a commit
    belongs to.  Tags are expected in chronological order.
    Returns e.g. '1.1.0' or 'Unreleased'.
    #>
    param(
        [datetime]$CommitDate,
        [array]$SortedBoundaries   # @( @{Tag='v1.0.0'; Date=...}, ... )
    )

    if (-not $SortedBoundaries -or $SortedBoundaries.Count -eq 0) {
        return 'Unreleased'
    }

    for ($i = $SortedBoundaries.Count - 1; $i -ge 0; $i--) {
        $b = $SortedBoundaries[$i]
        if ($CommitDate -le $b.Date) {
            return ($b.Tag -replace '^v', '')
        }
    }
    return 'Unreleased'
}

function Get-CitedPRsPerSection {
    <#
    Parses CHANGELOG.md and returns a hashtable:
      @{ '1.1.1' = @(831, 778, ...); 'Unreleased' = @(...); ... }
    #>
    param([string[]]$Lines)

    $sections = @{}
    $currentSection = $null

    foreach ($line in $Lines) {
        if ($line -match '^\#\#\s+\[(\d+\.\d+\.\d+)\]') {
            $currentSection = $Matches[1]
            if (-not $sections.ContainsKey($currentSection)) {
                $sections[$currentSection] = [System.Collections.Generic.HashSet[int]]::new()
            }
        }
        elseif ($line -match '^\#\#\s+\[?Unreleased\]?') {
            $currentSection = 'Unreleased'
            if (-not $sections.ContainsKey($currentSection)) {
                $sections[$currentSection] = [System.Collections.Generic.HashSet[int]]::new()
            }
        }

        if ($null -ne $currentSection) {
            $prMatches = [regex]::Matches($line, '\[#(\d+)\]')
            foreach ($pm in $prMatches) {
                [void]$sections[$currentSection].Add([int]$pm.Groups[1].Value)
            }
            # Also catch bare (#NNN) patterns
            $barePR = [regex]::Matches($line, '\(#(\d+)\)')
            foreach ($bp in $barePR) {
                [void]$sections[$currentSection].Add([int]$bp.Groups[1].Value)
            }
            # And plain #NNN references (e.g. "closes #529")
            $plainPR = [regex]::Matches($line, '(?<!\[)#(\d+)(?!\])')
            foreach ($pp in $plainPR) {
                [void]$sections[$currentSection].Add([int]$pp.Groups[1].Value)
            }
        }
    }

    return $sections
}

function Get-ConventionalType {
    <# Extracts the conventional-commit type from a subject line. #>
    param([string]$Subject)

    if ($Subject -match '^(feat|fix|docs|chore|ci|test|refactor|perf|deps|build|style)\b') {
        return $Matches[1]
    }
    # Infer from keywords
    if ($Subject -match '\bfix\b|\bbugfix\b|\bhotfix\b') { return 'fix' }
    if ($Subject -match '\btest\b|\bpester\b|\be2e\b')    { return 'test' }
    if ($Subject -match '\bdocs?\b|\bREADME\b|\bCHANGELOG\b') { return 'docs' }
    if ($Subject -match '\bci\b|\bworkflow\b|\bCI\b')     { return 'ci' }
    return 'chore'
}

function Get-SectionHeading {
    <# Maps conventional-commit type to release-please section heading. #>
    param([string]$Type)
    switch ($Type) {
        'feat'     { return 'Features' }
        'fix'      { return 'Fixes' }
        'docs'     { return 'Documentation' }
        'chore'    { return 'Chores' }
        'ci'       { return 'CI' }
        'test'     { return 'Tests' }
        'refactor' { return 'Refactors' }
        'perf'     { return 'Performance' }
        'deps'     { return 'Dependencies' }
        default    { return 'Chores' }
    }
}

function Format-CitationBullet {
    <# Formats a single CHANGELOG bullet in release-please style. #>
    param(
        [string]$Subject,
        [int[]]$PRNumbers,
        [string]$SHA,
        [string]$RepoUrl
    )

    # Strip conventional prefix and scope for cleaner display
    $desc = $Subject -replace '^\w+(\([^)]*\))?:\s*', ''
    # Strip trailing PR refs from description since we add them explicitly
    $desc = $desc -replace '\s*\(#\d+\)\s*', ' '
    $desc = $desc.Trim()

    $prLinks = ($PRNumbers | ForEach-Object {
        "[#$_]($RepoUrl/issues/$_)"
    }) -join ' '

    $shortSha = $SHA.Substring(0, 7)
    $shaLink  = "[$shortSha]($RepoUrl/commit/$SHA)"

    return "* $desc ($prLinks) ($shaLink)"
}

# ── main ─────────────────────────────────────────────────────────────────

$resolvedPath = (Resolve-Path $ChangelogPath -ErrorAction Stop).Path
$originalLines = Get-Content $resolvedPath -Encoding UTF8

Write-Verbose "Parsing existing CHANGELOG citations..."
$citedPerSection = Get-CitedPRsPerSection -Lines $originalLines

Write-Verbose "Collecting tag boundaries..."
$tagDates = Get-TagDates
$sortedBoundaries = @($tagDates.GetEnumerator() |
    Sort-Object Value |
    ForEach-Object { [PSCustomObject]@{ Tag = $_.Key; Date = $_.Value } })

Write-Verbose "Walking git log for PR references..."
$commits = Get-CommitsWithPRs

# Build list of insertions: group by (version, section heading)
$insertions = @{}  # key = "version|heading", value = list of bullets
$allMissingPRs = [System.Collections.Generic.HashSet[int]]::new()

foreach ($commit in $commits) {
    $version = Get-VersionForCommit -CommitDate $commit.AuthorDate -SortedBoundaries $sortedBoundaries

    # Check if ALL PRs in this commit are already cited
    $uncitedPRs = @()
    $sectionCited = if ($citedPerSection.ContainsKey($version)) { $citedPerSection[$version] } else {
        [System.Collections.Generic.HashSet[int]]::new()
    }

    foreach ($pr in $commit.PRNumbers) {
        # Also check if cited in ANY section (global dedup)
        $globalCited = $false
        foreach ($sec in $citedPerSection.Values) {
            if ($sec.Contains($pr)) { $globalCited = $true; break }
        }
        # Also skip if we already plan to insert this PR
        if ($allMissingPRs.Contains($pr)) { $globalCited = $true }
        if (-not $globalCited) {
            $uncitedPRs += $pr
        }
    }

    if ($uncitedPRs.Count -eq 0) { continue }

    $ccType  = Get-ConventionalType -Subject $commit.Subject
    $heading = Get-SectionHeading -Type $ccType
    $key     = "$version|$heading"

    if (-not $insertions.ContainsKey($key)) {
        $insertions[$key] = [System.Collections.Generic.List[string]]::new()
    }

    $bullet = Format-CitationBullet -Subject $commit.Subject `
        -PRNumbers $uncitedPRs -SHA $commit.SHA -RepoUrl $RepoUrl

    $insertions[$key].Add($bullet)
    foreach ($pr in $uncitedPRs) { [void]$allMissingPRs.Add($pr) }
}

if ($allMissingPRs.Count -eq 0) {
    Write-Host "✅ No missing PR citations found — CHANGELOG is up to date."
    return
}

Write-Host "Found $($allMissingPRs.Count) uncited PR(s) across $($insertions.Count) section(s)."

# ── Apply insertions to the CHANGELOG lines ──────────────────────────────

$newLines = [System.Collections.Generic.List[string]]::new()
foreach ($l in $originalLines) { $newLines.Add($l) }

# For each version section, find the right ### heading and insert after it.
# Process in reverse line order so insertions don't shift indices.
$insertionPoints = @()

foreach ($entry in $insertions.GetEnumerator()) {
    $parts   = $entry.Key -split '\|', 2
    $version = $parts[0]
    $heading = $parts[1]
    $bullets = $entry.Value

    # Find the version header line
    $versionLineIdx = -1
    $nextVersionLineIdx = $newLines.Count

    for ($i = 0; $i -lt $newLines.Count; $i++) {
        $line = $newLines[$i]
        if ($version -eq 'Unreleased') {
            # Match the FIRST Unreleased header
            if ($line -match '^\#\#\s+\[?Unreleased\]?' -and $versionLineIdx -eq -1) {
                $versionLineIdx = $i
            }
            elseif ($versionLineIdx -ge 0 -and $line -match '^\#\#\s+\[?\d+\.\d+\.\d+\]?') {
                $nextVersionLineIdx = $i
                break
            }
        }
        else {
            if ($line -match "^\#\#\s+\[$([regex]::Escape($version))\]") {
                $versionLineIdx = $i
            }
            elseif ($versionLineIdx -ge 0 -and $i -gt $versionLineIdx -and
                    ($line -match '^\#\#\s+\[' -or $line -match '^\#\#\s+\[?Unreleased\]?')) {
                $nextVersionLineIdx = $i
                break
            }
        }
    }

    if ($versionLineIdx -eq -1) {
        Write-Warning "Could not find section header for version '$version' — skipping $($bullets.Count) bullet(s)."
        continue
    }

    # Find the ### $heading within this version section
    $headingLineIdx = -1
    for ($i = $versionLineIdx + 1; $i -lt $nextVersionLineIdx; $i++) {
        if ($newLines[$i] -match "^\#\#\#\s+$([regex]::Escape($heading))\s*$") {
            $headingLineIdx = $i
            break
        }
    }

    if ($headingLineIdx -eq -1) {
        # Need to create the heading — insert just before the next ## or at end of section
        $insertAt = $nextVersionLineIdx
        # Find a good spot: after the last ### block in this section
        for ($i = $nextVersionLineIdx - 1; $i -gt $versionLineIdx; $i--) {
            if ($newLines[$i] -match '\S') {
                $insertAt = $i + 1
                break
            }
        }

        $headingBlock = @('', "### $heading", '')
        $headingBlock += $bullets
        $headingBlock += ''

        $insertionPoints += [PSCustomObject]@{
            Index = $insertAt
            Lines = $headingBlock
        }
    }
    else {
        # Find the end of the existing bullet list under this heading
        $insertAt = $headingLineIdx + 1
        for ($i = $headingLineIdx + 1; $i -lt $nextVersionLineIdx; $i++) {
            $l = $newLines[$i]
            if ($l -match '^\*\s' -or $l -match '^\s+' -or $l -eq '') {
                $insertAt = $i + 1
            }
            elseif ($l -match '^\#\#\#') {
                break
            }
        }

        $insertionPoints += [PSCustomObject]@{
            Index = $insertAt
            Lines = $bullets
        }
    }
}

# Sort by descending index so later insertions don't shift earlier ones
$insertionPoints = $insertionPoints | Sort-Object -Property Index -Descending

foreach ($ip in $insertionPoints) {
    for ($i = $ip.Lines.Count - 1; $i -ge 0; $i--) {
        $newLines.Insert($ip.Index, $ip.Lines[$i])
    }
}

$newContent = $newLines -join "`n"

# ── Output / Write ──────────────────────────────────────────────────────

if ($WhatIfPreference) {
    Write-Host "`n─── DRY RUN: would add $($allMissingPRs.Count) citation(s) ───"
    # Show a compact diff summary
    $added = ($newLines.Count - $originalLines.Length)
    Write-Host "Lines added: $added"
    Write-Host "Sections touched: $($insertions.Count)"
    Write-Host "PR numbers: $($allMissingPRs | Sort-Object | ForEach-Object { "#$_" })"
}
else {
    if ($PSCmdlet.ShouldProcess($resolvedPath, "Write $($allMissingPRs.Count) backfilled citations")) {
        Set-Content -Path $resolvedPath -Value $newContent -Encoding UTF8 -NoNewline
        Write-Host "✅ Wrote $($allMissingPRs.Count) citation(s) to $resolvedPath"
    }
}

return [PSCustomObject]@{
    CitationsAdded = $allMissingPRs.Count
    PRNumbers      = ($allMissingPRs | Sort-Object)
    SectionsTouched = $insertions.Keys
}
