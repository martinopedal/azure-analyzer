# ADO Pipeline Run Correlator - Required Permissions

**Display name:** ADO Pipeline Run Correlator

**Scope:** ado | **Provider:** ado

The run correlator (`ado-pipeline-correlator`) is read-only and requires only the minimum PAT scopes needed to enumerate build runs and correlate commit SHAs with `ado-repos-secrets` output.
Schema 2.2 blast-radius metadata (`DeepLinkUrl`, `EvidenceUris`, `BaselineTags`, `EntityRefs`) is derived from the same read-only build and repo context, so no additional PAT scopes are required.

## Required PAT scopes

| Token scope | Why |
|-------------|-----|
| **Build (Read)** | Query build runs and run-log references (`builds` + `builds/{id}/logs`) |
| **Project and Team (Read)** | Enumerate projects when `-AdoProject` is omitted |

## Usage

```powershell
$env:AZURE_DEVOPS_EXT_PAT = "<your-ado-pat>"

# Correlation only (expects ado-repos-secrets output in the same run output folder)
.\Invoke-AzureAnalyzer.ps1 -AdoOrg "contoso" -IncludeTools 'ado-repos-secrets','ado-pipeline-correlator'
```

All HTTP calls use Basic auth. No write scopes required.
