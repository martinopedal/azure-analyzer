# Consumer documentation

All advanced consumer docs live here. The root `README.md` is your starting point.

- [tool-catalog.md](tool-catalog.md) - Every tool azure-analyzer can run, what it covers, and what scope it targets. Generated from `tools/tool-manifest.json`.
- [permissions/](permissions/README.md) - Per-tool permission detail. The root [`PERMISSIONS.md`](../../PERMISSIONS.md) is the short summary; per-tool pages live here.
- [continuous-control.md](continuous-control.md) - Continuous control monitoring patterns and integration guidance.
- [ai-triage.md](ai-triage.md) - AI-assisted finding triage workflow and prompt design.
- [gitleaks-pattern-tuning.md](gitleaks-pattern-tuning.md) - Tuning gitleaks rule patterns to cut false positives.
- [k8s-auth.md](k8s-auth.md) - Targeting Kubernetes wrappers (kubescape, falco, kube-bench) with explicit `-KubeconfigPath` / `-KubeContext` / per-tool namespace params.
- [permissions/appinsights.md](permissions/appinsights.md) - Application Insights performance KQL signals (slow requests, dependency failures, exception clusters).
- [permissions/loadtesting.md](permissions/loadtesting.md) - Azure Load Testing failed-run and regression permissions and usage.
- [permissions/aks-rightsizing.md](permissions/aks-rightsizing.md) - AKS Container Insights rightsizing permissions and usage.
- [sinks/log-analytics.md](sinks/log-analytics.md) - Streaming azure-analyzer findings into Azure Log Analytics.
- Cost and performance tools are listed in [tool-catalog.md](tool-catalog.md); permission details are in [permissions/](permissions/README.md).
