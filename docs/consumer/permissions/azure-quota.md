# Azure Quota Reports - Required Permissions

**Display name:** Azure Quota Reports

**Scope:** subscription | **Provider:** azure

The Azure Quota Reports tool uses Azure CLI quota APIs to read current quota utilization and limits per subscription, provider, and region. It is read-only and does not create quota increase requests or modify any resources.

## Required roles

| Token / scope | Why |
|---------------|-----|
| **Reader** at subscription scope | Required to query current quota usage and limits through Azure management-plane read APIs |

## Parameters

- `-SubscriptionId <guid>` (optional): single-subscription run.
- `-Subscriptions <guid[]>` (optional): explicit fanout list. When neither flag is supplied the wrapper enumerates every subscription returned by `az account list`.
- `-Locations <string[]>` (optional): restrict the region fanout. Defaults to the locations enabled for each subscription.
- `-Threshold <int>` (optional, default `80`): usage percentage at or above which a quota row is treated as non-compliant.
- `-OutputPath <dir>` (optional): write the wrapper envelope to disk for audit.

## Azure CLI commands invoked

The wrapper performs read-only fanout across `subscription x location` and shells out to:

- `az account list -o json` (subscription discovery)
- `az account list-locations --subscription <sub> -o json` (region discovery)
- `az vm list-usage --location <region> --subscription <sub> -o json`
- `az network list-usages --location <region> --subscription <sub> -o json`

Every external call is wrapped in `Invoke-WithTimeout` (300s) and `Invoke-WithRetry` for transient throttling. No write commands and no support-ticket APIs are touched.

## Sample command

```powershell
# Single subscription, default 80% threshold
.\Invoke-AzureAnalyzer.ps1 -SubscriptionId "<sub-guid>" -IncludeTools 'azure-quota'

# Across a management group (runs per discovered subscription)
.\Invoke-AzureAnalyzer.ps1 -ManagementGroupId "<mg-id>" -IncludeTools 'azure-quota'

# Stricter capacity gate (alert at 70%)
.\Invoke-AzureAnalyzer.ps1 -SubscriptionId "<sub-guid>" -IncludeTools 'azure-quota' `
    -ToolParameters @{ 'azure-quota' = @{ Threshold = 70 } }
```

## Sample output

A normalized `FindingRow` from `Normalize-AzureQuotaReports` looks like:

```json
{
  "Source": "azure-quota",
  "EntityId": "/subscriptions/00000000-0000-0000-0000-000000000000",
  "EntityType": "Subscription",
  "Title": "Quota standardDSv3Family in westeurope is at 92%",
  "RuleId": "azure-quota:vm:standardDSv3Family:westeurope",
  "Compliant": false,
  "Severity": "Medium",
  "Pillar": "Reliability",
  "Category": "Capacity",
  "CurrentValue": 92,
  "Limit": 100,
  "UsagePercent": 92,
  "Threshold": 80,
  "Location": "westeurope",
  "Service": "vm"
}
```

## Severity ladder

`UsagePercent` (`current / limit * 100`) drives both severity and the `Compliant` flag. The ladder is locked in `modules/normalizers/Normalize-AzureQuotaReports.ps1`:

| UsagePercent | Severity | Compliant |
|---|---|---|
| `>= 99` | Critical | false |
| `>= 95` | High | false |
| `>= Threshold` (default 80) | Medium | false |
| `< Threshold` | Info | true |

Lowering `-Threshold` shifts more rows into the `Medium` band and into the non-compliant set; it does not change the `High` or `Critical` cutoffs.

## What it scans

- Compute quota (`az vm list-usage`): VM family vCPUs, total regional vCPUs, availability sets, etc.
- Networking quota (`az network list-usages`): VNets, public IPs, NSGs, load balancers, application gateways.
- Per `subscription x region` fanout, with each row tagged with `Service`, `SkuName`, `CurrentValue`, `Limit`, and computed `UsagePercent`.

## What it does NOT do

- No quota increase requests.
- No support ticket creation.
- No resource writes or deployment changes.
- No cross-tenant calls; the wrapper stays inside the signed-in `az` context.
