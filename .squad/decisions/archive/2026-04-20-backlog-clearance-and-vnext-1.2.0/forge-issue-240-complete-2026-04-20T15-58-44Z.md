# Forge completion note: issue #240

- Issue: #240 (parent #236, sibling #241/#242)
- PR: #269
- Merge SHA: 18c70ea5499acd9d8236f020309e8c066ee326c6
- Branch: feat/240-k8s-params (deleted post-merge)
- Triage reference: .squad/decisions/inbox/lead-backlog-triage-2026-04-20-aks-reports-cost-173025.md

## Scope delivered

Phase 1 of the K8s auth surface: explicit `-KubeconfigPath`, `-KubeContext`, and per-tool `-Namespace` parameters threaded through the three K8s wrappers and the orchestrator. Kubeconfig-mode short-circuits Azure Resource Graph AKS discovery and `az aks get-credentials`, allowing the wrappers to target any cluster reachable from a kubeconfig (on-prem, EKS/GKE, kind/k3s, etc.) instead of being AKS-only.

## Wrappers touched (3)

| Wrapper | Default `-Namespace` | Notes |
|---|---|---|
| `modules/Invoke-Kubescape.ps1` | `''` (empty = all namespaces) | Threads `--kube-context` and `--include-namespaces` into `kubescape scan` |
| `modules/Invoke-Falco.ps1` | `'falco'` | Kubeconfig mode applies only to `-InstallFalco`; query mode (ARG) is unaffected |
| `modules/Invoke-KubeBench.ps1` | `'kube-system'` | Job manifest namespace + all kubectl invocations parameterized |

Orchestrator: `Invoke-AzureAnalyzer.ps1` exposes 5 new top-level params (`-KubeconfigPath`, `-KubeContext`, `-KubescapeNamespace`, `-FalcoNamespace`, `-KubeBenchNamespace`) with conditional pass-through via `$PSBoundParameters.ContainsKey(...)` so existing call sites behave identically.

## Validation contract

- HTTPS/URL-style values rejected with regex `^[a-z][a-z0-9+.-]*://` -> "URLs are not accepted" throw.
- Non-existent kubeconfig path -> "file does not exist" throw.
- `-KubeContext` alone falls back to `$env:KUBECONFIG` then `$HOME/.kube/config`; missing default -> clear throw.
- Kubeconfig path text scrubbed via `Remove-Credentials` before being included in error messages.
- User-supplied kubeconfig is NEVER deleted by wrapper cleanup (only orchestrator-generated temp kubeconfigs are removed).

## Pester delta

- Baseline before: 1213 passing
- After PR: 1233 passing, 0 failing, 5 skipped (+20 net)
- New tests: 5 (Kubescape) + 5 (Falco) + 4 (KubeBench) + 4 (orchestrator AST) + 2 (CHANGELOG/docs) = 20 new
- Fixture: `tests/fixtures/kubeconfig-mock.yaml` (synthetic, server `kubernetes.example.invalid:6443`)

## Docs updated

- `CHANGELOG.md` -> Unreleased > Added entry
- `docs/consumer/README.md` -> link to k8s-auth.md
- `docs/consumer/k8s-auth.md` -> NEW; TL;DR + per-wrapper examples + validation + backward-compat
- `docs/consumer/permissions/{kubescape,falco,kube-bench}.md` -> "Auth context" section + adjusted "Local CLI requirements"

## CI iteration log

1. First push: macOS-only failure (2 tests in KubeBench validation).
   - Root cause: KubeBench's `kubectl` presence check ran BEFORE kubeconfig validation, so on macOS runners (kubectl absent) the wrapper returned `Status=Skipped` instead of throwing. Falco/Kubescape had the correct order.
   - Fix: re-ordered validation to run first, matching sibling wrappers (commit 94597c0).
2. Second push: all 16 checks green on rebased HEAD; merged with `--admin --squash --delete-branch`.

Required checks: `Analyze (actions)` + `rubberduck-gate` (skipped: non-squad-author).

## Extension hooks for #241 / #242

The kubeconfig branch was designed as an extension seam:

- **`$kubeconfigModeRequested`** predicate: `$PSBoundParameters.ContainsKey('KubeconfigPath') -or $PSBoundParameters.ContainsKey('KubeContext')`  -  single decision point that future PRs can reuse to gate "skip Azure-specific discovery" behavior for new K8s-aware wrappers.
- **Synthetic-cluster pattern**: when in kubeconfig mode each wrapper builds a single-element `$clusters` array with extra props `kubeconfigPath` + `kubeContext` so the existing `foreach ($cluster in $clusters)` loop body can branch via `if ($cluster.PSObject.Properties['kubeconfigPath'])`  -  no separate code path required.
- **ResourceId convention**: kubeconfig mode emits `kubeconfig:<context-name-or-default>` so report aggregation can group by source cluster without leaking Azure-specific schema.

#241 (cluster identity normalization) and #242 (multi-context fan-out) can plug into both seams without re-touching the validation block or the orchestrator pass-through.

## Em-dash gate

`git diff | Select-String "^\+" | Select-String " - "` returned zero. Pre-existing em-dashes in untouched files were not modified.

Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>
