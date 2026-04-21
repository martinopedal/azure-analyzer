# AKS Rightsizing (Container Insights utilization) - Required Permissions

**Display name:** AKS Rightsizing (Container Insights utilization)

**Scope:** subscription | **Provider:** azure

The AKS rightsizing wrapper discovers AKS managed clusters, resolves each cluster's Container Insights Log Analytics workspace, and runs read-only KQL over `Perf` and `KubePodInventory` to detect over-provisioning, under-provisioning, missing HPA candidates, and OOMKilled workloads.

## Required roles

| Token / scope | Why |
|---|---|
| **Reader** on AKS cluster, resource group, or subscription | Required to discover AKS clusters and read cluster diagnostic settings |
| **Log Analytics Reader** on the Container Insights workspace | Required to run KQL queries on `Perf` and `KubePodInventory` |

## API endpoints used (read-only)

- `Microsoft.ContainerService/managedClusters` via Azure Resource Graph
- `Microsoft.Insights/diagnosticSettings` on AKS cluster resources
- `Microsoft.OperationalInsights/workspaces/query` via `Invoke-AzOperationalInsightsQuery`

## Parameters

- `-SubscriptionId <guid>` (required)
- `-ResourceGroup <name>` (optional filter)
- `-ClusterName <name>` (optional filter)
- `-LogAnalyticsWorkspaceId <arm-id-or-workspace-id>` (optional override)
- `-LookbackDays <int>` (default `7`)

## Sample command

```powershell
.\Invoke-AzureAnalyzer.ps1 -SubscriptionId "<sub-guid>" -IncludeTools 'aks-rightsizing'
```

## What it scans

- P95 CPU and memory utilization compared to configured limits.
- Static replica patterns that are HPA candidates.
- OOMKilled workload signals from pod inventory.

## What it does NOT do

- No scaling changes on AKS workloads.
- No pod restarts or cluster updates.
- No write operations against Azure resources or Log Analytics.
