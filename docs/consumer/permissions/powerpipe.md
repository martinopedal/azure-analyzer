# powerpipe - Required Permissions

**Display name:** Powerpipe Compliance Benchmarks

**Scope:** subscription | **Provider:** azure

## Required roles

| Capability | Scope | Role | Why |
|---|---|---|---|
| Azure control evaluation | Subscription | **Reader** | Reads resource configuration evaluated by control-pack queries |

## Local CLI requirements

`powerpipe` must be on PATH. Missing CLI causes the wrapper to skip with an install message.

## What it does with these permissions

Runs Powerpipe control packs and emits normalized compliance findings, including framework references, baseline tags, evidence links, and remediation snippets.

## What it does NOT do

- No resource writes or policy assignments.
- No role changes, no deployment actions, no data-plane mutation.
