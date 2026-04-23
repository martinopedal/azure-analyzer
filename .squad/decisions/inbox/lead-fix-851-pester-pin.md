# Lead — Fix #851: Pin Pester to 5.7.1 across CI workflows

**Date:** 2026-04-23
**Author:** Lead
**Issue:** #851 (canonical for #844, #849, #856 — `Invoke-Pester returned null` across matrix OSes)
**Branch:** `squad/lead-fix-851-pin-pester`
**PR:** (to be filed)

## Problem

CI Test matrix (ubuntu / windows / macos) intermittently aborted with
`Invoke-Pester returned null; cannot record TotalCount.` across all three
OSes within the same run. Over 4 duplicate auto-filed issues. Neither the
failing jobs nor the pester-count baseline artifact showed which Pester
build was actually loaded.

## Root cause

`ci.yml`, `e2e.yml`, and `release.yml` all used:

```
Install-Module Pester -MinimumVersion 5.0
Import-Module Pester -MinimumVersion 5.0
```

`-MinimumVersion` lets Install-Module pull the **highest available**
version. Pester 6 is already on PowerShell Gallery as an alpha / preview
line and will auto-upgrade the moment it ships stable. Pester 6 is a
major rewrite with a different `[PesterConfiguration]` surface; on the
matrix runners (which may have side-installed preview bits from other
workflows) `Invoke-Pester -Configuration $config` with `PassThru=$true`
has been observed returning `$null` rather than a result object. That
null trips the `if ($null -eq $result)` guard, which writes a `::error::`
and exits 1 — but without telling triage which Pester version caused it.

## Decision

1. **Pin to `-RequiredVersion 5.7.1`** in all three workflows. 5.7.1 is
   the baseline the repo runs locally (`tests/_helpers/setup.ps1`
   bootstraps against it) and matches the version already in the
   existing green baseline run.
2. **Dump loaded Pester version** in the null-result branch of ci.yml so
   the next triage round has evidence, not an opaque abort.
3. **Add guard tests** in `tests/workflows/PesterVersionPin.Tests.ps1`:
   - no workflow may use `-MinimumVersion` on `Install-Module Pester`
     or `Import-Module Pester`
   - every workflow that imports Pester must pin to the canonical
     version (currently 5.7.1)
   - ci.yml must retain the loaded-version diagnostic in its null branch

   This prevents a future edit from silently re-introducing the drift
   bug.

## Alternatives considered

- **Pin to 5.6.x** to reduce install latency on hosted runners — rejected,
  5.7.1 matches local dev baseline and 1.1.1 release manifest, and the
  install happens inside a cached `nick-fields/retry` step anyway.
- **Block Pester 6 via a PSRepository filter** — rejected, too indirect;
  `-RequiredVersion` is explicit and surveyable.
- **Clear side-installed Pester 6 via Remove-Module / Uninstall-Module** —
  rejected for now; `Import-Module -RequiredVersion 5.7.1 -Force` wins
  the import race and is sufficient. Revisit if we see side-install
  symptoms after the pin lands.

## Test evidence

- `tests/workflows/PesterVersionPin.Tests.ps1` — 10/10 green against the
  pinned workflows; verified each guard case fails when I temporarily
  reverted a single Install-Module / Import-Module line back to
  `-MinimumVersion 5.0`.
- `tests/workflows/*` suite overall: 528/529 (the 1 pre-existing
  `continue-on-error` hygiene failure on ci.yml is tracked separately
  and is unrelated).
- Local Pester 5.7.1 baseline unchanged.

## Closes

- #851 (canonical)
- #844 / #849 / #856 (closed as duplicates pointing at #851; this PR
  closes them transitively)
