# kube-bench Schema 2.2 ETL mapping decision

Date: 2026-04-21
Issue: #359

## Decision

- Treat kube-bench findings as Security pillar findings.
- Emit Frameworks as CIS Kubernetes Benchmark plus CIS-AKS for AKS managedClusters.
- Set Impact from severity (High/Critical => High, Medium => Medium, Low/Info => Low).
- Emit BaselineTags as ControlId and Status.
- Emit DeepLinkUrl from LearnMoreUrl.
- Emit RemediationSnippets as one snippet with language inferred as yaml when remediation looks like Kubernetes manifest, otherwise bash.
- Emit ToolVersion from the kube-bench image tag passed to the wrapper.
- Emit EntityRefs with cluster ResourceId and optional node reference when present in kube-bench result rows.

## Rationale

These mappings satisfy the locked Schema 2.2 additive contract while preserving existing dedup behavior and aligning with Kubescape ETL patterns.
