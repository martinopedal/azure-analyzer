# Maester - Required Permissions

**Display name:** Maester

**Scope:** tenant | **Provider:** microsoft365

Maester requires delegated or application permissions to read Entra ID security configuration.

## Required Microsoft Graph permissions

| Permission | Type | Why |
|------------|------|-----|
| **Directory.Read.All** | Application or Delegated | Read Entra ID users, groups, roles, and security configuration |
| **Policy.Read.All** | Application or Delegated | Read conditional access policies, sign-in risk policies, and other security policies |
| **Reports.Read.All** | Application or Delegated | Read sign-in reports and audit logs for security assessment |
| **DirectoryRecommendations.Read.All** | Application or Delegated | Read Entra ID recommendations (preview feature) |

## How to grant

### Interactive use (delegated)

```powershell
# Connect to Graph with required scopes
$scopes = @(
  "Directory.Read.All",
  "Policy.Read.All",
  "Reports.Read.All",
  "DirectoryRecommendations.Read.All"
)
Connect-MgGraph -Scopes $scopes

# Run Maester
.\Invoke-AzureAnalyzer.ps1 -IncludeTools 'maester'
```

### Service principal (application permissions)

1. Go to **Azure Portal** -> **Entra ID** -> **App registrations** -> **Your app**.
2. Select **API permissions**.
3. Click **Add a permission** -> **Microsoft Graph**.
4. Choose **Application permissions**.
5. Search for and select: `Directory.Read.All`, `Policy.Read.All`, `Reports.Read.All`, `DirectoryRecommendations.Read.All`.
6. Click **Grant admin consent** (requires Entra ID admin).

**Important:** Maester does **NOT** modify your tenant. All permissions are read-only.
