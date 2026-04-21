# Falco - Required Permissions

**Display name:** Falco (AKS runtime anomaly detection)

**Scope:** subscription | **Provider:** azure

## Required roles

| Capability | Scope | Role | Why |
|---|---|---|---|
| Query mode | Subscription | **Reader** | Reads Falco runtime alerts already present in Azure (`Microsoft.Security` alert query, ARG) |
| Install mode (optional) | AKS cluster | **AKS cluster-read RBAC** | Deploys Falco to AKS via `helm` for short-lived runtime capture |

## Local CLI requirements

- Query mode: none beyond `az` for subscription auth.
- Install mode: `helm`, `kubectl`. `az` is required only when `-KubeconfigPath` is **not** supplied (otherwise AKS discovery and `az aks get-credentials` are skipped).

## Auth context

`-KubeconfigPath` (orchestrator or wrapper) controls which cluster Falco install mode targets. Query mode is unaffected by `-KubeconfigPath` because it reads Azure-side alerts, not cluster state. The Helm release namespace and `kubectl logs` namespace come from `-Namespace` (default `falco`). See [`docs/consumer/k8s-auth.md`](../k8s-auth.md).

## What it does with these permissions

In query mode, Falco reads existing runtime alerts emitted by an already-installed Falco daemonset (or by Microsoft Defender's Falco alerts). In install mode, the wrapper helm-installs Falco temporarily, captures runtime telemetry, then uninstalls.

## What it does NOT do

- Query mode does not modify the cluster at all.
- Install mode deploys Falco only into a dedicated namespace and removes it after the capture window.

## KubeAuthMode (AAD / Workload Identity)

In addition to `Default` mode (no kubelogin convert), the wrapper supports `-KubeAuthMode Kubelogin` and `-KubeAuthMode WorkloadIdentity` for AAD-integrated AKS. Both modes require the `kubelogin` binary on PATH (auto-installed when `-InstallMissingModules` is used). See [`docs/consumer/k8s-auth.md`](../k8s-auth.md) for the full mode matrix, sub-params, and examples.

| Mode | Extra Azure permission | Extra cluster permission |
|---|---|---|
| `Default` | none beyond Reader | cluster-read RBAC |
| `Kubelogin` | AAD user/SPN must be a member of the cluster's AAD admin/user group; `-KubeloginClientId`/`-KubeloginTenantId` for SPN flow | cluster-read RBAC granted to that AAD identity |
| `WorkloadIdentity` | Federated credential on the AAD app pointing at the pod's service account | cluster-read RBAC granted to the federated identity |
