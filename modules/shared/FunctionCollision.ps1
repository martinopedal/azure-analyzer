# FunctionCollision.ps1 — AST-based duplicate-function detector for the
# modules/shared/ tree. Companion to Errors.ps1.
#
# Background (#529 / #671): AzureAnalyzer.psm1 dot-sources every *.ps1 under
# modules/shared/ in ASCII order, so two files defining the same top-level
# function will silently shadow each other. The original incident: a stub
# `function New-FindingError` in Schema.ps1 overrode the canonical sanitizing
# version in Errors.ps1, bypassing Remove-Credentials on Reason / Remediation.
#
# This helper walks each file's AST and reports any function name defined more
# than once across files, IGNORING:
#   - guarded fallback shims wrapped in `if (-not (Get-Command X)) { function X }`
#   - nested helper functions defined inside another function
# Both patterns are intentional and don't cause shadowing of the canonical.

function Test-AzureAnalyzerSharedFunctionCollisions {
    [CmdletBinding()]
    param ([Parameter(Mandatory)] [System.IO.FileInfo[]] $Files)
    $seen = @{}
    foreach ($f in $Files) {
        $tokens = $null; $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile(
            $f.FullName, [ref]$tokens, [ref]$errors)
        if ($null -eq $ast) { continue }
        $funcs = $ast.FindAll({ param($n)
            $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)
        foreach ($fn in $funcs) {
            $isGuarded = $false
            $p = $fn.Parent
            while ($p) {
                if ($p -is [System.Management.Automation.Language.IfStatementAst] -or
                    $p -is [System.Management.Automation.Language.FunctionDefinitionAst]) {
                    $isGuarded = $true; break
                }
                $p = $p.Parent
            }
            if ($isGuarded) { continue }
            $name = $fn.Name
            if ($seen.ContainsKey($name)) {
                $seen[$name] += , $f.FullName
            } else {
                $seen[$name] = @($f.FullName)
            }
        }
    }
    $collisions = @($seen.GetEnumerator() | Where-Object { @($_.Value).Count -gt 1 })
    foreach ($c in $collisions) {
        Write-Warning ("AzureAnalyzer: function '{0}' is defined in multiple shared files (later wins): {1}" -f `
                $c.Key, ($c.Value -join '; '))
    }
    return $collisions
}
