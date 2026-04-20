# Forge completion note: issue #278

- Issue: #278
- PR: #279
- Merge SHA: ebb0f30d856ae70846f5d2c5b63421bae8feda01
- Closed: 2026-04-20T17:31:33Z

## Outcome

Resolved CI failure in `Docs Check / Tool catalog fresh` caused by rapid parallel merges that touched `tools/tool-manifest.json` and generated docs at nearly the same time.

## Root cause

Race condition / stale generated docs sequence, not a generator logic bug. The manifest projection logic in `scripts/Generate-ToolCatalog.ps1` remained valid for new tool fields; the failing run had committed catalog files out of sync with the latest manifest projection.

## Changes applied

- Hardened `.github/workflows/docs-check.yml` to print the generated catalog diff when freshness fails.
- Extended `tests/scripts/Generate-ToolCatalog.Tests.ps1` with a committed-vs-generated projection parity test.
- Added CRLF/LF normalization in that test to keep Windows runners stable.
- Updated `CHANGELOG.md` with `fix(ci)` entry for #278.

## Validation

- `pwsh -File scripts/Generate-ToolCatalog.ps1 -CheckOnly`
- `pwsh -File scripts/Generate-PermissionsIndex.ps1 -CheckOnly`
- `Invoke-Pester -Path .\tests -CI` -> 1293 passed, 0 failed, 5 skipped
- `gh pr checks 279 --watch` -> all checks green, including `Docs Check / Tool catalog fresh`

## Prevention pattern

For manifest-driven generated docs, keep verifier logs diagnostic-first: show projection diff on failure and enforce parity via tests that normalize line endings. This catches stale-doc races quickly and avoids opaque CI failures.
