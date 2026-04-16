# Contributing Tools (Collectors + Normalizers)

## Add a new tool collector

1. **Create the wrapper**
   - `modules/Invoke-{ToolName}.ps1`
   - Follow the wrapper contract (see below)
2. **Create the normalizer**
   - `modules/Normalize-{ToolName}.ps1`
   - Map raw output into schema v2
3. **Register in the manifest**
   - Add an entry in `tools/tool-manifest.json`
4. **Add fixtures**
   - `tests/fixtures/{toolname}-sample.json`
5. **Add normalizer tests**
   - `tests/normalizers/{ToolName}.Tests.ps1`

---

## Wrapper contract

Each tool wrapper is responsible for executing the tool and returning a
consistent result object. Wrappers **must not throw** — they return a status
and message instead.

### Input parameters

Minimum required parameters (tool-specific additions are allowed):

- **Scope identifiers** (one or more):
  - `-SubscriptionId`
  - `-ManagementGroupId`
  - `-TenantId`
  - `-Repository`
  - `-AdoOrg`, `-AdoProject`
- `-OutputPath` (directory for raw artifacts)
- `-IncludeSensitiveDetails` (optional, for redacted vs full output)

### Output shape

Return a single object with these fields:

```powershell
[PSCustomObject]@{
    Source   = 'tool-name'
    Status   = 'Success' | 'Skipped' | 'Failed'
    Message  = 'Human-readable status or error message'
    Findings = @()  # raw or normalized findings, depending on wrapper stage
}
```

### Error handling rules

- **Never throw** out of the wrapper.
- **Catch and return**: set `Status = 'Failed'` and populate `Message`.
- **Graceful skips**: if a tool is missing or not applicable, set
  `Status = 'Skipped'` with an explanatory message.

---

## Normalizer contract

Normalizers convert raw tool output into the schema v2 finding shape.

### Requirements

- Map every raw field into a v2 field **or** explicitly list the field as:
  `not captured: <reason>`.
- Enforce required fields: `Id`, `Source`, `Category`, `Title`, `Severity`,
  `Compliant`, `Detail`.
- Use canonical `ResourceId` whenever possible.
- Return an array of findings only — no side effects.

---

## Manifest entry example

```json
{
  "name": "exampletool",
  "provider": "Azure",
  "scope": "Subscription",
  "collector": "modules/Invoke-ExampleTool.ps1",
  "normalizer": "modules/Normalize-ExampleTool.ps1",
  "permissionTier": 1
}
```

---

## Testing checklist

- Fixture file added under `tests/fixtures/`
- Normalizer tests added under `tests/normalizers/`
- Wrapper returns `Status`, `Message`, and `Findings` consistently
