# Future feature: IaC validation + drift detection

**Status:** Design only. Not implemented. No tracking issue. Do not
prioritize until explicitly scheduled.

## Problem

azure-analyzer is a cloud-first posture tool. Teams also define desired
state in Infrastructure-as-Code (IaC): Bicep, ARM, Terraform, Pulumi,
Crossplane, Kustomize/Helm overlays, etc. Today we scan *live* Azure and
*repositories* independently — we do not:

1. Validate the IaC itself (lint, schema, policy-as-code, secret scan).
2. Compare declared desired state against what actually exists in the
   subscription (drift).
3. Flag resources in Azure that have no corresponding IaC definition
   (shadow resources).

The result: gaps between what teams think they shipped and what's
running are invisible to the tool.

## Goals

- One orchestrator run produces **three correlated views** of each
  resource: declared (IaC), deployed (Azure ARM), observed (runtime).
- Discrepancies between any two views raise a finding with
  `category = Drift`.
- Works for the major IaC flavours without a separate runner per
  language — pluggable adapters.
- Pure read-only; never mutates live Azure or the IaC repo.

## Non-goals

- Not a policy authoring tool — reuse PSRule / Checkov / tfsec output.
- Not a deployment engine — this is observability, not enforcement.
- Not a full state reconciler — we emit findings, not remediation plans.

## Proposed architecture

```
   repo (IaC) -------> adapter ----.
                                    \
   Azure ARM --------> normalizer ---> drift-engine -----> findings
                                    /
   runtime (AKS/ACA) > collector --'
```

### 1. IaC adapters (new `modules/iac/`)

One adapter per flavour, each producing a canonical **declared resource
set** (JSON):

| Flavour    | Backing tool                                     | Notes |
|------------|---------------------------------------------------|-------|
| Bicep      | `bicep build` → ARM JSON → parser                 | Native Azure format |
| ARM        | parse directly                                    | — |
| Terraform  | `terraform plan -out` + `terraform show -json`    | Requires init or use `tfstate`/plan file |
| Pulumi     | `pulumi preview --json` or stack export           | Language-agnostic via IR |
| Crossplane | parse `Composition`/`XR` manifests                | Kubernetes-style |
| Helm       | `helm template` → k8s manifests                   | Lower priority |

Each adapter returns:
- `ResourceId` (normalized canonical form, reusing `Canonicalize.ps1`)
- `ResourceType` (ARM provider namespace/type)
- `DeclaredProperties` (hashtable of structural props)
- `SourceFile` + line number

### 2. IaC validation pass (findings, not drift)

Run existing validators in parallel. All outputs feed the existing
normalizer contract (v1 wrapper → v2 FindingRow):

| Language    | Tool                                         |
|-------------|----------------------------------------------|
| Bicep / ARM | PSRule.Rules.Azure (already wired), `bicep build` |
| Terraform   | `tfsec`, `checkov`, `terraform validate`     |
| Pulumi      | `pulumi policy`, language-native linters     |
| Workflow    | `zizmor`, `actionlint` (existing)            |
| Secrets     | `gitleaks` (existing)                        |
| Deps        | `trivy` (existing)                           |

New tool manifest entries go under `scope = repository`, same pattern
as existing scanners. Install recipes follow the existing
`cli/psmodule/pipx` kinds.

### 3. Drift engine (new `modules/shared/DriftEngine.ps1`)

Input: declared set + Azure-ARM entity set (already in `entities.json`).
Join on canonical `ResourceId`. Emit findings:

| Case                                  | Severity | Category |
|---------------------------------------|----------|----------|
| Declared, not deployed                | High     | Drift    |
| Deployed, not declared (shadow)       | Medium   | Drift    |
| Deployed + declared, property mismatch | Medium   | Drift    |
| Deployed + declared, tag mismatch only | Low      | Drift    |

Property comparison is **schema-guided**, not naive: only compare
properties that are part of the ARM PUT contract (reuse Bicep schema
from `azure-mcp-bicepschema`). Runtime-only fields (operational state,
timestamps, identity.principalId) are excluded.

### 4. Cross-cutting concerns

- **Auth**: reuse existing Azure/Graph auth. IaC parsing is local to the
  repo clone (remote or workspace), no new credentials.
- **Performance**: IaC parse is cheap; ARM export reuses entity store;
  drift join is an in-memory left/right/outer on the two ID sets.
- **Scale**: batch by subscription/resource-group; entity store already
  supports spillover to disk when combined records exceed threshold.
- **Reporting**: new `Drift` filter in HTML/MD reports; "Shadow
  Resources" and "Missing Deployments" become top-level cards alongside
  severity. Report stays manifest-driven so each new adapter's findings
  appear automatically.

## Phasing (when eventually scheduled)

1. **Phase A — IaC validation only.** Ship Terraform (tfsec/checkov)
   and Bicep (`bicep build` + PSRule) adapters. Findings only, no drift.
2. **Phase B — Declared-set inventory.** Normalize Bicep + ARM + TF
   plan into canonical resource IDs and include in `entities.json` as
   a new `Source = iac-declared`.
3. **Phase C — Drift engine.** Join declared vs deployed, emit drift
   findings, add Drift category to reports.
4. **Phase D — Shadow resource detection.** Extend drift to flag any
   deployed resource without a declared counterpart (per-subscription
   opt-in to avoid noise on un-IaC'd subscriptions).
5. **Phase E — Extended languages.** Pulumi, Crossplane, Helm as needed.

## Open design questions (to resolve when scheduled)

- Should multi-stack Terraform (remote state, workspace per env) be
  handled natively or via a required `--tfplan` input file per scope?
- How do we canonicalize cross-subscription scopes (e.g. a TF module
  targeting a different subscription than the current scan scope)?
- Policy-as-code: do we re-evaluate Azure Policy definitions against
  the declared set (`Test-AzPolicyCompliance` pattern) or leave that
  to PSRule?
- Bicep modules published to a registry — do we vendor the registry
  reference set or require users to `bicep restore` before the run?

## Security considerations

- IaC files can embed credentials. Adapters MUST pipe all parse output
  through `Remove-Credentials` and respect existing `gitleaks` pre-flight
  (don't proceed with drift if `gitleaks` found unredacted secrets).
- Terraform plan files can contain sensitive values. Prefer the JSON
  representation from `terraform show -json` over raw state.
- External tools invoked (tfsec/checkov/pulumi) must be wired through
  the manifest-driven installer with `Test-SafePackageName` +
  allow-listed package managers (already in place).

## Deferred / out of scope

- Writeback / remediation (no auto-fix or PR generation).
- IaC generation from live Azure (reverse engineering).
- Non-Azure clouds (AWS/GCP Terraform providers) — would require
  expanding the canonical resource ID scheme.
