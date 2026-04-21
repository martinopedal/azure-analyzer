# ADO Repos Secret Scanning - Required Permissions

**Display name:** ADO Repos Secret Scanning

**Scope:** ado | **Provider:** ado

The ADO repo-secret scanner (`ado-repos-secrets`) is read-only and supports both Azure DevOps Services (cloud) and Azure DevOps Server / on-prem collection URLs. PAT authentication remains Basic auth with the same read-only scopes.

## Required PAT scopes

| Token scope | Why |
|-------------|-----|
| **Code (Read)** | Enumerate repositories and clone source for secret scanning |
| **Project and Team (Read)** | Enumerate projects when `-AdoProject` is omitted |

## Usage

```powershell
$env:AZURE_DEVOPS_EXT_PAT = "<your-ado-pat>"

# Repo secret scanning only
.\Invoke-AzureAnalyzer.ps1 -AdoOrg "contoso" -IncludeTools 'ado-repos-secrets'

# Azure DevOps Server / on-prem collection
.\Invoke-AzureAnalyzer.ps1 -AdoOrg "contoso" -AdoServerUrl "https://ado.contoso.local/tfs/DefaultCollection" -IncludeTools 'ado-repos-secrets'
```

The tool uses HTTPS-only remote cloning via `modules/shared/RemoteClone.ps1`, enforces host allow-list checks (`github.com`, `dev.azure.com`, `*.visualstudio.com`, `*.ghe.com`), and never requires write permissions. For on-prem deployments on custom hostnames outside the allow-list, repository clones are skipped and surfaced as **Info** findings so coverage gaps are explicit.

For pattern tuning to cut false positives, see [`docs/consumer/gitleaks-pattern-tuning.md`](../gitleaks-pattern-tuning.md).
