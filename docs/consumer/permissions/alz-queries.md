# ALZ Resource Graph Queries - Required Permissions

**Display name:** ALZ Resource Graph Queries

**Scope:** managementGroup | **Provider:** azure

## Required roles

| Capability | Scope | Role | Why |
|---|---|---|---|
| ARG query execution | Subscription or MG | **Reader** | Runs the curated ALZ query set (132+) via Azure Resource Graph |

## What it does with these permissions

The wrapper executes `Search-AzGraph` against the queries shipped under `queries/`. Each query returns a `compliant` column. No writes, no resource modification.

## How to grant

See [`_troubleshooting.md`](_troubleshooting.md#how-to-grant-azure-reader).
