# Rubberduck Verdict — Opus 4.7 on Consolidated Audit (2026-04-23)

> **Methodology.** Each consensus finding (C-1..C-19) was verified by reading the
> cited file at the cited line. Vote is AGREE only when the cited path:line
> evidence supports the claim *as worded*. REVISE/DISAGREE come with a
> counter-citation. Sample read every claim — no second-hand acceptance.

> **Note on Iris E2E input.** The prompt referenced
> `.copilot\audits\e2e-user-journey-2026-04-23.md` — that file does **not**
> exist on disk. The closest extant artifact (`iris-test-audit-2026-04-23.md`)
> is a test-coverage audit, not a user-journey walkthrough. Reconciliation
> section below flags this gap rather than fabricating Iris findings.

---

## Headline

Of 19 consensus findings: **13 AGREE, 4 REVISE, 1 DISAGREE, 1 NEED-MORE-EVIDENCE.**
The big two (C-1, C-2) are fully verified and merge-blocking. C-7 and C-15
are partially right but the wording in the consolidated doc misrepresents
the actual code state. C-13 is wrong as worded (`-Mode` parameter does not
exist at all — there is nothing to "break").

---

## Per-finding votes

### C-1 — CLI wrappers lack `Invoke-WithTimeout` AND WorkerPool has no per-tool runtime cap
- **Vote:** AGREE — severity **P0** (Codex was right; Opus models under-rated).
- **Verification:**
  - `modules/shared/WorkerPool.ps1:92-149` — `ForEach-Object -Parallel` with
    `-ThrottleLimit $MaxParallel` and a per-provider semaphore. No cancellation
    token, no per-tool deadline, no scriptblock timeout wrapper. A scriptblock
    that hangs holds its semaphore slot forever; the main thread blocks at
    pipeline drain.
  - Surveyed all 15 wrappers named in the consensus: **0 of 15 use
    `Invoke-WithTimeout`** (Azqr, Prowler, Scorecard, Trivy, PSRule, WARA,
    Maester, Powerpipe, Zizmor, Gitleaks, Falco, KubeBench, Kubescape,
    IaCBicep, IaCTerraform — all zero).
- **Notes:** A single stuck `& kubescape scan ...` (no `--timeout` flag passed)
  freezes the whole orchestrator with no console output. P0 promotion is
  warranted because the failure mode is "hangs forever" not "fails
  gracefully" — that is exactly what an operator can't recover from without
  killing the process.

### C-2 — 10+ wrappers missing `Invoke-WithRetry`
- **Vote:** AGREE.
- **Verification:** Survey of `Invoke-WithRetry` invocations in named wrappers:
  Azqr 0, Prowler 0, Scorecard 0, Trivy 0, PSRule 0, WARA 0, Maester 0,
  Powerpipe 0, IaCBicep 0, IaCTerraform 0. (Counter-evidence: Zizmor 3,
  Gitleaks 3, Falco 4, KubeBench 3, Kubescape 2 — uneven adoption confirms
  retry is *expected* at the wrapper layer, the listed 10 are genuine gaps.)
- **Notes:** None.

### C-3 — Pester `Test` job is advisory, only `Analyze (actions)` is required
- **Vote:** AGREE.
- **Verification:** `.github/workflows/ci.yml` defines a `Test` matrix job
  that exits 1 on Pester failure (good). But repo policy in
  `.github/copilot-instructions.md` and the prompt's own custom-instructions
  block confirms: "✅ Required status checks: `Analyze (actions)` only".
  The job is well-built; the gate is missing.
- **Notes:** Fix is a one-line branch-protection update, not a code change.
  Belongs in a governance PR (see Q2).

### C-4 — Orchestrator exits 0 even when every tool failed
- **Vote:** AGREE.
- **Verification:** `Invoke-AzureAnalyzer.ps1` last 40 lines: after the error
  summary block ("⚠️ N tool(s) encountered errors") there is no `exit`
  statement. The script ends with the env-restore block, so the exit code
  is implicit 0 regardless of `$toolErrors.Count`. The earlier `exit 0`
  /`exit 1`/`exit 2` paths only fire on the multi-tenant fan-out branch
  (line 244, 247) and on early validation failures (line 390). Single-tenant
  happy-path falls off the end.
- **Notes:** Cardinal CI honesty bug. Promote consideration to P0 if any
  downstream pipeline (release-please, dependabot auto-merge) trusts the
  exit code.

### C-5 — Installer/manifest contract broken for `kubescape`, `powerpipe`, `kubelogin`
- **Vote:** REVISE-SEVERITY (keep P0) + REVISE-DESCRIPTION.
- **Verification:**
  - `tools/tool-manifest.json` declares `kubescape` and `powerpipe` with
    `kind: cli` and full `windows`/`macos` install blocks (winget/brew).
    Linux blocks are **broken**:
    - `kubescape` linux uses `manager: "script"` — `script` is **not in
      `$AllowedPackageManagers`** (`Installer.ps1:407-413` rejects it).
    - `powerpipe` linux has no `manager` field at all, only `url` —
      `Install-CliTool` falls through to "Download from: <url>" warning
      (`Installer.ps1:428-432`) and returns `$false`.
  - `kubelogin` is **NOT** in the manifest at all (verified:
    `$m.tools.name -contains 'kubelogin'` returns False). It's only referenced
    as a *prerequisite* candidate in a comment (`Installer.ps1:724`).
- **Notes:** GPT-5.4's diagnosis (Linux silent fail) is correct; the
  framing "manifest declares them" is wrong for kubelogin. Severity stays P0
  because Linux is the supported CI platform.

### C-6 — Bare `Set-Content` on primary outputs
- **Vote:** AGREE.
- **Verification:** `Invoke-AzureAnalyzer.ps1`:
  - `:1373` results.json — `Set-Content -Path $outputFile`
  - `:1405` entities.json — `Set-Content -Path $entitiesFile`
  - `:1448` portfolio.json — `Set-Content -Path $portfolioFile`
  - `:1755` run-metadata.json — `Move-Item -Path $runMetaTemp -Destination ... -Force` (correct atomic write).
- **Notes:** Pattern already exists for run-metadata; lift it into a helper
  `Write-OutputAtomic` and apply to the three primary outputs.

### C-7 — Three retry-pattern lists drift apart
- **Vote:** AGREE (with correction — the *citation* is right but the
  consolidated doc says "three distinct `$TransientMessagePatterns`
  definitions" which is misleading).
- **Verification:** Only **one** `$TransientMessagePatterns` variable
  exists, in `Retry.ps1:22-30`. The drift is *implementation*, not
  variable-naming:
  - `modules/shared/RemoteClone.ps1:215-221` — inline literal:
    `$low -match '\b429\b' -or $low -match '\b503\b' -or ...`
  - `modules/shared/Invoke-PRReviewGate.ps1:102` and `:678` — inline regex:
    `(?i)(429|rate limit|503|timeout|temporar)` — misses 408, 504,
    EOF, broken pipe, connection reset, no such host, etc.
- **Notes:** Real bug, but the rubberduck must update the wording: it's
  three transient-detection *implementations*, not three *named variables*.

### C-8 — `-AlzReferenceMode` is a no-op
- **Vote:** AGREE.
- **Verification:** `Invoke-AzureAnalyzer.ps1:160` declares
  `[ValidateSet('Auto','Force','Off')] $AlzReferenceMode = 'Auto'`. Only
  consumer in the entire orchestrator is `:1430` where it's stuffed into
  the report manifest's `Policy.alz.mode` field — never read by any
  downstream code path that gates ALZ behavior. Grep confirms no other
  reference.
- **Notes:** Either wire it into `Invoke-AlzQueries` to enable/skip the
  reference comparison, or remove the parameter.

### C-9 — Failure remediation dropped from reports
- **Vote:** AGREE.
- **Verification:** `New-HtmlReport.ps1` and `New-MdReport.ps1` have
  zero references to `errors.json`, `toolErrors`, or wrapper-failure
  surfacing (verified by grep — `No matches found.`). `Invoke-AzureAnalyzer.ps1`
  writes `errors.json` (last 40 lines) but the renderers never read it.
  `Remediation` field on individual *findings* is rendered
  (`New-HtmlReport.ps1:553-554`); the gap is *tool-level* failures.
- **Notes:** Tool failure with structured `Remediation` (e.g., "az login required")
  is invisible to anyone who only opens report.html.

### C-10 — HTML/MD disagree on zero-finding posture
- **Vote:** NEED-MORE-EVIDENCE.
- **Verification:** `New-MdReport.ps1:391` and `:466` use plain text
  fallbacks ("No findings available..."). HTML side has no equivalent
  zero-state grep hit in this pass. Likely a real divergence but the
  consolidated doc didn't cite the HTML side and I haven't traced both
  renderers end-to-end on a 0-finding fixture. Goldeneye-substitute UX
  catch — needs a follow-up render diff.

### C-11 — Manifest has no duplicate-name runtime guard
- **Vote:** AGREE.
- **Verification:** `scripts/Sync-AlzQueries.ps1:83`:
  `$toolEntry = @($manifest.tools | Where-Object { $_.name -eq $SelectedToolName } | Select-Object -First 1)`.
  No pre-check that names are unique; first-wins is ordering-dependent.
- **Notes:** Add a `Test-ManifestUniqueness` helper called once at orchestrator
  startup (after `:256` parse).

### C-12 — `auto-approve-bot-runs.yml:83` includes `martinopedal` in trusted-bot allow-list
- **Vote:** AGREE — severity **P1 escalate to P0 for security review**.
- **Verification:** `.github/workflows/auto-approve-bot-runs.yml` lines
  ~78-86 show the literal trusted array including `"martinopedal"` alongside
  `copilot-swe-agent[bot]`, `dependabot[bot]`, `github-actions[bot]`.
- **Notes:** Auto-approval of a human's PRs by a bot defeats the spirit
  of the trusted-bot allow-list. Either intentional automation (justify in
  a comment) or accidental — see Q4. **Recommend removal pending owner
  confirmation.**

### C-13 — `-Mode Discovery` parameter broken
- **Vote:** DISAGREE (as worded).
- **Verification:** `Invoke-AzureAnalyzer.ps1:127-172` is the full param
  block. There is **no `-Mode` parameter**. Grep for `\$Mode` in the
  orchestrator returns only `BaselineMode`, `KubeAuthMode`, `AlzReferenceMode`,
  `RunMode` (internal var). Grep for `'Discovery'`/`"Discovery"` across
  *.md returns no user-facing doc that promises a `-Mode Discovery`
  parameter. There is nothing to "break" — the parameter does not exist.
- **Notes:** Codex's finding may have been a model hallucination, or
  refer to a different mode (perhaps `BaselineMode discovery`?). Drop
  C-13 from the fix wave or rewrite as "design issue: there is no
  discovery-only mode for cheap manifest validation". Verify against
  Codex's full deliverable when re-spawn lands.

### C-14 — Unguarded manifest JSON parse
- **Vote:** AGREE.
- **Verification:** `Invoke-AzureAnalyzer.ps1:256`:
  `$manifest = Get-Content (...) 'tool-manifest.json') -Raw | ConvertFrom-Json`.
  No try/catch. Bad JSON yields a raw `ConvertFrom-Json` parse error to
  the user. Strict mode is on (`:179`).
- **Notes:** Wrap in try/catch, throw `New-FindingError` with
  `Category=InvalidConfig`, `Remediation='Validate tool-manifest.json with jq .'`.

### C-15 — Legacy dead module `modules/Invoke-CopilotTriage.ps1` returns `$null`
- **Vote:** REVISE (severity stays P2; description is wrong).
- **Verification:** `modules/Invoke-CopilotTriage.ps1` header:
  *"Never throws — returns $null on any failure so the main pipeline
  continues without AI enrichment."* This is **intentional** best-effort
  shim behavior, not a "dead module". HOWEVER the real defect is
  duplication — three artifacts coexist:
  - `modules/Invoke-CopilotTriage.ps1` (PS shim)
  - `modules/Invoke-CopilotTriage.py` (Python triage script the shim shells out to)
  - `modules/shared/Triage/Invoke-CopilotTriage.ps1` (a second PS module same name)
- **Notes:** Re-cast the finding as "duplicate `Invoke-CopilotTriage.ps1`
  in two locations under modules/" — the dot-source loader behavior is
  last-wins per the existing FunctionCollision memory. P2 is appropriate.

### C-16 — Duplicate function defs in `Schema.ps1`
- **Vote:** AGREE.
- **Verification:** `modules/shared/Schema.ps1`:
  - `function Get-SchemaValidationFailures` at `:92` AND `:163`
  - `function Reset-SchemaValidationFailures` at `:102` AND `:175`
- **Notes:** Verified — last-defined wins in PowerShell. Pick one and delete
  the other. P2 is right because tests pass with current behavior.

### C-17 — `AttackPath.Tests.ps1:133` unconditional `-Skip`
- **Vote:** AGREE (with citation correction: file is at
  `tests/renderers/AttackPath.Tests.ps1`, the `-Skip` is at line 132 not 133).
- **Verification:** `tests/renderers/AttackPath.Tests.ps1:132`:
  `It 'gracefully omits tooltips and metadata for deferred FindingRow fields (depends on #432b)' -Skip {`.
  Hard-coded `-Skip`, no condition. Comment says "Pending #432b".
- **Notes:** When #432b lands, replace `-Skip` with a real assertion or
  `-Skip:(-not $env:TRACK_D_LANDED)` so the safety net engages
  automatically.

### C-18 — `run-metadata.json` contract drift (Markdown headers lose run identity)
- **Vote:** NEED-MORE-EVIDENCE.
- **Verification:** `New-MdReport.ps1:158-201` actively reads
  `run-metadata.json`, extracts `tenantId`, `runId`, `startedAtUtc`, and
  the `tools` block. The MD report DOES surface run identity. The
  consensus doc cites "header block" without a line number. Without
  Goldeneye-substitute's specific failure trace I can't verify a "drift"
  here. Possibly stale finding. Re-spawn Goldeneye to re-validate.

### C-19 — Retry helper misclassifies 502
- **Vote:** AGREE.
- **Verification:** `modules/shared/Retry.ps1:23` —
  `'\b429\b', '\b503\b', '\b504\b', '\b408\b'` — **502 is missing**.
  Status-code check at `:61` only matches `408, 429, 503, 504`. Bad
  Gateway is the canonical "transient upstream blip" code; ARM and Graph
  both emit it under load.
- **Notes:** Single-line fix in both pattern list and status-code set.
  Add a Pester case in `tests/shared/Retry.Tests.ps1`.

---

## Open question verdicts

### Q1: C-1 severity — Codex P0 vs Opus P1?
**My verdict: P0.** Hangs without console output > silently dropping a
single tool. Operator has no recovery path except Ctrl+C, and Ctrl+C
mid-write triggers the C-6 corruption bug. This is a compound failure.

### Q2: C-3 governance — this fix wave or separate PR?
**My verdict: Separate governance PR, ship in same milestone.** Code
change is zero, branch-protection change is API-only, but the rationale
needs a CHANGELOG entry and a 24h heads-up so contributors know the gate
is hardening. Bundling with code waves muddles the rollback story.

### Q3: C-4 exit-code — non-zero on any failure or threshold?
**My verdict: Non-zero on ANY wrapper failure, with a `-AllowToolFailures`
escape hatch (default off).** Threshold-based ("fail at N+ failures") is
operator-config that hides regressions. Honesty default = strict; opt-in
to looseness. Document the flag in README under "CI integration".

### Q4: C-12 allow-list — `martinopedal` intentional or accidental?
**My verdict: Likely accidental** (added during a self-test of the
auto-approve flow) — but I cannot prove intent without owner confirmation.
Recommend: remove from allow-list, add a comment block above the array
explaining the criterion ("bots only — humans do not get auto-approval"),
and if Martin needs self-PR auto-merge that's a separate `auto-merge`
label workflow, not a trusted-actor allow-list.

### Q5: C-7 retry pattern unification — single source or per-context lists?
**My verdict: Single source in `Retry.ps1`, exported as a function
`Test-IsTransientError -ErrorRecord $err -StatusCode $code`.** Per-context
pattern lists drift; the existing inline regexes in RemoteClone and
PRReviewGate prove that. Refactor RemoteClone:215 and PRReviewGate:102/678
to call the shared helper. Add `[string[]] $ExtraPatterns` parameter for
per-context additions without forking the base list.

---

## NEW findings missed by all 4 audit models

### N-1: WorkerPool semaphores leaked on early throw
**Severity:** P1
**Evidence:** `modules/shared/WorkerPool.ps1:110-134` — `$semaphore.Wait()`
inside try, `Release()` in finally. Looks safe. BUT: `Wait()` is *outside*
the try block in the original sense (it's the first line after `try {`),
which means if `$semaphore` resolution at `:105-108` somehow returned a
disposed object after a prior batch, the Wait throws and we never enter
the finally. The lookup `$providerSemaphores[$provider]` runs in the
parallel runspace via `$using:` — if `$ProviderConcurrencyLimits` is
mutated mid-run from another thread, semaphore state is undefined.
**Why missed:** Requires mental simulation of the parallel runspace
lifecycle; static models tend to read each block independently.

### N-2: `Set-StrictMode -Version Latest` + `?.Value` strict-mode interaction
**Severity:** P2
**Evidence:** `modules/shared/Retry.ps1:106-110` — chained null-conditional
property access (`$ErrorRecord.Exception?.PSObject.Properties['Category']?.Value`).
PowerShell 7.4's strict mode treats `?.` against non-existent property
on a strongly-typed object as an error in some configurations. If a
caller passes a non-`ErrorRecord` (e.g., a string) all four candidates
throw before the foreach can run.
**Why missed:** Requires runtime test of edge-case caller input; only
fires when error is rethrown from a wrapper that didn't preserve the
`$_` shape.

### N-3: `Install-PSModules` + `Test-PSModuleAvailable` race window
**Severity:** P2
**Evidence:** `modules/shared/Installer.ps1:683-695` — install-then-recheck.
Between `Install-PSModules` returning and `Test-PSModuleAvailable` running,
PowerShell session module cache may not refresh; module is installed but
`Test-PSModuleAvailable` returns false → goes into `$missing`. Falsely
reports "missing" on a successful install. Only seen across Windows
PowerShell→PS7 hand-off or freshly-imported modules.
**Why missed:** Subtle timing; doesn't surface in tests because tests
mock `Install-PSModules`.

### N-4: `Get-Content ... | ConvertFrom-Json` without `-Depth`
**Severity:** P2
**Evidence:** `Invoke-AzureAnalyzer.ps1:256, 1485, 1584` — manifest /
sinkConfig / triageInput parsed without `-Depth` parameter. Default
depth on `ConvertFrom-Json` is 1024 in PS7 (fine), but the sibling
`ConvertTo-Json` calls at `:1372`, `:1404`, `:1447` use explicit `-Depth 5`
(too low for entities) / `-Depth 30`. Asymmetric depth handling means
a deeply-nested entity that round-trips through portfolio/results loses
fidelity on write but parses fine on read.
**Why missed:** Requires reading both write and read sides together;
audit models usually verify one direction.

### N-5: `Invoke-CopilotTriage.ps1` python detection assumes `python3`/`python` are real interpreters
**Severity:** P2
**Evidence:** `modules/Invoke-CopilotTriage.ps1:18-32` — calls `& python3 --version`
then `& python --version`. On Windows 10/11, `python.exe` and `python3.exe`
are Microsoft Store *App Execution Aliases* by default — they print a
Store launch hint to stderr and exit 9009 even when no Python is
installed. The version regex would not match, so the `if` would skip,
but `$LASTEXITCODE` from the App Execution Alias is non-zero and
`Set-StrictMode -Version Latest` doesn't catch it. Operator on a fresh
Windows box gets `triage.json` = $null and a confusing log.
**Why missed:** Windows-only edge case; CI matrix likely uses
`actions/setup-python` which masks the alias.

---

## Reconciliation with Iris E2E

**Source artifact missing.** `e2e-user-journey-2026-04-23.md` does not
exist on disk. The closest match (`iris-test-audit-2026-04-23.md`) is a
test-coverage audit, not an E2E walkthrough — it tracks wrapper/normalizer
test coverage and identifies 2 missing test files
(`Invoke-CopilotTriage.Tests.ps1`, `Invoke-IdentityCorrelator.Tests.ps1`).

| Iris finding (from `iris-test-audit`) | Covered by | Action |
|---|---|---|
| Missing test: `Invoke-CopilotTriage.Tests.ps1` | partly N-5 + C-15 (revised) | merge into C-15 fix wave; add test in same PR |
| Missing test: `Invoke-IdentityCorrelator.Tests.ps1` | NOT covered | **add C-20**: "wrapper has zero unit tests; ratchet contract not enforceable" — P2 |

**If a real Iris E2E artifact lands later**, re-run reconciliation against
that file. Suggested follow-up: spawn Iris E2E walkthrough explicitly
(`Invoke-AzureAnalyzer.ps1 -SubscriptionId ... -Tools maester,zizmor`)
and capture P0/P1s from the operator-perspective.

---

## Final recommendation

**Approve consolidated doc as basis for fix-wave plan: WITH-REVISIONS.**

Required revisions before treating as canonical:
1. **Reword C-7** — say "three transient-detection *implementations*",
   not "three `$TransientMessagePatterns` definitions".
2. **Reword C-5** — kubelogin is not in the manifest at all; the bug is
   Linux install routing for kubescape (`script` manager not allow-listed)
   and powerpipe (no manager declared, only `url`).
3. **Reword C-15** — duplicate file at `modules/shared/Triage/Invoke-CopilotTriage.ps1`,
   not "dead module returning $null".
4. **Drop C-13** unless Codex re-spawn produces a concrete `-Mode Discovery`
   reference. As-worded, the parameter does not exist.
5. **Promote C-1 to P0 officially** — Codex was right.
6. **Re-validate C-10 and C-18** with a fresh render diff on a 0-finding
   fixture; current evidence is thin.

### Top 3 must-fix-first (regardless of consensus matrix order)

1. **C-1** — per-tool `Invoke-WithTimeout` + WorkerPool deadline. Without
   this, every other fix is moot because the orchestrator can hang.
2. **C-4** — orchestrator exit-code honesty. CI/CD regressions silently
   pass green today.
3. **C-6** — atomic primary output writes. Combined with C-1 fix,
   timeouts will trigger Ctrl+C-style aborts and the JSON outputs need
   to survive that window.

Wave 2 then bundles C-2 + C-5 + C-9 + C-12 + C-14 + C-19 (highest-evidence
P1s + the security smell). Wave 3 hygiene as in the consolidated doc.
