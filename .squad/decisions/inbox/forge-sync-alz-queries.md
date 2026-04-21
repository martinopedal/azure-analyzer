# Forge decision note — Sync ALZ queries (#315)

## Context
- Issue #315 asked for a manifest-driven ALZ query sync script.
- Upstream for `alz-queries` is now correctly set in `tools/tool-manifest.json` to `martinopedal/alz-graph-queries` (built on #314).
- Query-folder reshaping (`queries/alz/`) is deferred to #317.

## Decision
- Implement sync target as **top-level local** `queries/alz_additional_queries.json` (no `queries/alz/` subfolder yet).
- Resolve upstream repo from manifest (`tools[].name == "alz-queries" -> upstream.repo`) and normalize to HTTPS clone URL.
- Default upstream source path is `queries/alz_additional_queries.json` (relative to upstream repo root), matching current upstream layout.
- Enforce clone/fetch through shared helpers (`RemoteClone.ps1`, `Retry.ps1`, `Installer.ps1::Invoke-WithTimeout`, `Sanitize.ps1`) and throw rich installer-style failures via `New-InstallerError`.

## Why
- Keeps #315 narrowly scoped and avoids churn before #317 lands.
- Maintains security invariants (HTTPS-only + allow-list + credential scrubbing/sanitized output) by reusing shared infra.
- Makes re-runs no-op by hash comparison, enabling safe CI/operator use.

## Follow-up
- When #317 moves query files into tool subfolders, adjust `DestinationRelativePath` default from top-level `queries/` to the new ALZ folder while preserving dry-run + idempotence semantics.
