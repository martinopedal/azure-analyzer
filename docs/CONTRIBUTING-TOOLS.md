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

---

## Writing normalizers (Phase 1)

Normalizers convert raw tool output into schema v2 FindingRow format. They are called automatically by the orchestrator after a tool collector finishes.

### Normalizer template

```powershell
function Normalize-MyTool {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [object[]]$Findings,
        
        [Parameter(Mandatory=$false)]
        [string]$SubscriptionId,
        
        [Parameter(Mandatory=$false)]
        [string]$ResourceGroup
    )
    
    $normalized = @()
    
    foreach ($finding in $Findings) {
        # Extract ResourceId from raw finding (if applicable)
        $resourceId = $finding.ResourceId
        if (-not $resourceId -and $finding.TargetName) {
            $resourceId = $finding.TargetName
        }
        
        # Map to v2 schema
        $normalized += [PSCustomObject]@{
            Id           = [guid]::NewGuid().ToString()
            Source       = 'mytool'
            Category     = $finding.Category
            Title        = $finding.Title
            Severity     = $finding.Severity
            Compliant    = $finding.Compliant
            Detail       = $finding.Description
            Remediation  = $finding.Recommendation
            ResourceId   = $resourceId
            LearnMoreUrl = $finding.HelpUrl
        }
    }
    
    return $normalized
}
```

### Step 1: Registering in tool-manifest.json

Add or update the tool entry:

```json
{
  "name": "mytool",
  "provider": "Azure",
  "scope": "Subscription",
  "collector": "modules/Invoke-MyTool.ps1",
  "normalizer": "modules/normalizers/Normalize-MyTool.ps1",
  "permissionTier": 1
}
```

The `normalizer` field points to your new normalizer script.

### Step 2: Field mapping requirements

Ensure all raw fields are mapped:

- **Required v2 fields**: `Id`, `Source`, `Category`, `Title`, `Severity`, `Compliant`, `Detail`
- **Optional v2 fields**: `Remediation`, `ResourceId`, `LearnMoreUrl`
- **Unmapped fields**: List them as `not captured: <reason>` in code comments

### Step 3: ResourceId extraction

Parse ARM ResourceIds to extract subscription and resource group when possible:

```powershell
# Example: /subscriptions/abc123/resourceGroups/rg1/providers/Microsoft.Compute/virtualMachines/vm1
if ($resourceId -match '/subscriptions/([^/]+)/resourceGroups/([^/]+)') {
    $subscriptionId = $matches[1]
    $resourceGroup = $matches[2]
}
```

### Step 4: Testing

Create a test fixture and test file:

1. **Fixture**: `tests/fixtures/normalizers/mytool-sample.json` (raw tool output)
2. **Test**: `tests/normalizers/Normalize-MyTool.Tests.ps1`

Example test:

```powershell
Describe 'Normalize-MyTool' {
    It 'converts raw finding to v2 schema' {
        $raw = Get-Content 'tests/fixtures/normalizers/mytool-sample.json' | ConvertFrom-Json
        $normalized = Normalize-MyTool -Findings $raw
        
        $normalized[0].Source | Should -Be 'mytool'
        $normalized[0].Compliant | Should -BeOfType [bool]
        $normalized[0].Id | Should -Not -BeNullOrEmpty
    }
}
```

---
