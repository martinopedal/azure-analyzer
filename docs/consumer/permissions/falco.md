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
- Install mode: `helm`, `kubectl`, `az`.

## What it does with these permissions

In query mode, Falco reads existing runtime alerts emitted by an already-installed Falco daemonset (or by Microsoft Defender's Falco alerts). In install mode, the wrapper helm-installs Falco temporarily, captures runtime telemetry, then uninstalls.

## What it does NOT do

- Query mode does not modify the cluster at all.
- Install mode deploys Falco only into a dedicated namespace and removes it after the capture window.
