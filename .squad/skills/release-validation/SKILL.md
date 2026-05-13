---
name: "release-validation"
description: "Reproducible playbook for verifying azure-analyzer is fully clean before/after a release. Covers docs freshness, simulation/mock leakage, runtime correctness, CI green, and PSGallery publish parity. Every step writes its result to the decisions inbox so the run is auditable."
domain: "release-engineering"
confidence: "high"
source: "earned"
---

## Context

Use this skill any time the user asks one of:

- "is it all green?" / "all clean?" / "no errors?"
- "do a full code audit" / "validate the release" / "is X stable?"
- "do we still simulate / mock anything?"
- "are docs in sync?"
- "is PSGallery up to date?"
- before flipping a draft PR, before tagging a release, before walking away.

It is the Coordinator's single source of truth for "does this repo actually work end-to-end right now?"

**Standing directive (capture from Martin 2026-05-13):** *all logics, all errors we catch, everything must be logged.* Clarified 2026-05-13T22:30: **"logged" means `store_memory`** — the persistent memory layer that surfaces at the start of every future session via the memories prompt. Inbox files (`.squad/decisions/inbox/*.md`) are a **secondary** audit trail; memory is **primary**. Every validation pattern in this skill MUST close with a `store_memory` call carrying the verdict + evidence. **No silent passes.** A green check that wasn't stored as memory is treated as not-run.

## Logging contract — applies to every step below

For every step you run:

1. **PRIMARY — `store_memory`** (the actual "log" Martin asked for). One memory per validation pattern run, with:
   - `subject`: short topic (e.g., `release validation`, `docs freshness`, `runtime audit`).
   - `fact`: one-line verdict + key numbers (e.g., `Pattern C runtime audit 2026-05-13: 4/4 scopes GREEN, 0 lying-success envelopes, results.json 47KB tenant scope`).
   - `citations`: paths + commit SHAs + workflow run IDs proving it.
   - `reason`: why future sessions need this (e.g., "next pre-tag validation can skip rerunning if same SHA").
   - **Errors caught** (even recovered ones — rate-limit retries, model fallbacks, transient CI flakes) get their OWN memory under `subject: error caught` with the recovery path. Silent recovery hides regressions.

2. **SECONDARY — inbox file** (`.squad/decisions/inbox/{persona}-{domain}-{YYYY-MM-DD}.md`) for the full evidence dump that's too long for a memory fact. Scribe merges these into `decisions.md` on the next flush. Use this for: full grep output, full pester breakdown by file, command-by-command exit codes.

3. **TERTIARY — orchestration log** (Scribe writes `.squad/orchestration-log/{ts}-{agent}.md`) so the routing trail is auditable.

Memory > inbox > orchestration log. If you only have time for one, do memory.

Empty error sections must be explicitly logged (`store_memory` with fact `Pattern X: zero errors caught`) — absence of memory is forbidden.

## Patterns

### Pattern A — Docs freshness (auto-bumper trifecta + per-tool pages + CHANGELOG)

All three generators support `-CheckOnly` and exit non-zero on drift. Run them in this order:

```powershell
cd C:\git\azure-analyzer
pwsh -NoProfile -Command ". './scripts/Generate-ReadmeFacts.ps1' -CheckOnly"
pwsh -NoProfile -Command ". './scripts/Generate-PermissionsIndex.ps1' -CheckOnly"
pwsh -NoProfile -Command ". './scripts/Generate-ToolCatalog.ps1' -CheckOnly"
```

Then sanity-check the manifest counts match what README claims:

```powershell
$m = Get-Content tools\tool-manifest.json -Raw | ConvertFrom-Json
$enabled  = @($m.tools | Where-Object { $_.enabled -eq $true })
$disabled = @($m.tools | Where-Object { $_.enabled -ne $true })
"Total: $($m.tools.Count) | Enabled: $($enabled.Count) | Disabled: $($disabled.Count)"
```

Confirm every enabled tool has a per-tool page:

```powershell
$enabled.name | Where-Object { -not (Test-Path "docs/reference/permissions/$_.md") }
# expected output: nothing
```

Confirm CHANGELOG carries a section for the last shipped tag:

```powershell
$lastTag = git --no-pager tag --sort=-v:refname | Select-Object -First 1
Select-String -Path CHANGELOG.md -Pattern "^## \[$($lastTag.TrimStart('v'))\]" | Select-Object -First 1
```

CI enforcement: `.github/workflows/docs-check.yml` (`readme-facts-fresh`, `permissions-pages-fresh`, `tool-catalog-fresh` jobs) — every PR is gated.

**Log file:** `coordinator-docs-freshness-{date}.md`

### Pattern B — Static mock / simulation leakage scan

Production surface = everything OUTSIDE `tests/`, `tests/fixtures/`, `tests/_helpers/`, `.squad/`, `docs/`, `examples/`, `.github/`. Run these greps and classify each hit (REAL vs LEAK):

```text
# A. FixtureMode references in wrappers (must NEVER appear inside modules/Invoke-*.ps1)
grep -n "FixtureMode" modules/Invoke-*.ps1

# B. Hardcoded fake names in production
grep -rn -i "contoso\|fabrikam\|sample-tenant\|00000000-0000-0000-0000-000000000000" modules/ tools/ scripts/ Invoke-AzureAnalyzer.ps1

# C. Silent error swallowing
grep -rn -E "catch\s*\{\s*\}" modules/ Invoke-AzureAnalyzer.ps1
grep -rn -E "catch\s*\{[^}]*return\s+@\(\)" modules/ Invoke-AzureAnalyzer.ps1
grep -rn -E "catch\s*\{[^}]*return\s+@\{\}" modules/ Invoke-AzureAnalyzer.ps1

# D. Stub markers in production code
grep -rn -E "TODO|FIXME|HACK|XXX|STUB|NotImplemented" modules/ tools/ scripts/ Invoke-AzureAnalyzer.ps1

# E. Mock injection parameters (forbidden)
grep -rn -E "\-MockResult|\-FakeOutput|AZURE_ANALYZER_MOCK_" modules/ Invoke-AzureAnalyzer.ps1

# F. Test-Path / Get-Command short-circuits faking success
grep -rn -E "Get-Command.*-ErrorAction\s+SilentlyContinue\s*\)\s*\)\s*\{\s*return\s+@\(\)" modules/

# G. Production code reading test fixtures
grep -rn "tests/fixtures\|tests\\\\fixtures" modules/ tools/ scripts/ Invoke-AzureAnalyzer.ps1
```

Plus the v1/v2 contract checks:

- Every `Invoke-*.ps1` envelope must include both `Findings = @()` AND `Errors = @()`. Enforced by `tests/shared/WrapperConsistencyRatchet.Tests.ps1` Cat 12/13 and `tests/wrappers/EnvelopeContract.Tests.ps1` (depth-balanced brace matcher — handles both `[pscustomobject]@{...}` literal and `[ordered]@{}` cast forms).
- Every v2 row must come from `New-FindingRow` (Schema.ps1) — no hand-rolled hashtables.
- Severity must be one of: `Critical | High | Medium | Low | Info` (case-insensitive in normalizers, canonical in the row).

**Log file:** `atlas-mock-leakage-audit-{date}.md`

### Pattern C — Runtime simulation across all dispatch profiles

Actually invoke the orchestrator. CI green != tool works.

```powershell
$base = "$env:TEMP\release-validation\$(Get-Date -Format 'yyyyMMdd-HHmmss')"
foreach ($scope in 'subscription','managementGroup','tenant','repository') {
    $out = Join-Path $base $scope
    pwsh -NoProfile -File .\Invoke-AzureAnalyzer.ps1 -FixtureMode -Scope $scope -OutputPath $out
    "[$scope] results.json: $((Get-Item $out\results.json -ErrorAction SilentlyContinue).Length) bytes"
    "[$scope] entities.json: $((Get-Item $out\entities.json -ErrorAction SilentlyContinue).Length) bytes"
    "[$scope] report.html: $((Get-Item $out\report.html -ErrorAction SilentlyContinue).Length) bytes"
}
```

For every output verify:

- `results.json` non-empty AND every entry has all 10 v2 FindingRow fields populated.
- `entities.json` non-empty AND every `EntityId` is canonical (lowercased ARM IDs, `tenant:{guid}`, `appId:{guid}`, `cap:{guid}`, `loc:{guid}`, `onprem:user:{sid}`).
- `report.html` > 5 KB AND contains real findings text (not the empty-state placeholder).
- `report.md` mirrors the JSON.
- Tenant scope additionally produces `portfolio.json`.
- No envelope with `Status=Success` AND empty `Findings` AND no genuine reason — that's the "lying success" anti-pattern.

Spot-check ONE wrapper outside FixtureMode against a real local target (e.g. `Invoke-Gitleaks.ps1` against this repo) to confirm the CLI path actually fires.

**Log file:** `sentinel-runtime-audit-{date}.md`

### Pattern D — Pester full pass

```powershell
pwsh -NoProfile -Command "Import-Module Pester -RequiredVersion 5.7.1 -Force; Invoke-Pester -Path tests -CI"
```

Capture and log: PassedCount / FailedCount / SkippedCount + every failure broken down by file. Pester baseline is enforced by `tests/workflows/PesterBaselineGuard.Tests.ps1` — any drop below baseline is RED. Skips that ship green to mask broken tests are forbidden ("Iterate Until Green" contract).

**Log file:** `sentinel-pester-{date}.md`

### Pattern E — CI green on `main`

```powershell
gh run list --branch main --limit 10 --json conclusion,createdAt,displayTitle,workflowName,databaseId | ConvertFrom-Json | Format-Table -AutoSize
gh run list --branch main --workflow "docs-check.yml" --limit 5 --json conclusion,event,createdAt | ConvertFrom-Json
gh run list --branch main --workflow "ci.yml" --limit 5 --json conclusion,event,createdAt | ConvertFrom-Json
gh run list --branch main --workflow "release.yml" --limit 5 --json conclusion,event,createdAt | ConvertFrom-Json
```

Required check (and ONLY required check) per branch protection: `Analyze (actions)`. Test (ubuntu/macos/windows) + Closes-link are advisory. Never add new required checks without updating this skill.

For any non-success: `gh run view {id} --log-failed | Select-Object -Last 200` and log the root cause.

**Log file:** `coordinator-ci-green-{date}.md`

### Pattern F — Open backlog triage

```powershell
gh pr list --state open --json number,title,author,isDraft,reviewDecision,mergeStateStatus | ConvertFrom-Json
gh issue list --state open --label squad --json number,title,labels --limit 50 | ConvertFrom-Json
```

Classify every open `squad`-labelled issue as `bug` (must close before release), `enhancement` (backlog, OK to defer), or `stale auto-noise` (close as bookkeeping). Anything stuck in `BEHIND mergeStateStatus` → `gh pr update-branch --rebase`.

**Log file:** `coordinator-backlog-triage-{date}.md`

### Pattern G — PSGallery + GH release parity

```powershell
$psGallery = Find-Module -Name AzureAnalyzer -Repository PSGallery -ErrorAction SilentlyContinue
$lastTag   = git --no-pager tag --sort=-v:refname | Select-Object -First 1
$ghRelease = gh release view $lastTag --json tagName,name,publishedAt,assets | ConvertFrom-Json
"PSGallery: $($psGallery.Version) ($($psGallery.PublishedDate))"
"Last tag:  $lastTag"
"GH release: $($ghRelease.tagName) -- $($ghRelease.assets.Count) assets"
git --no-pager show -s --format='%H %d' $lastTag   # confirm tag is reachable on main
git --no-pager cat-file -t $lastTag                # 'commit' = lightweight (release-please default), 'tag' = annotated
```

Lightweight tags are EXPECTED — release-please ships unsigned, lightweight tags. Validators in `release.yml` must NOT require annotated/signed tags (regression of this rule cost us v1.4.5 — see memory `release pipeline`).

The PSGallery 8-check E2E (`psgallery_e2e` job in `release.yml`) covers cross-OS install + import + manifest + version + metadata + ReleaseNotes + functional smoke + PSScriptAnalyzer. If that job is green on the release run, install parity is verified.

**Log file:** `coordinator-release-parity-{date}.md`

### Pattern H — Security invariants (one-shot regression catch)

```powershell
# HTTPS-only + host allow-list (RemoteClone)
grep -rn -E "git\s+clone\s+http://" modules/

# Allow-listed package managers only (Installer)
grep -rn -E "Start-Process\s+(curl|wget|iwr)" modules/

# Token scrubbing post-clone
grep -rn "Remove-Credentials" modules/shared/RemoteClone.ps1

# 300s timeout wrapper coverage
grep -rn "Invoke-WithTimeout" modules/Invoke-*.ps1 | Measure-Object | Select-Object -ExpandProperty Count
```

If any of these regress, stop the release and file a P0 issue.

**Log file:** `coordinator-security-invariants-{date}.md`

## How to invoke this skill from a Coordinator session

When Martin asks "is it clean?" / "validate the release" / "audit it":

1. Acknowledge in 1-2 sentences + show launch table.
2. Spawn ONE persona per pattern in parallel (`mode: "background"`):
   - **Sentinel** → Pattern C (runtime) + Pattern D (Pester)
   - **Atlas** → Pattern B (static leakage) + Pattern H (security invariants)
   - **Coordinator (you)** → Patterns A (docs), E (CI), F (backlog), G (release parity) — these are read-only, fast, no agent spawn needed.
3. Each persona writes its `.squad/decisions/inbox/{persona}-{domain}-{date}.md` log file per the contract above.
4. After all results land, present a single compact verdict table:
   ```
   Pattern         Verdict   Log
   --------------- --------- ---------------------------------------------
   A docs          GREEN     coordinator-docs-freshness-2026-05-13.md
   B mock leakage  GREEN     atlas-mock-leakage-audit-2026-05-13.md
   C runtime       GREEN     sentinel-runtime-audit-2026-05-13.md
   D pester        GREEN     sentinel-pester-2026-05-13.md
   E ci green      GREEN     coordinator-ci-green-2026-05-13.md
   F backlog       AMBER     coordinator-backlog-triage-2026-05-13.md
   G release       GREEN     coordinator-release-parity-2026-05-13.md
   H security      GREEN     coordinator-security-invariants-2026-05-13.md
   ```
5. Spawn Scribe (background) to merge the inbox into `decisions.md` and commit.

Any RED triggers the "Iterate Until Green" loop — do NOT report success.

## Examples

- 2026-05-13 release-validation run: this skill was extracted from the parallel Sentinel (runtime) + Atlas (static) audit Martin requested before going away. See `.squad/decisions/inbox/sentinel-runtime-audit-2026-05-13.md` and `.squad/decisions/inbox/atlas-mock-leakage-audit-2026-05-13.md` for the worked example.

## Anti-patterns

- **"All checks green" without per-pattern logs.** A green PR badge is not the same as a clean tool. If the inbox has no validation files for the date, the validation didn't happen.
- **Skipping Pattern C because Pattern E is green.** CI runs FixtureMode in one configuration. The runtime pattern exercises every scope.
- **Catching an error and not logging it.** Per the standing directive every error we catch — even ones we recover from with retry/fallback — must land in the inbox file's "Errors caught" section. Silent recovery hides regressions.
- **Marking PR-1 of N green and shipping.** Validation is whole-tool, not per-PR. If you're between PRs in a sequence, log the partial state explicitly (`Pattern C: NOT-RUN, blocked on PR-3`).
- **Hand-editing per-tool docs (`docs/reference/permissions/{tool}.md`)** instead of letting the generator stub them. The generator's `-CheckOnly` mode will fail on `main` if the auto-stub gets out of sync.
