# kubescape - Required Permissions

**Display name:** Kubescape (AKS runtime posture)

**Scope:** subscription | **Provider:** azure

## Required roles

| Capability | Scope | Role | Why |
|---|---|---|---|
| AKS discovery | Subscription | **Reader** | Discovers AKS clusters via Azure Resource Graph |
| In-cluster posture scan | AKS cluster | **AKS cluster-read RBAC** (or kubeconfig with read) | Runs kubescape against the cluster API for misconfigurations, RBAC, network policies, vulnerabilities |

## Local CLI requirements

`kubescape`, `kubectl`, and `az` must be on PATH. Missing CLIs cause the tool to skip with an install instruction. When `-KubeconfigPath` is supplied (BYO cluster mode), `az` is not required.

## Auth context

`-KubeconfigPath` (passed via the orchestrator or directly to the wrapper) controls which cluster kubescape scans. When supplied, AKS discovery via ARG and `az aks get-credentials` are skipped and the wrapper runs a single scan against the cluster reachable via that kubeconfig (optionally filtered by `-KubeContext` and `-Namespace`). See [`docs/consumer/k8s-auth.md`](../k8s-auth.md).

## What it does with these permissions

kubescape lists AKS clusters via ARG, then connects to each cluster (using `az aks get-credentials`) and runs the kubescape scanner against the live cluster API. All operations are read.

## What it does NOT do

- No cluster mutations: no Job creation, no namespace creation, no RBAC changes.
- No node-level access (use `kube-bench` for node-level CIS checks).
