# kube-bench - Required Permissions

**Display name:** kube-bench (AKS node-level CIS compliance)

**Scope:** subscription | **Provider:** azure

## Required roles

| Capability | Scope | Role | Why |
|---|---|---|---|
| AKS discovery | Subscription | **Reader** | Discovers AKS clusters via Azure Resource Graph |
| Run kube-bench Job | AKS cluster | **AKS RBAC Admin** on `kube-system` | Creates a temporary kube-bench Job in `kube-system`, then collects node-level CIS results, then deletes the Job |

## Local CLI requirements

`kubectl` and `az` must be on PATH.

## What it does with these permissions

kube-bench needs to run as a Pod on each node to read node-level kubelet configuration. That requires permission to create / delete a Job in `kube-system`. The Job itself is short-lived and the wrapper deletes it after collection. No persistent in-cluster footprint.

## What it does NOT do

- No node modification.
- No persistent workload installation.
- Does not change cluster configuration.
