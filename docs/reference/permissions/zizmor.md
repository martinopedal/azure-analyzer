# zizmor - Required Permissions

**Display name:** zizmor (Actions YAML Scanner)

**Scope:** repository | **Provider:** cli

zizmor scans GitHub Actions workflow YAML files for security anti-patterns. **Cloud-first**: when `-Repository` is provided it scans a remote checkout via `modules/shared/RemoteClone.ps1` (HTTPS-only; host allow-list: `github.com`, `dev.azure.com`, `*.visualstudio.com`, `*.ghe.com`; tokens scrubbed from `.git/config` after clone). When neither `-Repository` nor `-AdoOrg` is provided it falls back to scanning the local filesystem (`-RepoPath` / `-ScanPath`).

## Required permissions

| Mode | Auth | Notes |
|---|---|---|
| Public repo (remote) | None | No token required |
| Private repo (remote) | `GITHUB_AUTH_TOKEN` - fine-grained PAT with **Contents: Read**, or classic PAT with `public_repo` / `repo` | Same token used by Scorecard |
| Local checkout | None | Works on any local clone |

## Local CLI requirement

`zizmor` must be on PATH. If missing the tool is skipped with an install instruction.

zizmor is read-only; no write permissions anywhere.
