# Azure Quota Reports - Required Permissions

**Display name:** Azure Quota Reports

**Scope:** subscription | **Provider:** azure

The Azure Quota Reports tool uses Azure CLI quota APIs to read current quota utilization and limits per subscription, provider, and region. It is read-only and does not create quota increase requests or modify any resources.

## Required roles

| Token / scope | Why |
|---------------|-----|
| **Reader** at subscription scope | Required to query current quota usage and limits through Azure management-plane read APIs |

## Parameters

- `-SubscriptionId <guid>` (required, passed by orchestrator).
- `-OutputPath <dir>` (optional): write wrapper output for audit.

## Sample command

```powershell
# Single subscription
.\Invoke-AzureAnalyzer.ps1 -SubscriptionId "<sub-guid>" -IncludeTools 'azure-quota'

# Across an MG (runs per discovered subscription)
.\Invoke-AzureAnalyzer.ps1 -ManagementGroupId "<mg-id>" -IncludeTools 'azure-quota'
```

## What it scans

- Subscription quota usage and limits for supported resource providers.
- Usage percentage bands to highlight approaching/exceeded capacity.
- Region/provider/sku-level capacity pressure indicators.

## What it does NOT do

- No quota increase requests.
- No support tickets.
- No resource writes or deployment changes.
