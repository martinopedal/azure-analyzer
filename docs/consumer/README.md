# Consumer documentation

All advanced consumer docs live here. The root `README.md` is your starting point.

- [tool-catalog.md](tool-catalog.md) - Every tool azure-analyzer can run, what it covers, and what scope it targets. Generated from `tools/tool-manifest.json`.
- [permissions/](permissions/README.md) - Per-tool permission detail. The root [`PERMISSIONS.md`](../../PERMISSIONS.md) is the short summary; per-tool pages live here.
- [continuous-control.md](continuous-control.md) - Continuous control monitoring patterns and integration guidance.
- [ai-triage.md](ai-triage.md) - AI-assisted finding triage workflow and prompt design.
- [gitleaks-pattern-tuning.md](gitleaks-pattern-tuning.md) - Tuning gitleaks rule patterns to cut false positives.
- [k8s-auth.md](k8s-auth.md) - Targeting Kubernetes wrappers (kubescape, falco, kube-bench) with explicit `-KubeconfigPath` / `-KubeContext` / per-tool namespace params.
- [sinks/log-analytics.md](sinks/log-analytics.md) - Streaming azure-analyzer findings into Azure Log Analytics.
- Cost and FinOps tools are listed in [tool-catalog.md](tool-catalog.md); permission details are in [permissions/](permissions/README.md).
