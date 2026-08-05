---
name: "strictmode-property-access"
description: "StrictMode-safe optional property access in PowerShell"
domain: "powershell"
confidence: "high"
source: "suppression-list regression (Invoke-AzureAnalyzer.ps1 line 2157, PR #1251)"
---

## Context

This repo runs `Set-StrictMode -Version Latest` in both the orchestrator and the module. Under StrictMode, accessing a property that does not exist on an object throws `PropertyNotFoundException`, not a silent `$null`. This bites whenever two code paths add objects to the same list but one path forgets a property.

The canonical example: `Invoke-AzureAnalyzer.ps1` has two `$allResults.Add(...)` blocks -- one for normal tool findings (line 1472) and one for correlator findings (line 1633). The suppression feature added `Suppressed`, `FindingKey`, and `SuppressionReason` to the first block but not the second. The severity-count `Where-Object { ... -and -not $_.Suppressed }` at line 2157 then threw on any correlator finding.

## Pattern: stamp the property on every object, even with a default

The most robust fix is to stamp the property with a safe default on every path, so the property always exists:

```powershell
$allResults.Add([PSCustomObject]@{
    # ... other fields ...
    FindingKey        = if ($f.PSObject.Properties['FindingKey'])        { $f.FindingKey }        else { '' }
    Suppressed        = if ($f.PSObject.Properties['Suppressed'])        { [bool]$f.Suppressed }  else { $false }
    SuppressionReason = if ($f.PSObject.Properties['SuppressionReason']) { $f.SuppressionReason } else { '' }
})
```

## Pattern: safe read when you cannot guarantee the property

When you cannot control how the object was created, use `PSObject.Properties`:

```powershell
# StrictMode-safe optional read -- returns $null if property absent, not an exception
$suppressed = $_.PSObject.Properties['Suppressed']
if ($suppressed -and $suppressed.Value) { ... }

# Or in a Where-Object:
$results | Where-Object { -not ($_.PSObject.Properties['Suppressed'] -and $_.Suppressed) }
```

Do NOT use this in hot paths that run millions of times -- `PSObject.Properties` is slower than direct access. Stamp the property at construction time for objects in shared lists.

## Anti-pattern: direct access on objects from mixed sources

```powershell
# WRONG under StrictMode when some objects lack Suppressed:
$results | Where-Object { -not $_.Suppressed }

# RIGHT -- stamp at construction, or check PSObject.Properties first:
$results | Where-Object { -not ($_.PSObject.Properties['Suppressed'] -and $_.Suppressed) }
```

## Checklist when adding a new property to `$allResults`

1. Find every `$allResults.Add(...)` block in `Invoke-AzureAnalyzer.ps1`.
2. Add the new property with a safe default to ALL blocks, not just the first one.
3. Search for every consumer of `$allResults` (and `$allResultsFM`) to verify it does not access the new property without a `PSObject.Properties` guard.
4. Run `Invoke-Pester -Path tests/Invoke-AzureAnalyzer.IdentityGraphExpansion.Integration.Tests.ps1` -- this test exercises the correlator path that triggered the regression.
