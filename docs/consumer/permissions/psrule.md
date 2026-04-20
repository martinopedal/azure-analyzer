# PSRule for Azure - Required Permissions

**Display name:** PSRule for Azure

**Scope:** subscription | **Provider:** azure

## Required roles

| Capability | Scope | Role | Why |
|---|---|---|---|
| Rule-based policy evaluation | Subscription | **Reader** | Evaluates resources against PSRule's Well-Architected and best-practice rule baseline |

## What it does with these permissions

PSRule reads resource configuration via the standard ARM read endpoints and runs each rule offline. No writes, no policy creation.

## How to grant

See [`_troubleshooting.md`](_troubleshooting.md#how-to-grant-azure-reader).
