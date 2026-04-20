# kube-bench - Required Permissions

**Display name:** kube-bench (AKS node-level CIS compliance)

**Scope:** subscription | **Provider:** azure

## Required roles

| Capability | Scope | Role | Why |
|---|---|---|---|
| AKS discovery | Subscription | **Reader** | Discovers AKS clusters via Azure Resource Graph |
| Run kube-bench Job | AKS cluster | **AKS RBAC Admin** on `kube-system` | Creates a temporary kube-bench Job in `kube-system`, then collects node-level CIS results, then deletes the Job |

## Local CLI requirements

`kubectl` must be on PATH. `az` is required only when `-KubeconfigPath` is **not** supplied (otherwise AKS discovery and `az aks get-credentials` are skipped).

## Auth context

`-KubeconfigPath` controls which cluster the temporary kube-bench Job lands in. `-Namespace` selects the Job namespace (default `kube-system`). See [`docs/consumer/k8s-auth.md`](../k8s-auth.md).

## What it does with these permissions

kube-bench needs to run as a Pod on each node to read node-level kubelet configuration. That requires permission to create / delete a Job in `kube-system`. The Job itself is short-lived and the wrapper deletes it after collection. No persistent in-cluster footprint.

## What it does NOT do

- No node modification.
- No persistent workload installation.
- Does not change cluster configuration.

## KubeAuthMode (AAD / Workload Identity)

In addition to `Default` mode (no kubelogin convert), the wrapper supports `-KubeAuthMode Kubelogin` and `-KubeAuthMode WorkloadIdentity` for AAD-integrated AKS. Both modes require the `kubelogin` binary on PATH (auto-installed when `-InstallMissingModules` is used). See [`docs/consumer/k8s-auth.md`](../k8s-auth.md) for the full mode matrix, sub-params, and examples.

| Mode | Extra Azure permission | Extra cluster permission |
|---|---|---|
| `Default` | none beyond Reader | cluster-read RBAC |
| `Kubelogin` | AAD user/SPN must be a member of the cluster's AAD admin/user group; `-KubeloginClientId`/`-KubeloginTenantId` for SPN flow | cluster-read RBAC granted to that AAD identity |
| `WorkloadIdentity` | Federated credential on the AAD app pointing at the pod's service account | cluster-read RBAC granted to the federated identity |
