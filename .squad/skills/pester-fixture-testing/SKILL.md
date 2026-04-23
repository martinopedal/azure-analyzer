# Skill: Pester Fixture Testing

Patterns learned from stabilizing drift-detection tests in azure-analyzer.

## Deterministic output rule

Any renderer output used in drift tests **MUST** have a stable sort order.

- Hashtables (`@{}`) have non-deterministic `GetEnumerator()` order across runs/platforms.
- Use `[ordered]@{}` for any hashtable whose keys/values are serialized to JSON or HTML.
- When sorting collections with ties, always include a secondary sort on a unique key (e.g., name ascending) to break ties deterministically:
  ```powershell
  # BAD — ties produce random order
  Sort-Object Value -Descending

  # GOOD — ties broken by name
  Sort-Object @{Expression={$_.Value};Descending=$true}, @{Expression={$_.Key};Descending=$false}
  ```
- When switching from `@{}` to `[ordered]@{}`, update `.ContainsKey()` calls to `.Contains()` — `OrderedDictionary` uses the latter.

## Array wrapping rule

Always use `@()` for parameters that might be `$null` or a single object in strict mode.

```powershell
# BAD — .Count fails on $null under Set-StrictMode -Version Latest
for ($i = $SortedBoundaries.Count - 1; $i -ge 0; $i--) { ... }

# GOOD — @() forces array, .Count always works
$SortedBoundaries = @($SortedBoundaries)
for ($i = $SortedBoundaries.Count - 1; $i -ge 0; $i--) { ... }
```

This is critical in `Set-StrictMode -Version Latest` where accessing `.Count` on `$null` throws `PropertyNotFoundException`.

## CRLF normalization for cross-platform fixture comparison

Drift tests compare committed fixtures against freshly generated output. Line endings differ across platforms:
- Windows: `\r\n` (CRLF)
- Linux/macOS: `\n` (LF)
- GitHub Actions runners: LF

Always normalize before comparison:
```powershell
$committed = (Get-Content $fixture -Raw -Encoding UTF8) -replace "`r`n", "`n"
$fresh     = (Get-Content $freshFile -Raw -Encoding UTF8) -replace "`r`n", "`n"
$fresh | Should -BeExactly $committed
```

Also strip non-deterministic values (timestamps) before comparison:
```powershell
$text = $text -replace '\d{4}-\d{2}-\d{2} \d{2}:\d{2} UTC', 'TIMESTAMP'
```
