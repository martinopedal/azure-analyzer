# WARA - Required Permissions

**Display name:** Well-Architected Reliability Assessment

**Scope:** subscription | **Provider:** azure

## Required roles

| Capability | Scope | Role | Why |
|---|---|---|---|
| WARA collector | Subscription | **Reader** | Collects Well-Architected Framework reliability assessment data |

## What it does with these permissions

WARA reads resource and Resource Graph data per subscription to populate the WAF reliability assessment. Read-only.

## How to grant

See [`_troubleshooting.md`](_troubleshooting.md#how-to-grant-azure-reader).
