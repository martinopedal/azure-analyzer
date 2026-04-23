# Multi-Model Fault Audit — Consolidated (2026-04-23)

> ⚠️ **RECOVERY ARTIFACT.** All 4 audit agents (Opus 4.7, Opus 4.6-1M, GPT-5.3-codex, GPT-5.4) hit the platform Silent-Success bug — they returned substantive verbal summaries but did NOT actually persist their deliverable files. This consolidated file is reconstructed from the read_agent transcripts captured by Squad Coordinator. Fresh re-spawn is in flight with explicit file-existence verification; this artifact will be replaced when the per-model files materialize.

**Models:**
- Opus 4.7 (lead, cross-cutting) — verdict: RISKS, 0 P0, 7 P1, 4 cross-cutting
- Opus 4.6-1M (depth scan) — verdict: RISKS, 0 P0, 3 P1, 3 P2
- GPT-5.3-codex (code-defect specialist) — verdict: RISKS, 1 P0
- GPT-5.4 (Goldeneye substitute, breadth/operator-UX) — verdict: 1 P0, 3 P1, 1 P2

**Goldeneye honesty disclosure:** Goldeneye is NOT in the current 15-model spawn catalog. GPT-5.4 used as the closest breadth equivalent. Re-spawn when Goldeneye returns.

---

## Headline verdict

The tool **runs** but contains multiple silent-degradation paths and at least 2 confirmed P0 contract bugs. No model considers any single defect merge-blocking on its own, but the cumulative effect is that an operator can run a "successful" assessment that silently dropped tool results, exited 0 despite full failure, or installed nothing despite asking for `-InstallMissingModules`. Banner-down gate REQUIRES Wave 1 + Wave 2 fixes. Strong cross-model consensus on retry/timeout, advisory-Pester honesty gap, and orchestrator exit-code semantics.

---

## Consensus matrix (sorted by # of models flagging)

| ID  | Finding | Sev | Models | Best citation |
|-----|---------|-----|--------|---------------|
| C-1 | **CLI wrappers lack `Invoke-WithTimeout` AND WorkerPool has no per-tool runtime cap** — one stuck CLI hangs orchestrator forever. Wrappers union: zizmor, trivy, gitleaks, scorecard, prowler, kubescape, kube-bench, falco, IaCBicep, IaCTerraform, powerpipe, azqr, PSRule, WARA, Maester | **P0** | Opus 4.7 (P1-1), Opus 4.6-1M (F-2), GPT-5.3-codex (P0 C-1) | `WorkerPool.ps1` no cap; `& <cli>` direct calls in 11+ wrappers |
| C-2 | **10+ wrappers missing `Invoke-WithRetry`** — transient 429/timeout silently drops tool results | P1 | Opus 4.7 (P1-1 overlap), Opus 4.6-1M (F-1) | azqr, prowler, scorecard, trivy, PSRule, WARA, Maester, Powerpipe, IaC-Bicep, IaC-Terraform |
| C-3 | **Pester `Test` job is advisory, only `Analyze (actions)` is required** — broken tests can merge to main; PowerShell (the repo's primary language) has zero blocking gate | P1 | Opus 4.7 (X-3), Opus 4.6-1M (F-3) | `.github/workflows/ci.yml`; required-checks list |
| C-4 | **Orchestrator exits 0 even when every tool failed** — single-tenant runs return success exit code despite total failure. Cardinal CI/CD honesty bug | P1 | Opus 4.7 (P1-4) — Codex gap to verify on respawn | `Invoke-AzureAnalyzer.ps1:1898` (tail falls off implicitly) |
| C-5 | **Installer/manifest contract broken for `kubescape`, `powerpipe`, `kubelogin`** — `-InstallMissingModules` silently fails to install these despite manifest declaring them | **P0** | GPT-5.4 (P0) | `tools/tool-manifest.json` install blocks vs `Installer.ps1` provider routing |
| C-6 | **Bare `Set-Content` on primary outputs** (`results.json`, `entities.json`, `portfolio.json`) — non-atomic; Ctrl+C mid-write produces corrupt output. `run-metadata.json` already does temp+`Move-Item` — apply consistently | P1 | Opus 4.7 (P1-5), GPT-5.3-codex (C-4) | grep `Set-Content` against output writers |
| C-7 | **Three retry pattern lists drift apart** — `Retry.ps1` master ⊋ `RemoteClone.ps1` ⊋ `Invoke-PRReviewGate.ps1`. Gate regex misses `EOF`, `connection reset`, `broken pipe` | P1 | Opus 4.7 (P1-3 / X-1) | three distinct `$TransientMessagePatterns` definitions |
| C-8 | **`-AlzReferenceMode` is a no-op** — switch parses but does nothing | P1 | GPT-5.4 (P1) | `Invoke-AzureAnalyzer.ps1` switch handler |
| C-9 | **Failure remediation dropped from reports** — when a wrapper errors, the structured remediation field is not surfaced in HTML/MD | P1 | GPT-5.4 (P1) | `New-HtmlReport.ps1` / `New-MdReport.ps1` failure path |
| C-10 | **HTML/MD disagree on zero-finding posture** — same input, different empty-state UX | P1 | GPT-5.4 (P1) | renderer divergence |
| C-11 | **Manifest has no duplicate-name runtime guard** — `Where … \| Select -First 1` makes lookups order-dependent | P1 | Opus 4.7 (P1-7 / X-4) | `scripts/Sync-AlzQueries.ps1:83-90` and others |
| C-12 | **`auto-approve-bot-runs.yml:83` includes human maintainer `martinopedal` in trusted-bot allow-list** — security smell | P1 | Opus 4.7 (P1-6) | workflow file line 83 |
| C-13 | **`-Mode Discovery` parameter broken** | P1 | GPT-5.3-codex (C-2) | `Invoke-AzureAnalyzer.ps1` mode dispatch |
| C-14 | **Unguarded manifest JSON parse** — bad manifest crashes orchestrator without actionable error | P1 | GPT-5.3-codex (C-3) | `tool-manifest.json` load path |
| C-15 | **Legacy dead module `modules/Invoke-CopilotTriage.ps1`** returns `$null`; coexists with real module | P2 | Opus 4.6-1M (F-4) | file presence |
| C-16 | **Duplicate function defs in `Schema.ps1`** for `Get-SchemaValidationFailures` / `Reset-SchemaValidationFailures` — last wins per memory | P2 | Opus 4.6-1M (F-5) | `Schema.ps1` |
| C-17 | **`AttackPath.Tests.ps1:133` unconditional `-Skip`** — masks regressions when Track D lands | P2 | Opus 4.6-1M (F-6) | test file |
| C-18 | **`run-metadata.json` contract drift** — Markdown headers lose run identity | P2 | GPT-5.4 (P2) | `New-MdReport.ps1` header block |
| C-19 | **Retry helper misclassifies 502** — should retry, currently does not | P2 | GPT-5.3-codex (C-5) | `Retry.ps1` `$TransientMessagePatterns` |

---

## Unique findings (single-model)

### Opus 4.7 (lead) only
- **X-2** — Required CodeQL scan covers GitHub Actions only; PowerShell extractor doesn't exist (architectural — confirms repo policy is doing best available).

### Opus 4.6-1M only
- All depth-scan findings absorbed into consensus matrix above.

### GPT-5.3-codex only
- C-2 (`-Mode Discovery` broken) — would benefit from Opus 4.7 cross-check on respawn.

### GPT-5.4 (Goldeneye sub) only
- C-8, C-9, C-10, C-18 — all operator-UX surface findings. Goldeneye-substitute breadth lens caught what code-first models missed.

---

## Contradictions / disagreements

**None.** No model contradicted another's finding. Severity escalations on overlapping findings (e.g., C-1 timeout: Opus models say P1, Codex says P0) are reconciled UP — final consensus severity is the highest assigned by any model, since under-rating risk is more dangerous than over-rating.

---

## Goldeneye substitution caveats

GPT-5.4 covered breadth/operator-UX adequately but may have missed:
- Cross-model architectural holism (Goldeneye historically catches "X is sane on its own but combined with Y creates Z" patterns)
- Long-context trace reasoning (Goldeneye has different attention patterns)

**Recommendation:** Re-spawn the 4-model audit once Goldeneye returns to the spawn catalog. Track this as a follow-up evidence task.

---

## Recommended fix wave order

### Wave 1 — E2E blockers (must merge before banner-down)
- **C-1** per-tool timeout + WorkerPool runtime cap (P0)
- **C-5** installer manifest contract for kubescape/powerpipe/kubelogin (P0)
- **C-4** orchestrator exit-code honesty (P1, but exit-code semantics ARE a CI blocker)
- **C-13** `-Mode Discovery` (P1, blocks documented user workflow)
- **C-14** manifest JSON parse guard (P1, crashes on malformed manifest)

### Wave 2 — Silent-degradation P1s
- **C-2** retry coverage on 10+ wrappers
- **C-3** make Pester required (governance)
- **C-6** atomic primary output writes
- **C-7** retry pattern unification
- **C-8** `-AlzReferenceMode` implement-or-remove
- **C-9** failure-remediation surfacing in reports
- **C-10** HTML/MD zero-finding parity
- **C-11** manifest duplicate-name guard
- **C-12** auto-approve allow-list cleanup

### Wave 3 — P2 hygiene
- **C-15** delete `Invoke-CopilotTriage.ps1`
- **C-16** dedupe `Schema.ps1` functions
- **C-17** un-skip `AttackPath.Tests.ps1:133`
- **C-18** `run-metadata.json` contract restoration
- **C-19** retry helper 502 handling

---

## Open questions for the 2-model rubberduck (Opus 4.7 + GPT-5.3-codex)

1. **C-1 severity:** Codex says P0, Opus models say P1. Final call?
2. **C-3 governance:** Making Pester required is a process change. Does it land in this fix wave or as a separate governance PR?
3. **C-4 exit-code:** Should non-zero be the default on ANY wrapper failure, or only on N+ failures (operator-config threshold)?
4. **C-12 allow-list:** Confirm `martinopedal` in trusted-bot allow-list is genuinely intended for automation or actually accidental?
5. **C-7 retry pattern unification:** Single source of truth in `Retry.ps1`, or per-context pattern lists with shared base?

---

## Recovery instructions for next session

If this reconstructed consolidation is replaced by genuine per-model deliverables (after audit re-spawn), re-run consolidation against:
- `multimodel-opus-47-2026-04-23.md`
- `multimodel-opus-46-1m-2026-04-23.md`
- `multimodel-gpt53-codex-2026-04-23.md`
- `multimodel-gpt54-2026-04-23.md`

Use Sage haiku-4.5 with explicit instruction to read each file via `view` tool BEFORE writing consolidation, and verify file existence with `Test-Path` after writing.
