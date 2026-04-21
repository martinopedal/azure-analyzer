# AKS Karpenter Cost (consolidation + node utilization) - Required Permissions

**Display name:** AKS Karpenter Cost (consolidation + node utilization)

**Scope:** subscription | **Provider:** azure

This wrapper emits cluster-level and Karpenter-Provisioner cost findings against AKS managed clusters. It runs in two RBAC tiers; the elevated tier is OFF by default and must be opted in per-wrapper invocation.

## RBAC tier table

| Tier | Active when | Roles required | Findings emitted | kubectl invoked? |
|---|---|---|---|---|
| **Reader** (default) | `-EnableElevatedRbac` NOT supplied | `Reader` on AKS cluster, resource group, or subscription + `Log Analytics Reader` on the Container Insights workspace | `aks.node-cost-rollup` (Info), `aks.idle-node` (Medium) | **No** |
| **ClusterUser** (opt-in) | `-EnableElevatedRbac` supplied | All of Reader tier **plus** `Azure Kubernetes Service Cluster User Role` on the AKS cluster | All of Reader tier **plus** `karpenter.consolidation-disabled` (Medium), `karpenter.over-provisioned` (Medium), `karpenter.no-node-limit` (High) | **Yes** (`kubectl get provisioners.karpenter.sh -o json`) |

> **Security note:** the elevated tier is **off by default**. With `-EnableElevatedRbac` omitted the wrapper performs zero kubectl calls, fetches no kubeconfig, and stays inside the same Reader-only envelope as every other azure-analyzer collector.

## Per-wrapper opt-in scoping (vNEXT v1.2.0)

The opt-in flag is **per-wrapper**, not orchestrator-wide. Setting `-EnableElevatedRbac` on this wrapper does not change the RBAC tier of any other tool that runs in the same orchestrator session. The state lives in `modules/shared/RbacTier.ps1` (`Get-RbacTier` / `Set-RbacTier` / `Reset-RbacTier`) and is reset to `Reader` in the wrapper's `finally{}` block.

Future tools that need the same elevated tier should:

1. Add a `-EnableElevatedRbac` switch (default off).
2. Call `Set-RbacTier -Tier 'ClusterUser'` at the top of their body, guarded by the switch.
3. Call `Reset-RbacTier` in `finally{}`.
4. Call `Assert-RbacTier -Required 'ClusterUser' -Capability '...' -OptInFlag '-EnableElevatedRbac'` immediately before the gated work.

## API endpoints used (read-only)

- `Microsoft.ContainerService/managedClusters` via Azure Resource Graph (Reader)
- `Microsoft.Insights/diagnosticSettings` on the AKS cluster (Reader)
- `Microsoft.OperationalInsights/workspaces/query` (Log Analytics Reader)
- `provisioners.karpenter.sh` CRD via `kubectl get` (Cluster User Role; ClusterUser tier only)

## Parameters

- `-SubscriptionId <guid>` (required)
- `-ResourceGroup <name>` (optional filter)
- `-ClusterName <name>` (optional filter)
- `-LogAnalyticsWorkspaceId <arm-id>` (optional override)
- `-LookbackDays <int>` (default `7`, range `1-30`)
- `-KubeconfigPath <path>` (required when `-EnableElevatedRbac` is set)
- `-KubeContext <name>` (optional)
- `-Namespace <name>` (optional; defaults to `-A` all namespaces)
- `-KubeAuthMode <Default|Kubelogin|WorkloadIdentity>` (default `Default`)
- `-EnableElevatedRbac` switch (default OFF)
- `-OutputPath <dir>` (optional)

## Sample commands

Reader tier only (default; safe everywhere Reader is granted):

```powershell
.\Invoke-AzureAnalyzer.ps1 -SubscriptionId "<sub-guid>" -IncludeTools 'aks-karpenter-cost'
```

Elevated tier (Karpenter Provisioner inspection):

```powershell
.\Invoke-AzureAnalyzer.ps1 -SubscriptionId "<sub-guid>" -IncludeTools 'aks-karpenter-cost' `
    -EnableElevatedRbac -KubeconfigPath C:\path\to\kubeconfig -KubeContext aks-prod
```

## What it scans

- Container Insights node-hours per cluster over the lookback window (cost rollup).
- Per-node CPU utilization (idle nodes <10% over the lookback window).
- Karpenter Provisioner spec (consolidation policy + spec.limits) when elevated tier is enabled.
- Per-Provisioner average node CPU utilization (over-provisioned <50% over the lookback window).

## What it does NOT do

- No write operations against AKS, Log Analytics, or Karpenter resources.
- No `kubectl` invocation when `-EnableElevatedRbac` is omitted.
- No cluster admin actions (the Cluster User Role is read-only).
- No kubeconfig retrieval when `-KubeconfigPath` is not supplied; the elevated branch is skipped with a clear error message instead.
