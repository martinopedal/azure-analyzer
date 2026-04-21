# gitleaks - Required Permissions

**Display name:** gitleaks (Secrets Scanner)

**Scope:** repository | **Provider:** cli

gitleaks scans repository filesystems for hardcoded secrets. Invoked with `--redact` so the report file **never contains plaintext secrets** (Secret / Match fields are also stripped from parsed JSON as defense-in-depth).
Schema 2.2 enrichments (`Frameworks`, `Pillar`, `DeepLinkUrl`, `EvidenceUris`, `BaselineTags`, `EntityRefs`, `ToolVersion`) are metadata only and do not require extra scopes.

**Cloud-first**: when `-Repository` (GitHub) or `-AdoOrg` / `-AdoRepoUrl` (Azure DevOps) is provided, it scans a remote checkout via `modules/shared/RemoteClone.ps1` (HTTPS-only; host allow-list: `github.com`, `dev.azure.com`, `*.visualstudio.com`, `*.ghe.com`; tokens scrubbed from `.git/config` after clone).

## Required permissions

| Mode | Auth | Notes |
|---|---|---|
| Public repo (remote) | None | |
| Private GitHub repo | `GITHUB_AUTH_TOKEN` with **Contents: Read** (fine-grained) or `public_repo` / `repo` (classic) | |
| Private ADO repo | `AZURE_DEVOPS_EXT_PAT` with **Code: Read** | |
| Local checkout | None | Works on any local clone |

## Local CLI requirement

`gitleaks` must be on PATH. Missing CLI causes the tool to skip with an install instruction.

gitleaks is read-only; no write permissions anywhere.

For pattern tuning to cut false positives, see [`docs/consumer/gitleaks-pattern-tuning.md`](../gitleaks-pattern-tuning.md).
