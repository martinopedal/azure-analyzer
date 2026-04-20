# Contributing Tools (Collectors + Normalizers)

Adding a new tool to azure-analyzer is a **five-step** process. Reports pick up new tools automatically once they are registered in the manifest — no report code changes needed.

## TL;DR — five steps

1. **Manifest** — add an entry to `tools/tool-manifest.json` with `install` + `report` blocks
2. **Wrapper** — create `modules/Invoke-<Tool>.ps1` (returns `Source`, `Status`, `Message`, `Findings`)
3. **Normalizer** — create `modules/normalizers/Normalize-<Tool>.ps1` (v1 → v2 FindingRow)
4. **Tests** — add fixture under `tests/fixtures/normalizers/` and Pester tests under `tests/normalizers/`
5. **Docs** — update README (tool count, tool table, valid names) and CHANGELOG; update PERMISSIONS.md if the tool needs credentials

Reports (`New-HtmlReport.ps1`, `New-MdReport.ps1`) auto-discover the new tool from the manifest.

---

## Step 1 — Add to `tools/tool-manifest.json`

Every tool entry declares its identity, how to install it, and how reports should render it.

```json
{
  "name": "mytool",
  "displayName": "My Tool",
  "source": "mytool",
  "provider": "azure",
  "scope": "subscription",
  "normalizer": "Normalize-MyTool",
  "invokeMethod": "script",
  "type": "collector",
  "script": "modules/Invoke-MyTool.ps1",
  "requiredParams": ["SubscriptionId"],
  "optionalParams": ["OutputPath"],
  "requiredPermissionTier": 1,
  "platforms": ["windows", "macos", "linux"],
  "enabled": true,
  "report": { "color": "#1565c0", "phase": 4 },
  "install": {
    "kind": "cli",
    "command": "mytool",
    "windows": { "winget": "vendor.mytool" },
    "macos":   { "brew": "vendor/tap/mytool" },
    "linux":   { "url": "https://github.com/vendor/mytool/releases/latest" }
  }
}
```

### `install` block — one of four kinds

| Kind | Example fields | Notes |
|---|---|---|
| `psmodule` | `"modules": ["PSRule", "PSRule.Rules.Azure"]` | Installed from PSGallery via `Install-Module` |
| `cli` | `"command": "mytool"`, per-OS `winget` / `brew` / `pipx` / `pip` / `snap` | Package-name regex and manager allow-list enforced. Only these five managers are accepted. |
| `gitclone` | `"url": "https://github.com/...", "dest": "tools/AzGovViz"` | HTTPS-only; host must be on the allow-list (currently github.com) |
| `none` | — | No-op. Use for tools that ship with the repo. |

The installer runs only when `-InstallMissingModules` is set on `Invoke-AzureAnalyzer.ps1`. See [ARCHITECTURE.md](ARCHITECTURE.md#installer-modulessharedinstallerps1) for security controls (timeout, credential scrubbing, retry).

### `report` block

| Field | Purpose |
|---|---|
| `color` | Hex color used for per-source bar chart and source badge in the HTML/MD reports |
| `phase` | Grouping hint (1–6) matching the tool's release phase; used for report organization |

Reports (`New-HtmlReport.ps1`, `New-MdReport.ps1`) read this block and auto-generate Tool coverage, per-source bars, and Findings by source without any report-code changes.

### `upstream` block — weekly auto-update loop (optional)

Every wrapped upstream tool should declare an `upstream` block so the **Tool auto-update** workflow
(`.github/workflows/tool-auto-update.yml`) can keep the pin fresh and open a PR when a new version ships.

```json
"upstream": {
  "repo": "vendor/mytool",
  "releaseApi": "https://api.github.com/repos/vendor/mytool/releases/latest",
  "pinType": "cli-version",
  "currentPin": "1.2.3"
}
```

| Field | Values | Notes |
|---|---|---|
| `repo` | `owner/name` | GitHub repo for the upstream tool |
| `releaseApi` | URL | GitHub API endpoint returning the latest release (or commit for SHA-pinned tools) |
| `pinType` | `semver`, `cli-version`, `psmodule-version`, `sha` | Controls how the driver compares versions |
| `currentPin` | string | Current pinned version / SHA. The weekly workflow rewrites this on bump. |

The driver (`tools/Update-ToolPins.ps1`) opens one PR per tool. When the release notes match
any of `BREAKING`, `CHANGED:`, `removed flag`, `renamed`, or `schema`, the PR is labelled
`needs-copilot-iteration` and `@copilot` is tagged against the wrapper and normalizer paths
so the iteration loop catches flag/schema drift automatically.

### Compliance framework mappings (`tools/framework-mappings.json`)

Findings are enriched post-normalization with CIS Azure Foundations / NIST 800-53 / PCI-DSS
control mappings by `modules/shared/FrameworkMapper.ps1`. The mapping file is **user-extensible**
— add entries to `tools/framework-mappings.json` without modifying code:

```json
{
  "source": "my-new-tool",
  "match": { "Category": "Encryption" },
  "controls": {
    "CIS":  ["8.1"],
    "NIST": ["SC-13","SC-28"],
    "PCI":  ["3.5","4.1"]
  }
}
```

`match` supports `Category`, `Check`, or `RuleIdPrefix` (prefix-match against `RuleId`).
All findings from a source sharing the same category inherit the mapping, so one line covers
many findings. Scope a run to a single framework via `-Framework CIS|NIST|PCI` on the orchestrator.

---

## Step 2 — Wrapper contract

`modules/Invoke-<Tool>.ps1` is a PowerShell script that runs the tool and returns a single envelope object. Wrappers **must not throw** — catch everything and set `Status` accordingly.

### Input parameters (minimum)

- **Scope identifier** (at least one): `-SubscriptionId`, `-ManagementGroupId`, `-TenantId`, `-Repository`, `-AdoOrg` / `-AdoProject`, `-RepoPath`, `-ScanPath`
- `-OutputPath` (directory for raw artifacts)
- Tool-specific parameters as needed

### Return shape

```powershell
[PSCustomObject]@{
    Source   = 'mytool'
    Status   = 'Success' | 'Skipped' | 'Failed' | 'PartialSuccess'
    Message  = 'Human-readable status or error message'
    Findings = @( <raw tool-specific objects> )
}
```

### Error handling rules

- **Never throw.** Catch and return `Status='Failed'` with a descriptive `Message`.
- **Graceful skip** when the tool is missing or not applicable: `Status='Skipped'` with a pointer to install instructions.
- **Credentials never logged.** Use `Remove-Credentials` from `modules/shared/Sanitize.ps1` on any output passed to `Write-Host` / `Write-Verbose` / report files.
- **External commands:** wrap in `Invoke-WithRetry` (from `modules/shared/Retry.ps1`) for any network-facing calls; it retries on 429/503/throttle/timeout patterns.

---

## Step 3 — Normalizer contract

`modules/normalizers/Normalize-<Tool>.ps1` converts the v1 wrapper envelope into an array of **v2 FindingRow** objects. The orchestrator invokes it with `-ToolResult <envelope>`.

### Requirements

- Accept `[Parameter(Mandatory)] [PSCustomObject] $ToolResult`
- Return `@()` when `$ToolResult.Status -ne 'Success'` or there are no findings
- Call `New-FindingRow` (from `modules/shared/Schema.ps1`) per finding
- Canonicalize IDs via `ConvertTo-CanonicalArmId` / `ConvertTo-CanonicalRepoId` (from `Canonicalize.ps1`)
- Pick one of the **12 valid EntityTypes**: `AzureResource`, `Subscription`, `ManagementGroup`, `ServicePrincipal`, `ManagedIdentity`, `Application`, `User`, `Tenant`, `Repository`, `Workflow`, `Pipeline`, `ServiceConnection`. Platform is derived from EntityType automatically via `Get-PlatformForEntityType`.
- **No side effects, no throws.** Return the array.

### Template

```powershell
function Normalize-MyTool {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [PSCustomObject] $ToolResult
    )

    if ($ToolResult.Status -ne 'Success' -or -not $ToolResult.Findings) {
        return @()
    }

    $runId = [guid]::NewGuid().ToString()
    $normalized = [System.Collections.Generic.List[PSCustomObject]]::new()

    foreach ($finding in $ToolResult.Findings) {
        $resourceId = $finding.ResourceId
        $canonicalId = if ($resourceId -and $resourceId -match '^/subscriptions/') {
            try { ConvertTo-CanonicalArmId -ArmId $resourceId } catch { $resourceId.ToLowerInvariant() }
        } else {
            "mytool/$($finding.Id ?? [guid]::NewGuid().ToString())"
        }

        $row = New-FindingRow `
            -Id ([guid]::NewGuid().ToString()) `
            -Source 'mytool' `
            -EntityId $canonicalId `
            -EntityType 'AzureResource' `
            -Title $finding.Title `
            -Compliant ([bool]$finding.Compliant) `
            -ProvenanceRunId $runId `
            -Category $finding.Category `
            -Severity $finding.Severity `
            -Detail $finding.Description `
            -Remediation $finding.Recommendation `
            -ResourceId ($resourceId ?? '') `
            -LearnMoreUrl ($finding.HelpUrl ?? '')
        $normalized.Add($row)
    }

    return @($normalized)
}
```

### Field-mapping requirements

- **Required**: `Id`, `Source`, `EntityId`, `EntityType`, `Title`, `Compliant`, `ProvenanceRunId`
- **Recommended**: `Category`, `Severity` (one of `Critical`/`High`/`Medium`/`Low`/`Info`), `Detail`, `Remediation`, `ResourceId`, `LearnMoreUrl`
- **Optional**: `Platform` (auto-derived), `SubscriptionId`, `ResourceGroup`, `ManagementGroupPath`, `Frameworks`, `Controls`, `Confidence`, `EvidenceCount`, `MissingDimensions`
- **Unmapped fields** — list them as `# not captured: <reason>` in code comments

---

## Step 4 — Tests

1. **Fixture** — `tests/fixtures/normalizers/mytool-sample.json` (representative raw tool output)
2. **Tests** — `tests/normalizers/Normalize-MyTool.Tests.ps1`

```powershell
Describe 'Normalize-MyTool' {
    It 'converts raw finding to v2 schema' {
        $raw = Get-Content 'tests/fixtures/normalizers/mytool-sample.json' | ConvertFrom-Json
        $toolResult = [PSCustomObject]@{ Source = 'mytool'; Status = 'Success'; Message = ''; Findings = $raw }
        $normalized = Normalize-MyTool -ToolResult $toolResult

        $normalized[0].Source      | Should -Be 'mytool'
        $normalized[0].Compliant   | Should -BeOfType [bool]
        $normalized[0].Id          | Should -Not -BeNullOrEmpty
        $normalized[0].EntityType  | Should -BeIn @('AzureResource','Subscription','ManagementGroup','ServicePrincipal','ManagedIdentity','Application','User','Tenant','Repository','Workflow','Pipeline','ServiceConnection')
    }

    It 'returns empty for non-success envelopes' {
        $toolResult = [PSCustomObject]@{ Source = 'mytool'; Status = 'Skipped'; Message = 'not installed'; Findings = @() }
        Normalize-MyTool -ToolResult $toolResult | Should -BeNullOrEmpty
    }
}
```

---

## Step 5 — Docs

Every new tool PR must update:

- **README.md** — bump the tool count in the opening paragraph, add a row to the "What each tool does" table, add the name to the `Valid tool names` list, and (if needed) add a scoped-run example
- **CHANGELOG.md** — `### Added` entry under `## [Unreleased]` mentioning the tool, its source, and any new CLI parameters
- **PERMISSIONS.md** — add required scopes/tokens if the tool needs any credentials; add a row to the permission matrix
- **docs/ARCHITECTURE.md** — add a row to the Normalizer locations table

---

## Manifest-driven invocation recap

Because the orchestrator, installer, and both report generators all consume `tools/tool-manifest.json`:

- Registering a tool in the manifest is sufficient to make it eligible for execution
- The `install` block drives `-InstallMissingModules` behavior
- The `report` block drives HTML and Markdown report rendering
- The `normalizer` field drives v1 → v2 conversion

No report code changes, no orchestrator code changes — **the manifest is the contract**.
