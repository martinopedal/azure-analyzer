# Shared Infrastructure Modules

**Status**: In development

Detailed module documentation coming soon.

## Overview

Shared modules provide battle-tested utilities for wrappers to avoid reinventing retry logic, cloning, sanitization, and error handling.

## Core Modules

### `modules/shared/Installer.ps1`

Manifest-driven prerequisite installer. See [tool-manifest.json](../../tools/tool-manifest.json).

- `Install-PrerequisitesFromManifest` — main entry point
- `Invoke-WithInstallRetry` — retry wrapper with jittered backoff
- `Invoke-WithTimeout` — 300s timeout on external processes
- Supports `psmodule`, `cli`, `gitclone`, `none` install types

### `modules/shared/RemoteClone.ps1`

Cloud-first HTTPS clone helper. All repo-scoped tools use this.

- `Invoke-RemoteRepoClone` — returns `{ Path, Url, Cleanup }`
- Host allow-list: `github.com`, `dev.azure.com`, `*.visualstudio.com`, `*.ghe.com`
- HTTPS-only (HTTP rejected)
- Token scrubbing from `.git/config` post-clone

### `modules/shared/Retry.ps1`

Transient failure retry with jittered exponential backoff.

- `Invoke-WithRetry` — wraps any scriptblock
- Retries on 429/503/504/throttle/timeout patterns
- Default: 3 retries, 2s base delay, 2x backoff, 0.3 jitter

### `modules/shared/Sanitize.ps1`

Credential scrubbing for all output written to disk.

- `Remove-Credentials` — scrubs tokens/keys/connection strings
- All JSON/HTML/MD/log output must pass through this

### `modules/shared/Schema.ps1`

Schema 2.2 FindingRow factory and entity type enums.

- `New-FindingRow` — ONLY way to emit v2 findings
- Severity enum: `Critical | High | Medium | Low | Info`
- EntityType enum: 15 canonical types

### `modules/shared/Canonicalize.ps1`

Canonical entity ID normalization.

- `ConvertTo-CanonicalEntityId` — always use for entity IDs
- Format: `tenant:{guid}`, `appId:{guid}`, ARM lowercase

### `modules/shared/EntityStore.ps1`

v3 entity-centric store writer.

- Findings and entities written separately
- `results.json` + `entities.json` output

## Security Invariants

All shared modules enforce:

- ✅ HTTPS-only URLs
- ✅ Host allow-lists for clone/fetch
- ✅ Package manager allow-lists
- ✅ 300s timeout on external processes
- ✅ Token scrubbing from config files
- ✅ Rich error objects with sanitized details

See module source files for full API reference.
