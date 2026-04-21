# Microsoft Sentinel (Active Incidents) - Required Permissions

**Display name:** Microsoft Sentinel (Active Incidents)

**Scope:** workspace | **Provider:** azure

The Sentinel incidents wrapper queries the Log Analytics workspace API (`/api/query`) with KQL against the `SecurityIncident` table. It reads active (non-closed) incidents including severity, status, classification, owner, and linked alert counts. Incidents are scoped to the workspace ARM resource and fold into the EntityStore alongside Defender for Cloud findings.

## Required roles

| Token / scope | Why |
|---------------|-----|
| **Log Analytics Reader** on the workspace | Required to query the `SecurityIncident` table via the workspace query API |
| (Alternative) **Reader** on the workspace resource group | Sufficient in tenants where Reader permits `Microsoft.OperationalInsights/workspaces/api/query` |

**API endpoint used:** `Microsoft.OperationalInsights/workspaces/{name}/api/query` (read).

## Parameters

- `-SentinelWorkspaceId <ARM-resource-id>` (required): full ARM resource ID of the Log Analytics workspace linked to Sentinel.
- `-SentinelLookbackDays <int>` (default `30`): number of days to look back for active incidents (range 1-365).

## Sample command

```powershell
# Query active Sentinel incidents (last 30 days)
.\Invoke-AzureAnalyzer.ps1 -SubscriptionId "<sub-guid>" `
  -SentinelWorkspaceId "/subscriptions/<sub-guid>/resourceGroups/<rg>/providers/Microsoft.OperationalInsights/workspaces/<ws-name>"

# Custom lookback window (7 days)
.\Invoke-AzureAnalyzer.ps1 -SubscriptionId "<sub-guid>" `
  -SentinelWorkspaceId "/subscriptions/<sub-guid>/resourceGroups/<rg>/providers/Microsoft.OperationalInsights/workspaces/<ws-name>" `
  -SentinelLookbackDays 7

# Sentinel-only run
.\Invoke-AzureAnalyzer.ps1 -SentinelWorkspaceId "/subscriptions/<sub-guid>/resourceGroups/<rg>/providers/Microsoft.OperationalInsights/workspaces/<ws-name>" `
  -IncludeTools 'sentinel-incidents'
```

## What it scans

- Active (non-closed) SecurityIncident records within the lookback window.
- Per-incident metadata: title, severity, status, classification, owner, provider name, alert count, creation and last-modified timestamps.
- Incident URL for portal deep-link.

## What it does NOT do

- No incident closure, assignment, or status modification.
- No analytics rule creation or deployment.
- No alert suppression or dismissal.
- No custom table ingestion or DCR operations.
- Gracefully **skips** when the `SecurityIncident` table does not exist (Sentinel not enabled on the workspace).
