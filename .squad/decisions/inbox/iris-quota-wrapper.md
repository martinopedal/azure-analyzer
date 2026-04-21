# Iris decision — Azure Quota wrapper (#322)

## Context
Issue #322 requires a new wrapper for azure-quota using Azure CLI fanout, while normalizer work is deferred to #323.

## Decision
Implement modules/Invoke-AzureQuotaReports.ps1 as a v1-envelope collector that:
- accepts -Subscriptions and -Locations filters,
- defaults to all enabled subscriptions (az account list) and per-subscription physical regions (az account list-locations),
- executes az vm list-usage and az network list-usages for each (subscription, location) pair,
- computes compliant as UsagePercent < Threshold with default threshold 80.

## Why
This keeps the wrapper cloud-first and fanout-capable without coupling to normalizer decisions. It also matches the locked mapping (Pillar=Reliability, Category=Capacity, EntityType=Subscription) while preserving raw quota details for #323 normalizer work.
