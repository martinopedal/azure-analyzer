# Troubleshooting

Operator and contributor troubleshooting reference. For consumer-facing quickstart issues, start with the root [`README.md`](../../README.md).

## Diagnose tool failures

Every run writes per-tool execution status to `output/tool-status.json`. When a tool reports `Failed` or `Skipped`, inspect:

- `output/errors.json` (only emitted when at least one tool errors). Contains sanitized stderr and the install hint emitted by `New-InstallerError`.
- `output/<tool>/raw.json` (when the tool emits raw output). Useful for normalizer regressions.
- The tool's wrapper at `modules/Invoke-<Tool>.ps1`. Wrappers must not throw; a `Failed` status means the wrapper caught and recorded the failure.

## Missing prerequisites

Run with `-InstallMissingModules` to auto-install via the manifest. Failures fall into three buckets:

| Symptom | Likely cause | Fix |
|---|---|---|
| `winget` or `brew` not found | Package manager itself missing on the runner | Install the manager, or pre-bake the tool into the image. |
| `Install kind 'X' is not supported` | Manifest entry uses a kind outside `{none, psmodule, cli, gitclone}` | Patch the manifest or add the kind to `AllowedInstallKinds` in `Installer.ps1` (gated by review). |
| `Host 'X' is not allow-listed` | Clone or fetch URL falls outside the allow-list | Use `github.com`, `dev.azure.com`, `*.visualstudio.com`, or `*.ghe.com`. Other hosts are rejected by design. |

## Throttling and transient errors

External APIs (ARG, Defender, Graph, GitHub, ADO) are wrapped via `modules/shared/Retry.ps1` (`Invoke-WithRetry`). Retries fire on:

- HTTP status codes `408`, `429`, `500`, `502`, `503`, `504`.
- Exception messages matching `429`, `503`, `throttle`, `throttled`, `timeout`, `timed out`, `connection reset`, `socket`, `transient`.

If a tool fails with a transient pattern that is not yet covered, extend `$TransientMessagePatterns` and add a unit test under `tests/shared/Retry.Tests.ps1`.

## Token / credential surfaced in output

Every artifact written to disk passes through `Remove-Credentials` (`modules/shared/Sanitize.ps1`). If you observe a leaked token:

1. Capture the offending file and line.
2. Add a test fixture under `tests/shared/Sanitize.Tests.ps1` that reproduces the leak.
3. Extend the redaction patterns in `Sanitize.ps1` so the test passes.
4. Re-run the full Pester suite.

Never publish a finding or PR comment containing the unsanitized value.

## Pester baseline drops

The repo baseline is published in the commit message of every release-bearing PR. If your change drops the count:

1. Run `Invoke-Pester -Path .\tests -CI` locally.
2. Filter to failing tests with `Invoke-Pester -Path .\tests\<area> -Output Detailed`.
3. Fix the root cause, never `-Skip` or `-Pending` to ship green (this is a contract violation per `.copilot/copilot-instructions.md`).

## Stale tool catalog

CI fails with `tool-catalog stale relative to manifest` when `docs/consumer/tool-catalog.md` or `docs/contributor/tool-catalog.md` is out of sync with `tools/tool-manifest.json`. Regenerate:

```powershell
pwsh -File scripts/Generate-ToolCatalog.ps1
```

Commit the regenerated files and push.

## Module import surface

`Import-Module .\AzureAnalyzer.psd1` must expose `Invoke-AzureAnalyzer`, `New-HtmlReport`, and `New-MdReport`. If a future change drops one of these from the export surface, the module integrity test under `tests/module/` will fail. Restore the export in `AzureAnalyzer.psd1` (`FunctionsToExport`) and verify with `Test-ModuleManifest .\AzureAnalyzer.psd1`.

## Reporting an unreproducible scan

Collect the following before opening an issue:

- `output/tool-status.json`
- `output/errors.json` (if present)
- The orchestrator command line you ran (with credentials redacted)
- The `Az` and `Microsoft.Graph` module versions (`Get-Module Az.Accounts, Microsoft.Graph.Authentication -ListAvailable | Select Name, Version`)
- PowerShell version (`$PSVersionTable.PSVersion`)

Sanitize before posting.
