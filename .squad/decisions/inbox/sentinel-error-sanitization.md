# Decision: Error Sanitization Boundary

**Date:** 2026-04-18  
**Agent:** Sentinel  
**Issue:** #100  
**PR:** #116  

## Context

Error messages written to disk (JSON, HTML, MD, logs) can contain sensitive data leaked from Azure API errors, ADO PAT tokens, GitHub tokens, connection strings, or SAS URIs. These must be sanitized before writing to prevent credential exposure.

## Decision

**Sanitize at error-capture time, not write-time.**

Every `catch` block that assigns to a `Message` property must wrap the exception message with `Remove-Credentials`:

```powershell
} catch {
    $result.Status  = 'Failed'
    $result.Message = "Context: $(Remove-Credentials $_.Exception.Message)"
    return [pscustomobject]$result
}
```

## Rationale

1. **Single boundary enforcement:** Wrapping at catch-time ensures no code path can bypass sanitization. If we sanitized only at write-time, a future developer might write a new output path and forget to sanitize.

2. **Consistency:** All error messages in the result object are always safe. No need to re-sanitize at every `ConvertTo-Json` or `Set-Content` call.

3. **Testability:** We can test sanitization once at the boundary (exception → result object), not at every disk-write callsite.

## Alternatives Considered

- **Write-time sanitization:** Sanitize only at `ConvertTo-Json`, `Set-Content`, etc. Rejected because it's easy to miss a new write path and because error messages flow through multiple layers (orchestrator → normalizer → entity store → report).

- **Dual-layer sanitization:** Sanitize at both capture and write. Rejected as over-engineering; single boundary is sufficient if consistently applied.

## Pattern Established

```powershell
# ✅ Correct (error-capture boundary)
} catch {
    $result.Message = "Tool failed: $(Remove-Credentials $_.Exception.Message)"
}

# ❌ Incorrect (unsanitized)
} catch {
    $result.Message = "Tool failed: $($_.Exception.Message)"
}
```

## Enforcement

- Grep audit: `Exception\.Message|Error\.Message|\.Message` with manual review
- Pester tests: 6 disk-write scenarios (SAS URI, bearer token, connection string, GitHub PAT, null handling, multi-secret)
- CI: Full test suite must pass (398/398 tests)

## Status

**Active** — all existing unsanitized writes fixed in #116. Pattern documented for future development.
