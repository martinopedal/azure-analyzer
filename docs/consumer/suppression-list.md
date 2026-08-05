# Suppression list

Pass `-SuppressionFile` to mark findings you have already reviewed as suppressed,
so they stop appearing in severity counts and report views on every subsequent run.

```powershell
Invoke-AzureAnalyzer -SubscriptionId "<tenant-id>" -SuppressionFile .\suppressions.json
```

Suppressed findings are **marked, not dropped**. They stay in `results.json`
so the audit trail is intact. The HTML and Markdown reports render a visible
suppression count so the reduction is never mistaken for real remediation
progress. Unused suppression keys are surfaced so a list that silently stops
matching is detected immediately.

## Entry format

`suppressions.json` is a JSON array. Each entry must include a `reason`. Two
entry forms are accepted and can be mixed in the same file.

### Key form (machine-generated)

```json
[
  {
    "key": "a1b2c3d4e5f60718",
    "reason": "Accepted risk: dev subscription, no customer data"
  }
]
```

The key is the first 16 hex characters of SHA-256 over `source|rule|entity`
(all lowercase, trimmed). Get the key from a finding's `FindingKey` field in
`results.json` after the first scan.

### Triple form (human-readable)

```json
[
  {
    "source": "azqr",
    "ruleId": "aks-004",
    "entityId": "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-dev/providers/Microsoft.ContainerService/managedClusters/aks-dev",
    "reason": "Dev cluster, public API server accepted by architecture decision",
    "expires": "2027-01-01"
  }
]
```

The triple form is PR-reviewable without opaque hashes. Both forms route through
the same hash function, so they cannot drift. Use `source`/`ruleId`/`entityId`
when writing suppressions by hand; use `key` when pasting from `results.json`.

## Fields

| Field | Required | Description |
|-------|----------|-------------|
| `key` | ✅ (or triple) | Machine-generated 16-char hex key from `FindingKey` |
| `source` | ✅ (or key) | Tool name, e.g. `azqr`, `maester`, `wara` |
| `ruleId` | ✅ (or key) | Rule identifier from the tool. Falls back to `title` matching when `ruleId` is absent from the finding |
| `entityId` | ✅ (or key) | Canonical entity ID (lowercased ARM id, `tenant:{guid}`, etc.) |
| `reason` | ✅ always | Free-text explanation, required for auditability |
| `expires` | ❌ optional | ISO-8601 date (`YYYY-MM-DD`). Expired entries are logged and ignored |

## Why `Id` is not the suppression key

37 of 38 normalizers fall back to `[guid]::NewGuid()` when the underlying tool
supplies no stable id. A suppression list keyed on `Id` stops matching silently
after the first re-scan, which is worse than having no suppression at all because
the failure is invisible. `FindingKey` is derived from fields that are stable by
construction: the tool name, the rule identifier (or title as fallback), and the
canonical entity id.

## Error behaviour

A malformed `suppressions.json` is a **hard error**. Scanning without requested
suppressions misreports risk posture, so the orchestrator fails fast rather than
silently ignoring a broken file. Individual bad entries within an otherwise valid
file are collected and reported together, not fail-fast per entry.

Expired entries are reported in the console summary and then ignored. Unused keys
(entries that matched nothing in this run) are listed so a key that silently
stops matching is detected at the next scan.

## Example file

```json
[
  {
    "source": "azqr",
    "ruleId": "aks-004",
    "entityId": "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-prod/providers/Microsoft.ContainerService/managedClusters/aks-prod",
    "reason": "Public API server required for GitHub Actions OIDC; firewall rules in place",
    "expires": "2027-06-01"
  },
  {
    "key": "a1b2c3d4e5f60718",
    "reason": "Accepted risk approved in ADO work item #4321"
  }
]
```
