# azqr - Required Permissions

**Display name:** Azure Quick Review

**Scope:** subscription | **Provider:** azure

## Required roles

| Capability | Scope | Role | Why |
|---|---|---|---|
| Resource configuration scan | Subscription | **Reader** | Scans resource configurations against the azqr compliance ruleset (read-only) |

## What it does with these permissions

azqr reads resource manifests across the subscription and evaluates each resource against its built-in best-practice rules. No writes, no policy assignment, no role-assignment reads beyond inherited Reader.

## How to grant

See [`_troubleshooting.md`](_troubleshooting.md#how-to-grant-azure-reader) for `az` and PowerShell snippets to assign Reader at subscription scope.
