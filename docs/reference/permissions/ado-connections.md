# ADO Service Connections - Required Permissions

**Display name:** ADO Service Connections

**Scope:** ado | **Provider:** ado

The ADO service connection scanner requires a Personal Access Token (PAT) with read access to service endpoints.

## Required PAT scopes

| Token scope | Why |
|-------------|-----|
| **Service Connections (Read)** | Read service connection metadata (type, auth scheme, sharing status) across projects |
| **Project and Team (Read)** | List projects in the organization when `-AdoProject` is omitted |

## How to grant

1. Go to **Azure DevOps** -> **User settings** -> **Personal access tokens**.
2. Click **New Token**.
3. Set **Organization** to the target org (or "All accessible organizations").
4. Under **Scopes**, select:
   - **Service Connections**: Read
   - **Project and Team**: Read
5. Set expiration (recommended: 90 days).
6. Copy the token.

## Usage

```powershell
# Option 1: Environment variable (recommended for CI)
$env:AZURE_DEVOPS_EXT_PAT = "<your-ado-pat>"
.\Invoke-AzureAnalyzer.ps1 -AdoOrg "contoso"
# Alternative env var:
$env:ADO_PAT_TOKEN = "<your-ado-pat>"
.\Invoke-AzureAnalyzer.ps1 -AdoOrganization "contoso"

# Option 2: Explicit parameter
.\Invoke-AzureAnalyzer.ps1 -AdoOrg "contoso" -AdoProject "my-project" -AdoPatToken "<your-ado-pat>"
# (PAT can also be resolved from ADO_PAT_TOKEN, AZURE_DEVOPS_EXT_PAT, or AZ_DEVOPS_PAT env vars)

# Option 3: Combine with Azure assessment
.\Invoke-AzureAnalyzer.ps1 -SubscriptionId "..." -AdoOrg "contoso"
```

**Important:** The ADO scanner does **NOT** modify service connections or project settings. All API calls are read-only (`GET`).

Schema 2.2 metadata emitted by this tool (for example `Impact`, `Effort`, `DeepLinkUrl`, `EvidenceUris`, and auth-derived `BaselineTags`) is derived from the same read-only service-endpoint and project APIs listed above. No additional PAT scopes are needed.

This inventory surface pairs well with [`ado-pipelines`](ado-pipelines.md), which answers where those identities are consumed.
