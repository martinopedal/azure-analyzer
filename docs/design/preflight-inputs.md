# Pre-Flight Required-Input Collection (Design Doc)

**Status:** Draft (scaffold only; implementation pending Foundation PR #435)
**Issue:** #426
**Epic:** #427 (Phase 1 critical path)
**Owner:** iris-preflight track

## 1. Philosophy

azure-analyzer today lets each wrapper bottom out into the underlying tool (azqr,
prowler, kubescape, gh, az, etc.) when a mandatory input is missing. The user
then sees a cryptic upstream error long after the run has started, possibly
after several other tools have already executed.

Pre-flight inverts this. Before any tool is invoked, the orchestrator performs
a **single prompt pass** that:

1. Enumerates every enabled tool in the run.
2. Collects the union of mandatory inputs across all of them.
3. Resolves each input via a deterministic chain (CLI > env > prompt > fail).
4. Fails fast in non-interactive sessions when an input cannot be resolved.

The principle is "one prompt pass, zero in-flight surprises". If the user
provides everything up front (or sets the right env vars), the run is fully
non-interactive from there. If a required input is missing in a non-interactive
context, the run aborts before any external process is spawned.

## 2. Manifest schema extension

`tools/tool-manifest.json` gains a `required_inputs` array per tool entry.
Each element describes one input parameter:

```jsonc
{
  "name": "ManagementGroupId",
  "type": "string",
  "prompt": "Enter the Azure Management Group ID to scan",
  "envVar": "AZURE_MANAGEMENT_GROUP_ID",
  "example": "alz-root",
  "validator": "^[A-Za-z0-9._()-]{1,90}$",
  "conditional": null
}
```

Field semantics:

| Field | Purpose |
| --- | --- |
| `name` | PowerShell parameter name passed to the wrapper. Must match the wrapper's `[Parameter()]` block. |
| `type` | One of `string`, `guid`, `url`, `path`, `bool`, `enum`. Drives validator selection. |
| `prompt` | Human-friendly question shown when interactive prompting is required. |
| `envVar` | Environment variable consulted as the second resolution step. Optional. |
| `example` | Sample value displayed in prompts and error messages. |
| `validator` | Regex (or named validator id) applied after resolution; failure re-prompts or aborts. |
| `conditional` | Optional expression (e.g. `{ "param": "ScanScope", "equals": "managementGroup" }`) that gates whether the input is required for this run. |

The existing `requiredParams` / `optionalParams` arrays remain for back-compat;
`required_inputs` is a strict superset and the source of truth once present.

## 3. Resolution order

For every entry in the union of `required_inputs`:

1. **CLI argument** passed directly to `Invoke-AzureAnalyzer.ps1`
   (e.g. `-ManagementGroupId alz-root`).
2. **Environment variable** named in `envVar` (e.g. `AZURE_MANAGEMENT_GROUP_ID`).
3. **Interactive prompt** using PowerShell's native `Read-Host` (or the wrapper's
   own `[Parameter(Mandatory=$true)]` HelpMessage if invoked directly).
4. **Fail fast** with a rich error naming the param, env var, expected format,
   and example value. In non-interactive sessions step 3 is skipped and we go
   straight to step 4.

Resolution is performed once, up front, in the orchestrator. The resolved value
is then forwarded to every wrapper that declares the same input name, so the
user is never asked twice for the same thing in a single run.

## 4. Mandatory-input catalog (initial)

| Family | Inputs |
| --- | --- |
| Azure (subscription) | `SubscriptionId` (guid), `TenantId` (guid) |
| Azure (MG) | `ManagementGroupId`, `TenantId` |
| Azure (tenant) | `TenantId` |
| GitHub | `GitHubOrg`, `GitHubRepo`, `GitHubToken` (env-only, never prompted in clear) |
| Azure DevOps | `AdoOrg`, `AdoProject`, `AdoPat` (env-only) |
| Kubernetes | `KubeContext` or `KubeConfigPath` |
| Repository scanners (zizmor, gitleaks, trivy, scorecard) | Remote repo URL or local `RepoPath` (mutually exclusive) |
| Microsoft 365 / Entra | `TenantId`, optional `MaesterCommands` |

Tokens and PATs are **never prompted interactively in plaintext**. They must
arrive via environment variable or secure credential store; missing-token paths
fail with a remediation pointing to the env-var name.

## 5. Defense in depth

The pre-flight layer is the primary gate, but every wrapper retains its own
`[Parameter(Mandatory=$true)]` decoration on genuinely mandatory inputs. This
ensures that:

- Wrappers invoked directly (outside the orchestrator) still validate.
- A bug in pre-flight cannot silently bypass the wrapper-level contract.
- Pester tests can target each layer independently.

## 6. Non-interactive detection

A session is treated as non-interactive when any of the following holds:

- `[Console]::IsInputRedirected` returns `$true` (piped stdin, CI logs).
- The orchestrator was invoked with the explicit `-NonInteractive` switch.
- The `CI` environment variable is set to a truthy value (`true`, `1`).
- `[Environment]::UserInteractive` is `$false`.

In non-interactive mode, prompting is suppressed and any unresolved required
input causes an immediate fail-fast with exit code 2 and a sanitized error
naming all unresolved inputs in one shot (so CI users see the full list, not
one at a time).

## 7. Sample manifest entry (azgovviz)

`tools/tool-manifest.json` is a hot file owned by Foundation PR #435 in Phase 0
of epic #427. This scaffold therefore **proposes** the `required_inputs` schema
here without editing the manifest. The actual manifest edit lands either:

- Via direct coordination with #435 (folded into the Foundation PR), or
- In the Phase 1 follow-up to this PR, after #435 has merged.

Worked example to land on the azgovviz entry:

```jsonc
{
  "name": "azgovviz",
  "displayName": "AzGovViz",
  "scope": "managementGroup",
  "requiredParams": ["ManagementGroupId"],
  "required_inputs": [
    {
      "name": "ManagementGroupId",
      "type": "string",
      "prompt": "Enter the Azure Management Group ID for AzGovViz to scan",
      "envVar": "AZURE_MANAGEMENT_GROUP_ID",
      "example": "alz-root",
      "validator": "^[A-Za-z0-9._()-]{1,90}$",
      "conditional": null
    },
    {
      "name": "TenantId",
      "type": "guid",
      "prompt": "Enter the Azure tenant ID",
      "envVar": "AZURE_TENANT_ID",
      "example": "00000000-0000-0000-0000-000000000000",
      "validator": "^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$",
      "conditional": null
    }
  ]
}
```

## 8. Out of scope (this PR)

- Orchestrator integration (`Invoke-AzureAnalyzer.ps1` edits) lands in #435.
- Schema.ps1 changes (entity-store impact) land in #435.
- `tool-manifest.json` edits (hot file, owned by #435 in Phase 0) defer per
  Round 3 reconciliation on epic #427.
- Report rendering of resolved inputs lands in a follow-up.
- This PR ships scaffolding, the proposed schema in this design doc, and
  skipped Pester placeholders only.

## 9. References

- Issue #426 (this work)
- Foundation PR #435 (orchestrator wiring blocker)
- Epic #427 (Phase 1 critical path)
- `modules/shared/Installer.ps1` (manifest-driven precedent for fan-out)
