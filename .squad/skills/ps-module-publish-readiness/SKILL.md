# Skill: PowerShell module publish readiness

**Purpose:** Fast checklist for making a PowerShell module consumption-safe and PSGallery-ready without changing runtime behavior.

## When to use

- Before first PSGallery publish.
- When import behavior is flaky or script entry points execute during `Import-Module`.
- When manifest metadata is incomplete or still has placeholder identifiers.

## Checklist

1. **Root path correctness**
   - In `<Module>.psm1`, set module root to `$PSScriptRoot`.
   - Avoid `Split-Path -Parent $PSScriptRoot` unless scripts truly live outside the module folder.

2. **Import safety**
   - Do not dot-source script entry points with top-level `param(...)` + execution flow at import time.
   - Export wrapper functions from the module that invoke entry scripts on demand.
   - Keep import-time dot-sourcing limited to helper/function-library scripts.

3. **Manifest hygiene (`<Module>.psd1`)**
   - Rotate placeholder GUID with `[guid]::NewGuid()`.
   - Populate `PrivateData.PSData`:
     - `Tags`
     - `ProjectUri`
     - `LicenseUri`
     - `ReleaseNotes`
   - Leave `HelpInfoUri` absent unless Updatable Help is implemented.

4. **Validation gates**
   - `Import-Module .\<Module>.psd1 -Force -ErrorAction Stop`
   - `Get-Command -Module <ModuleName>` includes expected exported commands.
   - `Test-ModuleManifest .\<Module>.psd1` succeeds and returns populated PSData fields.
   - Add a focused Pester import test file and run full suite.

5. **String hygiene**
   - If repo enforces typography gates, run exact grep gates (for example em-dash exclusion) on modified module and test files before commit.

## Provenance

- Derived from azure-analyzer PR #244 (module root resolution + manifest PSData completion, 2026-04-20).
