
---

## Issue #236 - AKS auth parameters for K8s wrappers (2025-01-26)

**Audit verdict:** ✅ Ready to implement. No schema work needed.

**Key findings:**
- All 3 K8s wrappers (kubescape, falco, kube-bench) use temp kubeconfig isolation pattern (z aks get-credentials --file <temp>)
- Falco hardcodes --namespace falco (line 243) - easily parameterized
- Orchestrator already has subscription-scope param forwarding block (lines 636-669) - just add 4 new conditionals
- Top-level param block has room for 4 new K8s params (after line 136)
- Test baseline is 842/842 green - new test cases must preserve

**Implementation split into 3 phases:**
- #240 - Phase 1: Explicit kubeconfig/namespace (M effort, no external deps, zero breaking changes)
- #241 - Phase 2: kubelogin AAD modes (M/L effort, requires kubelogin CLI)
- #242 - Phase 3: In-cluster workload identity (L effort, requires pod SA)

**Line ranges confirmed stable:**
- Invoke-AzureAnalyzer.ps1: param block 86-137, forwarding 636-669
- modules/Invoke-Kubescape.ps1: param block 31-35, kubeconfig 121-147
- modules/Invoke-Falco.ps1: param block 26-32, kubeconfig 234-247
- PERMISSIONS.md: kubescape/falco mentioned at 109-110

**Documentation plan:** PERMISSIONS.md gets new K8s auth modes table (3 rows in Phase 1, +3 in Phase 2, +1 in Phase 3). README.md gets cluster compatibility matrix (5 cluster types × 4 auth modes).

**Test strategy:** Mock kubeconfig fixture + 3 new Describe blocks per wrapper (explicit kubeconfig / kubelogin / in-cluster). Total: 9 new test cases across 3 phases.

**Posted:** https://github.com/martinopedal/azure-analyzer/issues/236#issuecomment-4280535774

