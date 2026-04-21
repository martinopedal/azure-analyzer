# FinOps Signals - Required Permissions

**Display name:** FinOps Signals (Idle Resource Detection)

**Scope:** subscription | **Provider:** azure

The FinOps wrapper runs `queries/finops/finops-*.json` against Azure Resource Graph and joins findings with monthly waste estimates from the Cost Management query API. This surfaces likely idle spend areas such as unattached disks, deallocated VMs, unused public IPs, idle App Service Plans, empty resource groups, and idle network controls.

## Required roles

| Token / scope | Why |
|---------------|-----|
| **Reader** at subscription scope | Required for `Search-AzGraph` over `resources` and `resourcecontainers` tables |
| **Cost Management Reader** at subscription scope | Required in restricted tenants for `Microsoft.CostManagement/query` |
| (Alternative) **Reader** at subscription scope | Sufficient in tenants where Reader can call Cost Management query read endpoints |

**API namespaces used:** `Microsoft.ResourceGraph/*` (read), `Microsoft.CostManagement/query` (read).

## Parameters

- `-SubscriptionId <guid>` (required, passed by orchestrator).
- `-OutputPath <dir>` (optional): write wrapper JSON output for audit.

## Sample command

```powershell
# Single subscription FinOps-only run
.\Invoke-AzureAnalyzer.ps1 -SubscriptionId "<sub-guid>" -IncludeTools 'finops'

# Across an MG (runs per discovered subscription)
.\Invoke-AzureAnalyzer.ps1 -ManagementGroupId "<mg-id>" -IncludeTools 'finops'
```

## What it does NOT do

- No resource mutations, deletions, stop / start actions, or tagging.
- No budget creation or alert policy changes.
- No rightsizing recommendations outside the curated idle-signal set.
