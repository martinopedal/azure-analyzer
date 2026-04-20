# Bicep IaC Validation - Required Permissions

**Display name:** Bicep IaC Validation

**Scope:** repository | **Provider:** cli

Runs `bicep build` against `.bicep` files in a cloned repo. **No Azure API calls are made.**

## Required permissions

| Surface | Requirement |
|---|---|
| Azure | None |
| Microsoft Graph | None |
| GitHub | Token only required when cloning a **private** GitHub repo via `-Repository` (`GITHUB_AUTH_TOKEN` with **Contents: Read**) |
| ADO | `AZURE_DEVOPS_EXT_PAT` with **Code: Read** required only when cloning a **private** ADO repo |
| Local | None for `-RepoPath` / `-ScanPath` mode |

## Local CLI requirement

`bicep` (the Bicep CLI) must be on PATH. The tool only validates IaC source; it does not deploy or evaluate against a live Azure subscription.
