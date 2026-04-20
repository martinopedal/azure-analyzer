# kubescape - Required Permissions

**Display name:** Kubescape (AKS runtime posture)

**Scope:** subscription | **Provider:** azure

## Required roles

| Capability | Scope | Role | Why |
|---|---|---|---|
| AKS discovery | Subscription | **Reader** | Discovers AKS clusters via Azure Resource Graph |
| In-cluster posture scan | AKS cluster | **AKS cluster-read RBAC** (or kubeconfig with read) | Runs kubescape against the cluster API for misconfigurations, RBAC, network policies, vulnerabilities |

## Local CLI requirements

`kubescape`, `kubectl`, and `az` must be on PATH. Missing CLIs cause the tool to skip with an install instruction.

## What it does with these permissions

kubescape lists AKS clusters via ARG, then connects to each cluster (using `az aks get-credentials`) and runs the kubescape scanner against the live cluster API. All operations are read.

## What it does NOT do

- No cluster mutations: no Job creation, no namespace creation, no RBAC changes.
- No node-level access (use `kube-bench` for node-level CIS checks).
