# Kubernetes auth modes for kubescape, falco, and kube-bench

azure-analyzer's three Kubernetes-targeted wrappers accept explicit kubeconfig parameters
so you can scan clusters that are not AKS managed clusters discovered via Azure Resource
Graph (ARG), or scan a specific AKS cluster without going through `az aks get-credentials`.

Closes [#236](https://github.com/martinopedal/azure-analyzer/issues/236),
[#240](https://github.com/martinopedal/azure-analyzer/issues/240),
[#241](https://github.com/martinopedal/azure-analyzer/issues/241),
[#242](https://github.com/martinopedal/azure-analyzer/issues/242).

## Auth modes (`-KubeAuthMode`)

| Mode | When to use | Sub-params (required) | Sub-params (optional) | kubelogin login flow |
|---|---|---|---|---|
| `Default` | Local-only kubeconfig, or AKS clusters whose exec plugin entries already work (e.g. `azure-cli` on a workstation that ran `az login`). | none | none | none (no `kubelogin convert`) |
| `Kubelogin` | AKS with AAD-integrated cluster from a non-AAD-aware kubeconfig (e.g. CI runner). Converts the kubeconfig in place using kubelogin so `kubectl` requests get an AAD token. | none for `azurecli` flow | `-KubeloginServerId`, `-KubeloginClientId` + `-KubeloginTenantId` (must be set together for `spn` flow) | `azurecli` (default) or `spn` if both client+tenant supplied |
| `WorkloadIdentity` | Running inside an AKS pod (or any K8s pod) with Azure Workload Identity federation configured. azure-analyzer assumes the federated token of the SA. | `-WorkloadIdentityClientId`, `-WorkloadIdentityTenantId`, `-WorkloadIdentityServiceAccountToken` (path to the projected SA token, or the literal token value) | `-KubeloginServerId` | `workloadidentity` |

> Backward compatibility: `KubeAuthMode='Default'` is the default and is a strict no-op.
> Existing kubeconfig-based invocations continue to work unchanged.

### Examples

```powershell
# AAD-integrated AKS via az-cli login (most common CI case).
.\Invoke-AzureAnalyzer.ps1 -SubscriptionId <sub> `
    -KubeconfigPath ./kubeconfig -KubeContext my-aad-aks `
    -KubeAuthMode Kubelogin

# AAD-integrated AKS via SPN (CI federated to AAD app).
.\Invoke-AzureAnalyzer.ps1 -SubscriptionId <sub> `
    -KubeconfigPath ./kubeconfig -KubeContext my-aad-aks `
    -KubeAuthMode Kubelogin `
    -KubeloginClientId <appId> -KubeloginTenantId <tenant> `
    -KubeloginServerId 6dae42f8-4368-4678-94ff-3960e28e3630   # AKS AAD server app

# In-cluster Workload Identity (pod with projected SA token).
.\Invoke-AzureAnalyzer.ps1 -SubscriptionId <sub> `
    -KubeconfigPath /var/run/kubeconfig -KubeContext aad-cluster `
    -KubeAuthMode WorkloadIdentity `
    -WorkloadIdentityClientId <wiClientId> `
    -WorkloadIdentityTenantId <tenant> `
    -WorkloadIdentityServiceAccountToken /var/run/secrets/azure/tokens/azure-identity-token
```

### kubelogin prerequisite

Both `Kubelogin` and `WorkloadIdentity` modes require the `kubelogin` binary on PATH.
azure-analyzer registers it as a manifest prerequisite (auto-installed by
`-InstallMissingModules` when at least one K8s wrapper will run):

| Platform | Install |
|---|---|
| Windows | `winget install Azure.Kubelogin` |
| macOS   | `brew install Azure/kubelogin/kubelogin` |
| Linux   | `az aks install-cli` (also installs kubectl) or download from <https://github.com/Azure/kubelogin/releases> |

azure-analyzer copies your kubeconfig to a private temp file before running
`kubelogin convert-kubeconfig`, so your original `~/.kube/config` is never
mutated. The temp file is deleted after the per-cluster scan completes.

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
