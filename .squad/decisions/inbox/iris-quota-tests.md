# Iris decision — Azure Quota wrapper retry semantics (#324)

## Context
- While building deep wrapper tests for `Invoke-AzureQuotaReports.ps1` (#324), transient `az vm list-usage` failures were not retried.
- Root cause: `Invoke-AzJson` / `Invoke-AzNoOutput` returned non-zero `ExitCode` responses from `Invoke-WithTimeout` without throwing inside the `Invoke-WithRetry` script block.

## Decision
- Treat non-zero Azure CLI exit codes as exceptions inside the `Invoke-WithRetry` script block.
- Preserve installer-style failure surfacing by catching retry exceptions and rethrowing through `Throw-QuotaFailure` (`New-InstallerError` payload, sanitized output).

## Why
- `Invoke-WithRetry` retries on thrown errors; returning a failed response object bypassed retry entirely.
- This keeps behavior consistent with the shared retry contract and makes transient CLI/API failures resilient while preserving sanitized diagnostics for permanent failures.

## Impact
- Wrapper now retries transient CLI failures as designed.
- Permanent failures still surface as sanitized `New-InstallerError` payloads.
- New wrapper tests lock this behavior with realistic CLI fixtures.
