# LASTEXITCODE audit — 2026-04-22

Follow-up to issue #470 / PR #475.

## Scope

- `Invoke-AzureAnalyzer.ps1`
- `modules/**/*.ps1` (excluding `modules/shared/*` already reviewed in PR #469 / #475)
- `scripts/**/*.ps1`
- Tests under `tests/` are out of scope (mocks own their own exit-code semantics).

## Method

- Grep for `LASTEXITCODE` and for native-binary invocation regex.
- Calls already wrapped in `Invoke-WithRetry` / `Invoke-WithTimeout` / `Invoke-WithInstallRetry` / `Invoke-RemoteRepoClone` are exempt: those helpers own exit-code handling.
- Class A: bogus `if ($LASTEXITCODE ...)` checks after non-native commands (PS cmdlets, .NET methods).
- Class B: native invocation with no LASTEXITCODE check and no surrounding helper.

## Findings — pipe-separated inventory

Severity | File | Line | Class | Command | Justification
---|---|---|---|---|---
P1 | modules/Invoke-KubeBench.ps1 | 437 | B | `kubectl wait` | Wait timeout falls through silently to `kubectl logs`, which can capture partial / pre-completion output and parse cleanly into a truncated finding set, masking incomplete benchmarks per cluster.
P1 | modules/Invoke-KubeBench.ps1 | 438 | B | `kubectl logs` | Logs RBAC failure or pod-evicted is masked by the downstream `IsNullOrWhiteSpace` guard, which would treat the cluster as silently failed without an actionable diagnostic.
P2 | Invoke-AzureAnalyzer.ps1 | 1704 | B | `chmod 700` (viewer token dir) | Inconsistent with line 1725 chmod 600 which IS checked. POSIX-only. Soft fall-through risk: dir not locked down but file is.
P3 | modules/Invoke-Trivy.ps1 | (version probe) | B | `trivy --version` | Probe is null-checked on stdout instead of LASTEXITCODE; functionally equivalent for `--version`, but inconsistent with the rest of the codebase.
P3 | modules/Invoke-Zizmor.ps1 | (version probe) | B | `zizmor --version` | Same pattern as trivy probe.
P3 | modules/Invoke-Kubescape.ps1 | (version probe) | B | `kubescape version` | Same pattern as trivy probe.
P3 | modules/Invoke-KubeBench.ps1 | 510 | B | `kubectl delete --ignore-not-found` | Intentional fail-soft cleanup inside `finally` block. Leave alone.
P3 | modules/Invoke-KubeBench.ps1 | (umask) | B | `sh -c umask` capture | Best-effort umask probe. Acceptable as-is.

## Class A summary

Zero hits. Every existing `$LASTEXITCODE` check sits after a legitimate native CLI call.

## P1 detail — modules/Invoke-KubeBench.ps1

### Pre-fix

```powershell
& kubectl @kctxArgs -n $Namespace wait --for=condition=complete "job/$jobName" --timeout="$($JobTimeoutSeconds)s" 2>&1 | Out-Null
& kubectl @kctxArgs -n $Namespace logs "job/$jobName" 2>&1 | Set-Variable -Name kubeBenchLogs
if ([string]::IsNullOrWhiteSpace($kubeBenchLogs)) {
    $failed++
    continue
}
```

### Failure modes

1. **Wait timeout**: `kubectl wait --for=condition=complete --timeout=Ns` returns non-zero on timeout. Without a check, control flows immediately into `kubectl logs`, which may capture partial / mid-execution output. The downstream `ConvertFrom-KubeBenchLogJson` may parse those partial logs into a small but non-empty finding set, silently misrepresenting the cluster as "scanned with N findings" instead of "scan timed out".
2. **Logs RBAC / eviction**: `kubectl logs job/...` may fail with permission-denied or pod-not-found while still producing some stderr in `$kubeBenchLogs`. The `IsNullOrWhiteSpace` guard only catches empty captures, not non-empty error captures. Same silent-misrepresentation outcome.

### Post-fix

Two new exit-code branches per the local "warn + `$failed++; continue`" idiom (matches lines 504-505), each emitting a structured `Write-FindingError` with category (`TimeoutExceeded` for wait, `IOFailure` for logs), sanitized cluster context (cluster name, kube context, namespace), and a `Remediation` next-action.

Wrapper now dot-sources `modules/shared/Errors.ps1` after `Sanitize.ps1`, with the standard `Get-Command` guard + shim fallback (mirrors `Invoke-AzureQuotaReports.ps1:49` for `New-InstallerError`).

Regression guarded by `tests/wrappers/Invoke-KubeBench.LastExitCode.Tests.ps1` — text-based AST guard that fails CI if either `kubectl wait` or `kubectl logs` loses its exit-code check.

## PR plan

- **P1 → this PR** (`fix/kube-bench-silent-kubectl-failures`): both kube-bench fixes + regression test + this audit doc + CHANGELOG.
- **P2** (deferred): chmod 700 viewer token dir consistency. 1-line fix; can fold into a future viewer hardening PR.
- **P3** (no action): version probes and intentional cleanup are correct as-written; documented here for future auditors so they don't churn on them.

## Exempt sites

- `modules/shared/Resolve-PRReviewThreads.ps1` (PR #469): canonical LASTEXITCODE-reset pattern for retry-loop ScriptBlocks under Pester function mocks.
- `modules/shared/Invoke-PRReviewGate.ps1` (PR #475): same pattern applied at lines 75 and 615-618.
- `modules/shared/Invoke-PRAdvisoryGate.ps1` (PR #475): same pattern applied at lines 260, 408, 475, 628, 809.
- All wrappers using `Invoke-WithRetry`, `Invoke-WithTimeout`, or `Invoke-WithInstallRetry`: helper owns exit-code handling.
- All wrappers using `Invoke-RemoteRepoClone`: shared helper owns the git clone exit code.
