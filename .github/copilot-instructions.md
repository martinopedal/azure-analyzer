# Copilot Instructions — azure-analyzer

## Repository Purpose
Bundle multiple Azure assessment tools into a single, portable runner. Output unified JSON + HTML/Markdown reports.

## Query format
- ARG queries live in `queries/` as JSON (not .kql files)
- Every query MUST return a `compliant` column (boolean)
- See alz-graph-queries repo for query schema reference

## Branch protection
- Signed commits NOT required (breaks Dependabot and GitHub API commits)
- 0 required reviewers (solo-maintained)
- enforce_admins = true, linear history, no force push
- ✅ Required status checks: `Analyze (actions)` only (Python removed — repo is PowerShell)

## CodeQL policy
- This repo scans GitHub Actions workflows only — `language: [actions]`
- PowerShell is NOT scanned by CodeQL (no supported CodeQL extractor for PS)
- Actions scanning covers workflow injection risks (expression injection, untrusted input)

## SHA-pinning
- All GitHub Actions MUST use SHA-pinned versions, not tags
- Example: `actions/checkout@de0fac2e4500dabe0009e67214ff5f5447ce83dd # v6`

## Permissions
- Azure tools need Reader only — NO write permissions
- See PERMISSIONS.md for full breakdown per tool

## Documentation rules — ALWAYS required

Every PR that changes code, queries, or configuration MUST include a docs update in the same commit:

- ✅ `README.md` — update feature list, supported tools, permissions summary if changed
- ✅ `PERMISSIONS.md` — update if new Azure/Graph/GitHub API scopes are added
- ✅ `CHANGELOG.md` — add an entry for every user-visible change (feature, fix, breaking)
- ✅ Inline comments in new PowerShell modules if the logic is non-obvious

**No code PR merges without a matching docs update. This is not optional.**

## Issue conventions

- ✅ Every new issue MUST have the `squad` label — this is how Ralph (squad watch) picks it up for dispatch
- ✅ The auto-label-issues workflow adds `squad` automatically on open — never remove it
- ✅ Use labels `enhancement`, `bug`, `documentation` alongside `squad` to signal priority and type
- ✅ Issue titles must follow: `feat:`, `fix:`, `docs:`, `chore:` prefix

## Actions version policy
- Use SHA-pinned versions of actions/checkout (v6) and actions/setup-python (v6) — always pin by SHA, not tag

## GitHub-first principle
Validate changes in GitHub Actions, not locally. Push, trigger workflow, check logs, iterate.

## Cloud agent PR review contract

When the GitHub coding agent (copilot-swe-agent[bot]) opens a draft PR for a `squad:copilot` issue:

1. The `copilot-agent-pr-review.yml` workflow auto-requests Copilot code review on PR open.
2. The authoring agent **MUST** address every Copilot review comment — either with a code change or an explicit reply explaining why it does not apply.
3. **Comments from Copilot on the PR *or* on the linked issue enter the Comment Triage Loop** (see `.squad/ceremonies.md` → Cloud Agent PR Review):
   - Every Copilot comment is rubber-ducked against the 3-model gate (**Opus 4.6 + Goldeneye + GPT-5.3-codex**).
   - 2-of-3 verdict → add triaged todos to `plan.md` + SQL `todos` table.
   - Updated plan is itself rubber-ducked before any code change.
   - Code is implemented, then the 3-model gate re-runs on the diff (Build → Review → Fix → Re-gate → CI → Merge).
   - Every Copilot thread gets a reply: either the addressing commit SHA, or the multi-model rejection justification.
4. Maintainers **MUST NOT** squash-merge an agent PR until **all Copilot review threads are Resolved**, the 3-model gate is green, the squad reviewer has approved, and the required `Analyze (actions)` check is green.
5. If the agent is unresponsive for >24h, reassign the issue to a squad member or take it over locally.
6. Stale agent draft PRs that are superseded by a direct merge MUST be closed with a `--delete-branch` to keep the branch list clean.

## Iterate Until Green — Resilience Contract

Failure is the default state of a multi-system pipeline. A PR is "done" only when it is **green AND merged**. See `.copilot/copilot-instructions.md` → "Iterate Until Green — Resilience Contract" for the full policy. Summary:

- **Triggers (any of):** CI red, Pester red, Copilot rejection, 3-model gate fail, merge conflict, rate-limit / model unavailable, flaky test, branch corrupted.
- **Required loop:** read failing logs (`gh run view <id> --log-failed` or GitHub MCP run/job logs) → diagnose root cause → fix at root (not symptom) → push → `gh pr checks <pr> --watch` → repeat until green.
- **Per-failure playbook:**
  - CI red → fetch failed-job logs, fix root cause, push, re-check.
  - Pester red → fix code or test, re-run full suite locally, never push red.
  - Copilot rejection → Comment Triage Loop until all threads resolved or answered with multi-model rejection justification.
  - Rate-limit → walk the Frontier Fallback Chain (`claude-opus-4.7` → `claude-opus-4.6-1m` → `gpt-5.4` → `gpt-5.3-codex` → `goldeneye`); never sonnet / haiku / mini / `gpt-4.1`.
  - Merge conflict → `git rebase origin/main`, `git push --force-with-lease` (never plain `--force`).
  - Branch corrupted → fresh worktree from `origin/main`, cherry-pick clean commits, replacement PR.
  - Flaky test → run 3x; if intermittent, fix the flake (`-Skip` / `-Pending` to ship green is forbidden).
- **Escalation:** only after 3 *distinct* strategies have failed, with a written analysis posted as a PR sticky comment + mirror `squad` issue. Closing the PR or silently abandoning the branch is a contract violation.
- **Hard rule:** "blocked, needs maintainer" replies without the 3-strategy analysis are forbidden — resume the loop.

Cross-refs: rubber-duck retry / fallback chain in `.copilot/copilot-instructions.md`, Comment Triage Loop above (cloud-agent PR review contract), Squad Pre-PR Self-Review.

## Wrapper consistency ratchet (CON-001..005)

- **CON-001** — ADO wrapper parameter consistency (`AdoOrg` / `AdoProject` conventions with compatibility aliases as needed).
- **CON-002** — Repo input consistency (`RepoPath` + `RemoteUrl` canonical names; legacy aliases only for compatibility).
- **CON-003** — Structured wrapper errors: prefer `New-FindingError` + `Format-FindingErrorMessage` over raw throw strings.
- **CON-004** — Side-effecting wrappers should support safe dry-runs (`SupportsShouldProcess`, `-WhatIf` / `-Confirm`) where applicable.
- **CON-005** — Manifest/wrapper uniformity: manifest entries map to stable `Invoke-*` dispatch surfaces.

Treat regressions against these contracts as blockers; tighten ratchet baselines when drift is reduced.

## Shared infrastructure — REUSE, don't reinvent

Before adding retry/clone/sanitize/install logic, check these modules first:

- **`tools/tool-manifest.json`** — single source of truth for tool registration. `name`, `displayName`, `scope` (`subscription` / `managementGroup` / `tenant` / `repository` / `ado` / `workspace`), `provider` (`azure` / `microsoft365` / `graph` / `github` / `ado` / `cli`), `enabled`, plus `install` and `report` blocks. New tools **MUST** register here. Installer + both reports read from it.
- **`modules/shared/Installer.ps1`** — manifest-driven prerequisite installer. `Install-PrerequisitesFromManifest` handles `psmodule` / `cli` / `gitclone` / `none`. Uses `Invoke-WithInstallRetry` + `Invoke-WithTimeout` (300s). Rich errors via `New-InstallerError` / `Write-InstallerError`. Entry point: `-InstallMissingModules` orchestrator flag.
- **`modules/shared/RemoteClone.ps1`** — cloud-first HTTPS clone helper. `Invoke-RemoteRepoClone` returns `{ Path, Url, Cleanup }`. All new repo-scoped scanners MUST use this instead of rolling their own `git clone`.
- **`modules/shared/Retry.ps1`** — `Invoke-WithRetry` with jittered backoff. Retries on `$TransientMessagePatterns` (429/503/504/throttle/timeout). Wrap any REST/ARG/external call with it.
- **`modules/shared/Sanitize.ps1`** — `Remove-Credentials` scrubs tokens/keys/connection strings. **All error/log output written to disk MUST pass through this**.
- **`modules/shared/Schema.ps1`** — `New-FindingRow` is the ONLY way to emit v2 FindingRow entries. Severity enum is exactly five: `Critical | High | Medium | Low | Info`.
- **`modules/shared/Canonicalize.ps1`** — `ConvertTo-CanonicalEntityId` — always use for entity IDs. Format: `tenant:{guid}`, `appId:{guid}`, ARM resource IDs lowercased.
- **`modules/shared/EntityStore.ps1`** — v3 entity-centric store. Findings and entities are written separately (`results.json` + `entities.json`).

## Security invariants — enforced

Non-negotiable rules that apply to every new wrapper/module:

- ✅ **HTTPS-only** for any outbound URL; HTTP is rejected
- ✅ **Host allow-list** for clone/fetch: `github.com`, `dev.azure.com`, `*.visualstudio.com`, `*.ghe.com` — enforced by `RemoteClone.ps1`
- ✅ **Allow-listed package managers** only: `winget`, `brew`, `pipx`, `pip`, `snap` — enforced by `Installer.ps1`
- ✅ **Package-name regex** prevents shell-injection via manifest-sourced package names
- ✅ **300s timeout** on every external process launch (`Invoke-WithTimeout`)
- ✅ **Token scrubbing** from `.git/config` immediately post-clone
- ✅ **Remove-Credentials** on all output written to JSON/HTML/MD/log files
- ✅ **Rich errors**: throw via `New-InstallerError` / `New-FindingError` with `Category`, `Remediation`, and sanitized `Details`

## Testing gate

- `Invoke-Pester -Path .\tests -CI` — baseline is enforced by `tests/workflows/PesterBaselineGuard.Tests.ps1` and should be preserved or extended.
- Normalizer tests live under `tests/normalizers/`; wrapper tests under `tests/wrappers/`; shared-module tests under `tests/shared/`.
- Every new tool MUST ship with a normalizer test using a realistic fixture in `tests/fixtures/`.
- Every new shared module MUST ship with its own `tests/shared/<Module>.Tests.ps1`.

## Normalizer contract (v1 → v3)

Wrappers emit a v1 standardized envelope (`SchemaVersion: 1.0`, raw findings). Normalizers convert to v2 `FindingRow` (`SchemaVersion: 2.0`) via `New-FindingRow`. The orchestrator writes both:
- `results.json` — legacy 10-field findings (back-compat)
- `entities.json` — full v3 entity-centric model

Rules:
- Severity switch MUST handle all five levels (`critical/high/medium/low/info`, case-insensitive)
- EntityType MUST be one of the Schema.ps1 enum (`AzureResource`, `Subscription`, `Tenant`, `User`, `ServicePrincipal`, `Repository`, `Workflow`, …)
- Canonical entity IDs via `ConvertTo-CanonicalEntityId` — never emit raw GUIDs for tenant/SPN/user entities
- Tools that attach to the Entra tenant use `EntityType=Tenant` + `Platform=Entra` (see Maester)

## Reports

HTML + MD reports (`New-HtmlReport.ps1` / `New-MdReport.ps1`) read tools/tool-manifest.json for source/label/color metadata. New tools that register in the manifest appear automatically — no report-code edit required. The 12-tool fallback list is a safety net only.

## Cloud-first targeting

azure-analyzer is a **cloud-first** tool. Repo-scoped scanners (zizmor, gitleaks, trivy, scorecard) target remote GitHub / ADO / GHE URLs via `RemoteClone.ps1`. Local `-RepoPath` is a fallback, not the default. Do not add new local-only scan modes.
