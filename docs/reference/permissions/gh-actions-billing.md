# GitHub Actions billing - Required permissions

**Display name:** GitHub Actions Billing

**Scope:** repository | **Provider:** github

The GitHub Actions billing wrapper reads org billing metrics and workflow run duration telemetry for cost signals. It does not mutate repositories, workflows, or billing settings.

## Required token scopes

| Token scope | Why |
|---|---|
| `read:org` | Read org billing endpoint `/orgs/{org}/settings/billing/actions` |
| `repo` | Read private repository metadata and workflow runs |
| `actions:read` | Read workflow run history under `/repos/{org}/{repo}/actions/runs` |

## Parameters

- `-Org <name>` (required): GitHub organization.
- `-Repo <name>` (optional): single repository filter.
- `-DaysBack <int>` (default `30`): workflow run lookback.
- `-MonthlyBudgetUsd <double>` (optional): soft cost threshold.

## What it scans

- Included versus used org Actions minutes.
- Top repositories by runner minute consumption.
- Long-running workflow anomalies against 30-day baseline.

## What it does NOT do

- No workflow edits or billing changes.
- No secret write operations.
