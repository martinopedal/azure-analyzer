# Permissions troubleshooting

Recipes for diagnosing missing or misconfigured credentials before a scan.

## Azure authentication

```powershell
# Check current Azure context
Get-AzContext

# Switch subscriptions if needed
Set-AzContext -SubscriptionId "<subscription-id>"

# Verify Reader permissions on your subscription
$role = Get-AzRoleAssignment -ObjectId (Get-AzContext).Account.ExtendedProperties.HomeAccountId -RoleDefinitionName Reader
if ($role) { Write-Host "Reader role confirmed" } else { Write-Host "Reader role not found" }
```

## Microsoft Graph authentication

```powershell
# Check Graph connection
Get-MgContext

# Re-authenticate with required scopes if needed
Disconnect-MgGraph
Connect-MgGraph -Scopes "Directory.Read.All", "Policy.Read.All", "Reports.Read.All"
```

## GitHub authentication

```powershell
# Verify token is set
if ($env:GITHUB_AUTH_TOKEN) { Write-Host "Token is set" } else { Write-Host "Token not found in env" }

# Test token rate limits
curl -H "Authorization: token $env:GITHUB_AUTH_TOKEN" https://api.github.com/rate_limit | jq '.rate_limit'
```

## How to grant Azure Reader

```powershell
# Option 1: Azure CLI
az role assignment create `
  --assignee <principal-id-or-email> `
  --role Reader `
  --scope /subscriptions/<subscription-id>

# Option 2: PowerShell
New-AzRoleAssignment `
  -ObjectId <principal-id> `
  -RoleDefinitionName Reader `
  -Scope "/subscriptions/<subscription-id>"
```

### Where to find IDs

- **Object ID (service principal):** `az ad sp show --id <app-id> --query id`
- **Object ID (user):** `az ad user show --id <email> --query id`
- **Subscription ID:** `az account show --query id`
