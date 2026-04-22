#Requires -Version 7.4
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Guard for audit category 1 (post-#473 consistency sweep):
#
#   Scriptblocks that may be dispatched across PowerShell session-state
#   boundaries (e.g. orchestrator -> module-private installer, KubeAuth ->
#   wrapper cleanup, RemoteClone -> wrapper cleanup) must capture all
#   external state as variables. They MUST NOT rely on functions that are
#   only visible at the producer's session scope, because the consumer's
#   session state will not have those functions in scope and the call
#   will fail with a CommandNotFoundException at execution time
#   (the original failure mode of #473).
#
#   This test is a structural lint over the small set of confirmed
#   cross-boundary closure sites:
#     - Invoke-AzureAnalyzer.ps1   ShouldRunTool predicate (#473 fix)
#     - modules/shared/KubeAuth.ps1 cleanup closure
#     - modules/shared/RemoteClone.ps1 cleanup closure
#
#   For each site we assert that the scriptblock immediately preceding
#   the .GetNewClosure() call references only $-prefixed variables (or
#   built-in cmdlets / type accelerators), never bare identifiers that
#   would resolve to script-scope functions invisible from another
#   session state.

BeforeAll {
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path

    function Get-ClosureBlocks {
        param ([string] $Path)

        $text = Get-Content -LiteralPath $Path -Raw

        # Walk backward from each .GetNewClosure() to its matching opening brace,
        # ignoring nested braces. Returns the body text between the braces.
        $results = [System.Collections.Generic.List[pscustomobject]]::new()
        $regex = [regex]'\}\.GetNewClosure\(\)'
        foreach ($m in $regex.Matches($text)) {
            $closeIndex = $m.Index
            $depth = 1
            $i = $closeIndex - 1
            while ($i -ge 0 -and $depth -gt 0) {
                $ch = $text[$i]
                if ($ch -eq '}') { $depth++ }
                elseif ($ch -eq '{') { $depth-- }
                if ($depth -eq 0) { break }
                $i--
            }
            if ($depth -ne 0) { continue }
            $openIndex = $i
            $body = $text.Substring($openIndex + 1, $closeIndex - $openIndex - 1)
            $line = ($text.Substring(0, $openIndex) -split "`n").Count
            $results.Add([pscustomobject]@{
                Path = $Path
                Line = $line
                Body = $body
            })
        }
        return $results
    }
}

Describe 'Closure boundary lint - cross-session-state safety (post-#473)' {

    It 'inventories every .GetNewClosure() site in the orchestrator and shared modules' {
        $sites = @()
        $sites += Get-ClosureBlocks -Path (Join-Path $script:RepoRoot 'Invoke-AzureAnalyzer.ps1')
        Get-ChildItem -Path (Join-Path $script:RepoRoot 'modules') -Filter '*.ps1' -Recurse |
            ForEach-Object { $sites += Get-ClosureBlocks -Path $_.FullName }

        # If new sites appear, this test should be reviewed and the
        # patterns extended to cover them.
        $sites.Count | Should -BeGreaterThan 0
        $sites.Count | Should -BeLessOrEqual 10 -Because (
            "If the count of .GetNewClosure() sites grows substantially, " +
            "the consistency-sweep test ought to be re-evaluated to make " +
            "sure all new sites are still session-state safe. Current " +
            "sites: $(($sites | ForEach-Object { '{0}:{1}' -f $_.Path, $_.Line }) -join '; ')"
        )
    }

    It 'every closure body references only $-prefixed identifiers (no bare function calls that could leak across session state)' {
        $sites = @()
        $sites += Get-ClosureBlocks -Path (Join-Path $script:RepoRoot 'Invoke-AzureAnalyzer.ps1')
        Get-ChildItem -Path (Join-Path $script:RepoRoot 'modules') -Filter '*.ps1' -Recurse |
            ForEach-Object { $sites += Get-ClosureBlocks -Path $_.FullName }

        # Allowlist: PowerShell built-in cmdlets / verbs and language
        # keywords that are present in every session state and therefore
        # safe to call from a closure body executed in any scope.
        $allowedBare = @(
            'param','if','else','elseif','foreach','for','while','do','switch','return','throw','try','catch','finally',
            'Remove-Item','Test-Path','Get-Item','New-Item','Join-Path','Split-Path','Resolve-Path','ConvertTo-Json',
            'ConvertFrom-Json','Out-Null','Out-String','Write-Host','Write-Verbose','Write-Warning','Write-Error',
            'Get-Command','Get-Date','Get-Variable','Set-Variable','Where-Object','ForEach-Object','Select-Object',
            'Sort-Object','Measure-Object','Group-Object','Add-Member','New-Object','Start-Sleep','Stop-Process',
            'Get-Process','Get-ChildItem','Set-Content','Get-Content','Add-Content','Out-File','Test-Json'
        )

        $offenders = [System.Collections.Generic.List[string]]::new()
        foreach ($site in $sites) {
            # Strip strings, comments, and variable references.
            $clean = $site.Body
            $clean = [regex]::Replace($clean, "(?ms)<#.*?#>", '')
            $clean = [regex]::Replace($clean, "(?m)#.*$", '')
            $clean = [regex]::Replace($clean, "'[^']*'", "''")
            $clean = [regex]::Replace($clean, '"[^"]*"', '""')
            $clean = [regex]::Replace($clean, '\$[A-Za-z_][\w\.\:]*', '')

            # Find bare identifiers that look like command invocations.
            # A "command-position" identifier is one that appears at the
            # start of a statement, not after a dot, colon, or as a
            # parameter argument value.
            $idMatches = [regex]::Matches($clean, '(?m)(^|[\s\(\{;\|&])([A-Za-z][A-Za-z0-9\-]*)\b')
            foreach ($im in $idMatches) {
                $ident = $im.Groups[2].Value
                if ($ident -in $allowedBare) { continue }
                if ($ident -match '^(true|false|null)$') { continue }
                # Skip identifiers that look like enum / parameter argument
                # values: anything immediately preceded by a `-Param ` token
                # is a value, not a command. We check the 40 chars before
                # the match for a `-<name>\s+` parameter prefix.
                $back = $clean.Substring([Math]::Max(0, $im.Index - 40), [Math]::Min(40, $im.Index))
                if ($back -match '-[A-Za-z][A-Za-z0-9]*\s*$') { continue }
                $offenders.Add(("{0}:{1} -> {2}" -f $site.Path, $site.Line, $ident))
            }
        }

        $offenders.Count | Should -Be 0 -Because (
            "Closure bodies that may execute in another session state must " +
            "not call bare identifiers that resolve to script-scope " +
            "functions in the producer scope (the #473 bug class). Capture " +
            "the value as a variable, or reference a built-in cmdlet. " +
            "Offenders:`n" + ($offenders -join "`n")
        )
    }
}
