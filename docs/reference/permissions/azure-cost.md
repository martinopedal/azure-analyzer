# Azure Cost - Required Permissions

**Display name:** Azure Cost (Consumption API)

**Scope:** subscription | **Provider:** azure

The Azure Cost wrapper queries `Microsoft.Consumption/usageDetails` for a trailing 30-day window per subscription, aggregates spend per resource ID, and folds `MonthlyCost` / `Currency` onto existing AzureResource entities. No new role is required beyond subscription `Reader`, since the Consumption API authorizes off subscription-level read.

## Required roles

| Token / scope | Why |
|---------------|-----|
| **Reader** at subscription scope | Required for `Invoke-AzRestMethod` to call `Microsoft.Consumption/usageDetails` |
| (Optional) **Cost Management Reader** at subscription scope | Recommended for environments where tenant policy restricts Consumption data to the dedicated Cost role; functionally equivalent for this read path |

## Parameters

- `-SubscriptionId <guid>` (required, passed by orchestrator).
- `-TopN <int>` (default `20`): number of top costly resources emitted as findings (range 1..100).
- `-OutputPath <dir>` (optional): write raw API JSON for audit.

## Sample command

```powershell
# Single subscription
.\Invoke-AzureAnalyzer.ps1 -SubscriptionId "<sub-guid>" -IncludeTools 'azure-cost'

# Across an MG (per-subscription discovery applies; cost runs per child sub)
.\Invoke-AzureAnalyzer.ps1 -ManagementGroupId "<mg-id>" -IncludeTools 'azure-cost'
```

## What it scans

- 30-day usage records via `Microsoft.Consumption/usageDetails` (paged, up to 20 pages of 5,000 records).
- Subscription roll-up (total spend, billing currency).
- Top-N costly resources (resource ID, type, location, total cost).

## What it does NOT do

- No budget creation or modification.
- No resource modification (no scaling, deletion, tagging).
- No forecasting or anomaly alerting (point-in-time aggregation only).
- No cross-subscription rebilling or chargeback writes.
- Gracefully **skips** when the subscription has no Consumption data (new sub, trial, CSP without Consumption API access), typically as an empty result set (HTTP 200 with empty `value` array); HTTP 404 is treated as an access / scope / availability edge case.
