# Kubernetes auth modes for kubescape, falco, and kube-bench

azure-analyzer's three Kubernetes-targeted wrappers accept explicit kubeconfig parameters
so you can scan clusters that are not AKS managed clusters discovered via Azure Resource
Graph (ARG), or scan a specific AKS cluster without going through `az aks get-credentials`.

This is phase 1 of issue [#236](https://github.com/martinopedal/azure-analyzer/issues/236).
Closes [#240](https://github.com/martinopedal/azure-analyzer/issues/240).

## TL;DR

```powershell
# Default (AKS discovery via ARG, fetch credentials per cluster) - unchanged.
.\Invoke-AzureAnalyzer.ps1 -SubscriptionId <sub>

# Scan a single cluster via an existing kubeconfig (BYO cluster).
.\Invoke-AzureAnalyzer.ps1 -SubscriptionId <sub> `
    -KubeconfigPath C:\Users\me\.kube\config `
    -KubeContext my-prod-aks `
    -KubescapeNamespace prod `
    -FalcoNamespace falco-prod `
    -KubeBenchNamespace kube-system
```

## Top-level orchestrator parameters (Invoke-AzureAnalyzer.ps1)

| Parameter | Default | Forwarded to | Notes |
|---|---|---|---|
| `-KubeconfigPath` | (unset) | kubescape, falco, kube-bench | Local file path; URLs rejected. Falls back to `$env:KUBECONFIG` then `~/.kube/config` when only `-KubeContext` is supplied. |
| `-KubeContext`    | (unset) | kubescape, falco, kube-bench | Passed to wrapper CLIs as `--kube-context` / `--context`. |
| `-KubescapeNamespace` | `''` (all namespaces) | kubescape `-Namespace` | Empty means scan all namespaces (default kubescape behavior). |
| `-FalcoNamespace`     | `falco`               | falco `-Namespace`     | Helm release namespace + `kubectl logs` namespace in install mode. |
| `-KubeBenchNamespace` | `kube-system`         | kube-bench `-Namespace` | Namespace where the temporary kube-bench Job is created. |

## Per-wrapper parameters

Each wrapper accepts the same generic surface so the orchestrator can fan them out cleanly.

### Invoke-Kubescape.ps1

```powershell
.\modules\Invoke-Kubescape.ps1 -SubscriptionId <sub> `
    -KubeconfigPath C:\path\to\kubeconfig `
    -KubeContext my-cluster `
    -Namespace ''         # default: scan all namespaces
```

Kubeconfig mode short-circuits the ARG discovery + `az aks get-credentials` flow and
runs a single `kubescape scan --kube-context <ctx> [--include-namespaces <ns>]` against
the supplied kubeconfig.

### Invoke-Falco.ps1

```powershell
.\modules\Invoke-Falco.ps1 -SubscriptionId <sub> -InstallFalco `
    -KubeconfigPath C:\path\to\kubeconfig `
    -KubeContext my-cluster `
    -Namespace falco      # default
```

Kubeconfig mode applies only to `-InstallFalco` (the cluster-touching path).
Query mode reads Falco-related Microsoft.Security alerts from Azure ARG and is
unaffected by `-KubeconfigPath`.

### Invoke-KubeBench.ps1

```powershell
.\modules\Invoke-KubeBench.ps1 -SubscriptionId <sub> `
    -KubeconfigPath C:\path\to\kubeconfig `
    -KubeContext my-cluster `
    -Namespace kube-system   # default; the kube-bench Job lands here
```

## Validation

`-KubeconfigPath` is validated at the wrapper boundary:

- Empty value -> rejected.
- URL-style values (`https://...`, `s3://...`) -> rejected (no remote fetch).
- File does not exist -> rejected.

Error messages are sanitized through `Remove-Credentials` before they reach logs or
the v1 envelope.

## Backward compatibility

All new parameters are optional with safe defaults. Existing call sites that do
not pass any of them keep their pre-#240 behavior: AKS discovery via ARG, per-cluster
isolated kubeconfig via `az aks get-credentials`, namespace defaults preserved
(`falco`, `kube-system`, all-namespaces for kubescape). User-supplied kubeconfig
files are never deleted by cleanup logic.

## What's coming

- [#241](https://github.com/martinopedal/azure-analyzer/issues/241) and
  [#242](https://github.com/martinopedal/azure-analyzer/issues/242) build on this
  param surface to add additional Kubernetes auth modes (token / service-account /
  in-cluster). The param shape introduced here is intended to be forward-compatible.
