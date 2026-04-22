#Requires -Version 7.4
<#
.SYNOPSIS
    Auto-resolves common Git merge-conflict patterns in additive files (changelogs,
    docs, manifest entries) used by the `pr-auto-rebase.yml` workflow.

.DESCRIPTION
    Reads a file with conflict markers (`<<<<<<<`, `=======`, `>>>>>>>`) and applies
    a "union" merge strategy appropriate for additive content:
      - Changelog       Concatenates both sides' entries inside each conflict block
                        and dedupes by trimmed content. Both [Unreleased] additions
                        survive.
      - Manifest        Same union merge, then validates the resulting file parses
                        as JSON. Aborts (throws) when both sides modified the same
                        keys and the merged document is invalid JSON.
      - DocAddition     Same union merge for README / docs/ where both sides added
                        new sections.

    The script never touches lines outside conflict blocks. Throws when the conflict
    block is malformed, no markers are found, or post-merge validation fails. Pure
    PowerShell; no external dependencies.

.PARAMETER Path
    File with conflict markers. Modified in place on success.

.PARAMETER Strategy
    One of: Changelog, Manifest, DocAddition.

.OUTPUTS
    Hashtable with Resolved (bool), BlockCount (int), Path (string).
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Path,
    [Parameter(Mandatory)] [ValidateSet('Changelog', 'Manifest', 'DocAddition')] [string] $Strategy
)

$ErrorActionPreference = 'Stop'

function Get-ConflictBlock {
    param([string[]] $Lines)
    $blocks = @()
    $i = 0
    while ($i -lt $Lines.Count) {
        if ($Lines[$i] -match '^<<<<<<<') {
            $start = $i
            $sep = -1
            $end = -1
            for ($j = $i + 1; $j -lt $Lines.Count; $j++) {
                if ($sep -lt 0 -and $Lines[$j] -match '^=======\s*$') {
                    $sep = $j
                } elseif ($Lines[$j] -match '^>>>>>>>') {
                    $end = $j
                    break
                }
            }
            if ($sep -lt 0 -or $end -lt 0) {
                throw "Malformed conflict block starting at line $($start + 1) in input"
            }
            $oursRange = if ($sep - 1 -ge $start + 1) { $Lines[($start + 1)..($sep - 1)] } else { @() }
            $theirsRange = if ($end - 1 -ge $sep + 1) { $Lines[($sep + 1)..($end - 1)] } else { @() }
            $blocks += [pscustomobject]@{
                Start  = $start
                Sep    = $sep
                End    = $end
                Ours   = @($oursRange)
                Theirs = @($theirsRange)
            }
            $i = $end + 1
        } else {
            $i++
        }
    }
    return , $blocks
}

function Merge-ConflictBlocksUnion {
    param(
        [string[]] $Lines,
        [object[]] $Blocks
    )
    $out = New-Object 'System.Collections.Generic.List[string]'
    $cursor = 0
    foreach ($b in $Blocks) {
        for ($k = $cursor; $k -lt $b.Start; $k++) { $out.Add($Lines[$k]) | Out-Null }
        $seen = New-Object 'System.Collections.Generic.HashSet[string]'
        foreach ($l in $b.Ours)   { if ($seen.Add($l.Trim())) { $out.Add($l) | Out-Null } }
        foreach ($l in $b.Theirs) { if ($seen.Add($l.Trim())) { $out.Add($l) | Out-Null } }
        $cursor = $b.End + 1
    }
    for ($k = $cursor; $k -lt $Lines.Count; $k++) { $out.Add($Lines[$k]) | Out-Null }
    return , $out.ToArray()
}

function Resolve-FileWithUnion {
    param(
        [string]      $FilePath,
        [scriptblock] $Validator
    )
    if (-not (Test-Path -LiteralPath $FilePath)) {
        throw "File not found: $FilePath"
    }
    $raw = Get-Content -LiteralPath $FilePath -Raw
    if ([string]::IsNullOrEmpty($raw)) {
        throw "File is empty: $FilePath"
    }
    $eol = if ($raw -match "`r`n") { "`r`n" } else { "`n" }
    $hadTrailingNewline = $raw.EndsWith("`n")
    $lines = $raw -split "`r?`n"
    if ($hadTrailingNewline -and $lines[-1] -eq '') {
        $lines = $lines[0..($lines.Count - 2)]
    }
    $blocks = Get-ConflictBlock -Lines $lines
    if ($blocks.Count -eq 0) {
        throw "No conflict markers found in $FilePath"
    }
    $merged = Merge-ConflictBlocksUnion -Lines $lines -Blocks $blocks
    $content = ($merged -join $eol)
    if ($hadTrailingNewline) { $content += $eol }
    if ($Validator) {
        $err = & $Validator $content
        if ($err) {
            throw "Auto-resolved content failed validation for ${FilePath}: $err"
        }
    }
    Set-Content -LiteralPath $FilePath -Value $content -NoNewline
    return @{ Resolved = $true; BlockCount = $blocks.Count; Path = $FilePath }
}

function Resolve-ChangelogConflict {
    param([string] $Path)
    return Resolve-FileWithUnion -FilePath $Path
}

function Resolve-DocAdditionConflict {
    param([string] $Path)
    return Resolve-FileWithUnion -FilePath $Path
}

function Resolve-ManifestConflict {
    param([string] $Path)
    return Resolve-FileWithUnion -FilePath $Path -Validator {
        param($content)
        try {
            $null = $content | ConvertFrom-Json -ErrorAction Stop
            return $null
        } catch {
            return $_.Exception.Message
        }
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    switch ($Strategy) {
        'Changelog'   { Resolve-ChangelogConflict   -Path $Path }
        'Manifest'    { Resolve-ManifestConflict    -Path $Path }
        'DocAddition' { Resolve-DocAdditionConflict -Path $Path }
    }
}
