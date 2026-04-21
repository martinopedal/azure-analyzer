# ADO Pipeline Security - Required Permissions

**Display name:** ADO Pipeline Security

**Scope:** ado | **Provider:** ado

The ADO pipeline security collector inspects build definitions, classic release definitions, variable groups, and environments through the Azure DevOps REST API. It focuses on read-only posture signals: missing approvals on production-like environments, classic releases without approval coverage, plaintext secret-like library variables, and service-connection reuse across multiple pipeline assets.

## Required PAT scopes

| Token scope | Why |
|-------------|-----|
| **Build (Read)** | Read build definition metadata and trigger settings |
| **Release (Read)** | Read classic release definitions and stage approval metadata |
| **Library / Variable Groups (Read)** | Read variable-group metadata, secret flags, and Key Vault linkage state |
| **Environment (Read)** | Read environment definitions plus approval / check configuration |
| **Project and Team (Read)** | List projects when `-AdoProject` is omitted |

## How to grant

1. Go to **Azure DevOps** -> **User settings** -> **Personal access tokens**.
2. Click **New Token**.
3. Set **Organization** to the target org (or "All accessible organizations").
4. Under **Scopes**, select:
   - **Build**: Read
   - **Release**: Read
   - **Library / Variable Groups**: Read
   - **Environment**: Read
   - **Project and Team**: Read
5. Set expiration (recommended: 90 days).
6. Copy the token.

## Usage

```powershell
# Recommended for CI or repeat runs
$env:AZURE_DEVOPS_EXT_PAT = "<your-ado-pat>"
.\Invoke-AzureAnalyzer.ps1 -AdoOrg "contoso" -IncludeTools 'ado-pipelines'

# Single project
.\Invoke-AzureAnalyzer.ps1 -AdoOrg "contoso" -AdoProject "payments" -IncludeTools 'ado-pipelines'

# Run both ADO collectors together
.\Invoke-AzureAnalyzer.ps1 -AdoOrg "contoso"
```

## What it scans

- Build definitions for broad CI trigger patterns and deployment identity references.
- Classic release definitions for production stages that lack approvals or gates.
- Variable groups for plaintext secret-like variables and missing Key Vault linkage.
- Environments for missing approval / check coverage on production-like targets.

## What it does NOT do

- No writes back to Azure DevOps.
- No log scraping or pipeline-run mutation.
- No emission of plaintext variable values; only metadata and variable names are surfaced.
- No task reputation scoring or YAML linting outside the scoped posture checks above.
