# Burke - agent history

## 2026-04-19 - Issue #231 (Performance Efficiency pillar) split

**Verdict:** 🟡 split L → 3× S/M children (#237 App Insights, #238 Load Testing, #239 AKS rightsizing). #231 → tracking issue.

**Codebase facts confirmed (re-use next time):**
- Wrappers live in `modules/Invoke-*.ps1` - there is **no `modules/wrappers/`** subdir despite many issue specs claiming so. Always correct the path in child issues.
- **No KQL consumer exists yet.** `Invoke-SentinelCoverage.ps1` only uses Sentinel REST list APIs (alertRules / dataConnectors / savedSearches), never `/v1/.../query`. First wrapper to need KQL must ship `modules/shared/KqlQuery.ps1` (LA + App Insights).
- **AKS cluster discovery** is duplicated logic-in-waiting: today only `Invoke-Kubescape.ps1` does the ARG `Microsoft.ContainerService/managedClusters` query. Anything else AKS-shaped (#234 runtime cost, #239 rightsizing, future) should lift it into `modules/shared/AksDiscovery.ps1`.
- **Manifest has no `category` field.** `report.color`, `report.label`, `report.phase` are the only report-side keys. The "category=Performance" wording in coverage issues refers to the per-finding `Category` string in `New-FindingRow`, which is free-text and unvalidated - no schema change needed to use a new value.
- **FindingRow has no `metrics{}` blob.** p95 latency, regression delta, utilization-% all go in `Detail` as prose for v1. A structured `Metrics` field is a separate, larger schema PR - do not block perf wrappers on it.
- **MCP servers are author-time only.** Searched whole tree for `azure-mcp*` → only one aspirational doc hit. Wrappers always use `Invoke-AzRestMethod` + `Invoke-WithRetry` direct.
- **Severity enum is fixed at five** (Critical/High/Medium/Low/Info) - sufficient for regression bands.

**Cross-cutting flagged:** #239 (rightsizing) overlaps with #234 (AKS runtime cost) on Container Insights node-utilization. Resolution proposed in #239: Burke owns pod-level HPA/VPA, #234 owns node-level/Karpenter; node-utilization finding either moves to #234 or is dedup'd via `Source` field.

**Coordination needed:** App Insights child (#237) must land first - it ships the shared KQL helper that #239 depends on.
