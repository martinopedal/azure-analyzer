# Independent Required-to-Work Fault Audit (GPT-5.3-codex)
**Date:** 2026-04-23  
**Scope:** REQUIRED-TO-WORK faults only (end-to-end execution blockers)  
**Repo:** `C:\git\azure-analyzer`

## Verdict
**P0 faults found: YES (1).**  
The orchestrator can hang indefinitely when any long-running wrapper call stalls.

---

## P0 Findings

### P0-1 — No hard execution timeout for wrapper jobs (run can hang forever)
**What breaks if we don't fix this?**  
One stuck CLI call can block the entire analyzer run forever, producing no final `results.json/entities.json` completion and wedging CI/automation.

**Evidence (code):**
- `modules/shared/WorkerPool.ps1:92-93` — `"$results = $ToolSpecs | ForEach-Object -Parallel {"`
- `modules/shared/WorkerPool.ps1:149` — `"} -ThrottleLimit $MaxParallel"`
- No per-tool timeout/cancellation path exists in this execution loop.
- Multiple wrappers invoke external CLIs without `Invoke-WithTimeout`, e.g.:
  - `modules/Invoke-Trivy.ps1:293` — `"& trivy $ScanType --format json --scanners vuln,misconfig --output $reportFile $RepoPath ..."`
  - `modules/Invoke-Zizmor.ps1:304` — `"& zizmor --format=json --no-exit-codes $scanPath ..."`
  - `modules/Invoke-Kubescape.ps1:415` — `"& kubescape @ksArgs 2>&1 | Out-Null"`
  - `modules/Invoke-KubeBench.ps1:450` — `"& kubectl @kctxArgs apply -f $jobManifest ..."`
  - `modules/Invoke-Falco.ps1:508-509` — `"& helm repo add ..."`, `"& helm repo update ..."`

**Reproduce:**
1. Make any called CLI block/hang (network stall, hung kube API, stuck CLI process).
2. Run `Invoke-AzureAnalyzer.ps1` including that wrapper.
3. Observe no global timeout/cancellation; run does not complete.

**Fix:**
- Add per-tool timeout budget in `Invoke-ParallelTools` (e.g., run each spec in child process/runspace with max wall-clock).
- Enforce `Invoke-WithTimeout` (300s default) for all wrapper external commands.

**Effort:** Medium.

---

## P1 Findings

### P1-1 — `-Mode Discovery` command path is broken (parameter missing)
**What breaks if we don't fix this?**  
Discovery-mode bootstrap path is unavailable; scripted onboarding command fails immediately.

**Evidence (code + runtime):**
- `Invoke-AzureAnalyzer.ps1:93-130` param block has no `Mode` parameter.
- Runtime result: `"A parameter cannot be found that matches parameter name 'Mode'."` when executing `pwsh ...\Invoke-AzureAnalyzer.ps1 -Mode Discovery ...`.

**Reproduce:**
```powershell
pwsh -File .\Invoke-AzureAnalyzer.ps1 -Mode Discovery -SkipPrereqCheck
```

**Fix:**
- Either implement `-Mode` (`Help/Discovery/Run`) or remove all docs/automation that call it.

**Effort:** Low.

### P1-2 — Manifest JSON parsing is unguarded (hard crash on malformed manifest)
**What breaks if we don't fix this?**  
Any malformed `tools/tool-manifest.json` aborts startup with an unstructured terminating exception before tool selection/prereq logic.

**Evidence (code):**
- `Invoke-AzureAnalyzer.ps1:255` — `"$manifest = Get-Content ... 'tool-manifest.json' -Raw | ConvertFrom-Json"`
- No surrounding `try/catch` around this parse.

**Reproduce:**
1. Introduce invalid JSON in `tools/tool-manifest.json`.
2. Run orchestrator.
3. Observe immediate terminating parse failure.

**Fix:**
- Wrap manifest load in `try/catch` and emit `New-FindingError` (`ConfigurationError`) with sanitized details and actionable remediation.

**Effort:** Low.

### P1-3 — Primary output files are written non-atomically (corruption risk on interrupt)
**What breaks if we don't fix this?**  
If interrupted (Ctrl+C/process kill/power event) during write, JSON artifacts can be truncated/corrupt; downstream report/diff/triage consumers fail.

**Evidence (code):**
- Direct writes:
  - `Invoke-AzureAnalyzer.ps1:1365` — `"Set-Content -Path $outputFile ..."`
  - `Invoke-AzureAnalyzer.ps1:1397` — `"Set-Content -Path $entitiesFile ..."`
  - `Invoke-AzureAnalyzer.ps1:1440` — `"Set-Content -Path $portfolioFile ..."`
  - `Invoke-AzureAnalyzer.ps1:1535` — `"$statusJson | Set-Content -Path $statusFile ..."`
  - `Invoke-AzureAnalyzer.ps1:1886` — `"$errorsJson | Set-Content -Path $errorsFile ..."`
- Atomic pattern exists but only for run metadata:
  - `Invoke-AzureAnalyzer.ps1:1752-1754` — temp write + `Move-Item`.

**Reproduce:**
1. Start run with meaningful output volume.
2. Interrupt process during write window.
3. Validate malformed/truncated JSON in one of above files.

**Fix:**
- Use temp-file + atomic rename for all primary JSON artifacts.

**Effort:** Medium.

---

## P2 Findings

### P2-1 — Retry helper misclassifies common transient 502 as permanent
**What breaks if we don't fix this?**  
Transient upstream failures (502) are not retried; wrappers can fail fast in otherwise recoverable conditions.

**Evidence (code):**
- Retryable status list excludes 502:
  - `modules/shared/Retry.ps1:23-24` — includes 429/503/504/408 but not 502.
- Runtime reproduction showed single attempt only:
  - observed output: `"ATTEMPTS=1"` and `"Non-retryable ... HTTP 502 Bad Gateway"`.

**Reproduce:**
```powershell
. .\modules\shared\Retry.ps1
$script:attempts=0
Invoke-WithRetry -MaxAttempts 3 -ScriptBlock { $script:attempts++; throw 'HTTP 502 Bad Gateway' }
```

**Fix:**
- Treat 502 as retryable in status-code and/or transient-pattern paths.

**Effort:** Low.

---

## Wrapper-Level Required Checks (Failures)

### Wrappers failing timeout enforcement (300s hard cap absent on external process calls)
- `modules/Invoke-Trivy.ps1` (`line 293`)
- `modules/Invoke-Zizmor.ps1` (`line 304`)
- `modules/Invoke-Kubescape.ps1` (`line 415`)
- `modules/Invoke-KubeBench.ps1` (`lines 450, 468`)
- `modules/Invoke-Falco.ps1` (`lines 508-509, 521`)

### Wrapper missing explicit `$ErrorActionPreference='Stop'`
- `modules/Invoke-CopilotTriage.ps1` (StrictMode set at line 16; no EAP assignment in file)

---

## Normalizer Audit Result
No REQUIRED-TO-WORK normalizer faults confirmed that block end-to-end execution.  
Observed normalizers generally guard empty input and return `@()` on non-success tool status.

---

## Shared Infra Audit Result
- Confirmed blocker: WorkerPool lacks per-tool timeout/cancellation (P0-1).
- Confirmed degradation: Retry helper does not retry 502 (P2-1).

---

## Orchestrator Audit Result
- Confirmed blockers/degraders: P1-1, P1-2, P1-3.
- `tool-manifest` missing wrapper script path is handled gracefully by runner envelope:
  - `Invoke-AzureAnalyzer.ps1:733-739` returns failed result object with `Findings=@()`.

---

## CI Workflow Audit Result
No REQUIRED-TO-WORK faults found in workflow hygiene dimensions requested:
- explicit `permissions:` present
- `timeout-minutes` present
- actions are SHA-pinned
- no direct PR-head checkout under `pull_request_target` found in reviewed files

---

## Test Gate Audit Result
No REQUIRED-TO-WORK blocker found from skip/pending markers. Skips observed are feature- or environment-gated, not silently masking core orchestrator execution.

---

## Auth + Identity Audit Result
No confirmed required-to-work code defect found that leaks tokens into persisted finding artifacts in the audited paths. Token-expiry recovery remains dependent on underlying CLIs/services.

---

## Cold-Start Trace (executed)
1. `pwsh -File .\Invoke-AzureAnalyzer.ps1 -Help` → works.
2. `pwsh -File .\Invoke-AzureAnalyzer.ps1 -Mode Discovery ...` → fails (`Mode` parameter missing).
3. `pwsh -File .\Invoke-AzureAnalyzer.ps1 -SkipPrereqCheck ...` in interactive TTY prompted for mandatory params and blocked on input.
4. `pwsh -File .\Invoke-AzureAnalyzer.ps1 -NonInteractive -SkipPrereqCheck ...` fails fast with unresolved required inputs (exit code 2), which is expected.

---

## Gaps Prior Audits Missed
1. **Global hang risk from missing per-wrapper timeout in WorkerPool + unbounded CLI wrappers** (P0).  
2. **`-Mode Discovery` path is broken at parameter-binding level** (P1).  
3. **Primary artifact writes are non-atomic, unlike run-metadata path** (P1).  
4. **Retry helper does not retry transient 502** with demonstrated single-attempt failure (P2).

---

## Items Checked Clean
- Manifest/tool missing-script handling (graceful fail envelope path exists).
- Triaging malformed `results.json` for AI triage is catch-protected (`Invoke-AzureAnalyzer.ps1:1592-1594`).
- Workflow SHA pinning and explicit permissions/timeouts across reviewed workflows.
