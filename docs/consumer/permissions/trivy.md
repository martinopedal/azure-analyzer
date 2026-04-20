# Trivy - Required Permissions

**Display name:** Trivy Vulnerability Scanner

**Scope:** repository | **Provider:** cli

Trivy scans dependency manifests (package-lock.json, requirements.txt, go.sum, etc.) for CVEs. **Cloud-first**: when `-Repository` (GitHub) or `-AdoOrg` / `-AdoRepoUrl` (Azure DevOps) is provided, it scans a remote checkout via `modules/shared/RemoteClone.ps1`.

## Required permissions

| Mode | Auth | Notes |
|---|---|---|
| Public repo (remote) | None | |
| Private GitHub repo | `GITHUB_AUTH_TOKEN` with **Contents: Read** (fine-grained) or `public_repo` / `repo` (classic) | |
| Private ADO repo | `AZURE_DEVOPS_EXT_PAT` with **Code: Read** | |
| Local checkout | None | Works on any local clone |

## Local CLI requirement

`trivy` must be on PATH. Missing CLI causes the tool to skip with an install instruction.

Trivy operates read-only; no write permissions anywhere. Vulnerability database refresh happens in the user's home directory (`~/.cache/trivy`).
