# `queries/library/` - Reference KQL catalogs

This folder holds **hand-curated KQL query catalogs** that mirror queries embedded inline in wrapper modules. They are **reference material**, not data files consumed by the orchestrator.

## Convention

- Files at the top of `queries/` (e.g. `alz_additional_queries.json`, `finops-*.json`) are **read by a wrapper** - the orchestrator depends on them.
- Files under `queries/library/` are **not loaded by any wrapper**. They exist to:
  1. Document the canonical KQL that lives inline in the corresponding `Invoke-*.ps1` module.
  2. Give operators a copy-pasteable starting point for ad-hoc Log Analytics / App Insights / Container Insights investigations.
  3. Provide an obvious extraction target if a future refactor moves inline KQL to JSON.

## Current contents

| File | Mirrors inline KQL in |
| --- | --- |
| `appinsights-slow-requests.json` | `modules/Invoke-AppInsights.ps1` (`$slowRequestQuery`) |
| `appinsights-dependency-failures.json` | `modules/Invoke-AppInsights.ps1` (`$dependencyFailureQuery`) |
| `appinsights-exception-rate.json` | `modules/Invoke-AppInsights.ps1` (`$exceptionRateQuery`) |
| `aks-rightsizing-missing-hpa.json` | `modules/Invoke-AksRightsizing.ps1` (`$querySet`) |
| `aks-rightsizing-oomkilled.json` | `modules/Invoke-AksRightsizing.ps1` (`$querySet`) |
| `aks-rightsizing-over-provisioned.json` | `modules/Invoke-AksRightsizing.ps1` (`$querySet`) |
| `aks-rightsizing-under-provisioned.json` | `modules/Invoke-AksRightsizing.ps1` (`$querySet`) |

## Rules for adding files here

1. The wrapper's inline KQL is the source of truth. If you edit a `library/` file, update the wrapper too - they must stay in sync.
2. New entries must follow the existing JSON schema (`metadata`, `queries[].guid|category|severity|kql|graph`).
3. Do **not** put files here if a wrapper actually reads them - those belong at the top of `queries/`.
4. The orphan-query audit (see `.squad/decisions.md` → ALZ Queries SoT section) treats anything in `queries/` not referenced by a wrapper as a candidate for either wiring up, deletion, or moving here. If in doubt, default to wiring up.
