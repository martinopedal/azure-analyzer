# Skill: Error Sanitization for Disk Writes

**Owner:** Sentinel  
**Created:** 2026-04-18  
**Issue:** #100  

## Purpose

Prevent credentials, tokens, connection strings, or SAS URIs from being written to disk in error messages.

## Pattern

**Always wrap exception messages with `Remove-Credentials` at the error-capture boundary (in catch blocks), not at write-time.**

### Correct Pattern

```powershell
} catch {
    $result.Status  = 'Failed'
    $result.Message = "Tool failed: $(Remove-Credentials $_.Exception.Message)"
    return [pscustomobject]$result
}
```

### Incorrect Pattern

```powershell
} catch {
    $result.Status  = 'Failed'
    $result.Message = "Tool failed: $($_.Exception.Message)"  # ❌ UNSANITIZED
    return [pscustomobject]$result
}
```

## Why Error-Capture Boundary?

1. **Single enforcement point:** Every error message in result objects is always safe
2. **No bypass risk:** New write paths automatically get sanitized messages
3. **Testable:** Test once at boundary, not at every disk-write site
4. **Consistent:** All error messages flow through the same sanitization logic

## What Gets Redacted?

The `Remove-Credentials` function (from `modules/shared/Sanitize.ps1`) redacts:

- GitHub PATs: `ghp_*`, `gho_*`, `ghs_*`, `ghr_*`, `github_pat_*`
- ADO PATs: `Authorization: Basic ...`
- Bearer tokens: `Bearer ...`
- Connection string secrets: `AccountKey=`, `Password=`, `SharedAccessKey=`
- SAS signatures: `sig=...`, `SharedAccessSignature=`
- OAuth secrets: `client_secret=...`

## When to Apply

Apply this pattern in:

- All tool wrapper modules (`modules/Invoke-*.ps1`)
- Main orchestrator (`Invoke-AzureAnalyzer.ps1`)
- Shared modules that handle errors (`modules/shared/*.ps1`)
- Any code that writes to JSON, HTML, MD, log files, or temp files

## Verification

### Grep Audit

```powershell
# Find potential unsanitized writes
Get-ChildItem -Path . -Filter '*.ps1' -Recurse | Where-Object { $_.FullName -notlike '*\.git\*' } | ForEach-Object {
    $lines = Get-Content $_.FullName
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match 'Message\s*=.*Exception\.Message' -and $lines[$i] -notmatch 'Remove-Credentials') {
            Write-Output "$($_.Name):$($i+1): $($lines[$i].Trim())"
        }
    }
}
```

Expected output: **(empty)** — no unsanitized writes should exist.

### Pester Tests

Tests in `tests/shared/Sanitize.Tests.ps1` cover:

- SAS URI sanitization in exception → disk write
- Bearer token sanitization in exception → disk write
- Connection string sanitization
- GitHub PAT in JSON error output
- Null/empty message handling
- Multi-secret sanitization

## Examples from Codebase

### Azure Cost (Consumption API)

```powershell
} catch {
    $result.Status  = 'Failed'
    $result.Message = "Consumption API query failed: $(Remove-Credentials $_.Exception.Message)"
    return [pscustomobject]$result
}
```

### Defender for Cloud

```powershell
} catch {
    $result.Status  = 'Failed'
    $result.Message = "Secure Score query failed: $(Remove-Credentials $_.Exception.Message)"
    return [pscustomobject]$result
}
```

### KubeBench / Kubescape (ARG Discovery)

```powershell
} catch {
    $result.Status  = 'Failed'
    $result.Message = "ARG discovery failed: $(Remove-Credentials $_.Exception.Message)"
    return [pscustomobject]$result
}
```

### Main Orchestrator (Worker Exception)

```powershell
} catch {
    return [PSCustomObject]@{
        Source   = [System.IO.Path]::GetFileNameWithoutExtension($ScriptPath)
        Status   = 'Failed'
        Message  = (Remove-Credentials $_.Exception.Message)
        Findings = @()
    }
}
```

## False Positives

These are **safe** (not written to disk):

- `Write-Warning` — goes to warning stream (console), not disk
- `Write-Verbose` — goes to verbose stream (console), not disk
- `Write-Host` — goes to console, not disk

Only sanitize messages that flow into result objects, JSON, HTML, MD, logs, or temp files.

## Enforcement

- **Code review:** All PRs that add new error handling must follow this pattern
- **CI:** Pester tests validate sanitization logic
- **Periodic audit:** Run grep audit quarterly to catch regressions

## References

- Issue: #100
- PR: #116
- Sanitize module: `modules/shared/Sanitize.ps1`
- Tests: `tests/shared/Sanitize.Tests.ps1`
- Decision note: `.squad/decisions/inbox/sentinel-error-sanitization.md`
