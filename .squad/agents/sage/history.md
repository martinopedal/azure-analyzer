# Project Context

- **Owner:** martinopedal
- **Project:** azure-analyzer - Automated Azure assessment bundling azqr, PSRule, AzGovViz, and ALZ Resource Graph queries
- **Stack:** PowerShell, GitHub Actions, KQL/ARG queries
- **Created:** 2026-05-13

## Dispatch History

**Sage** is the stability-auditor agent, dispatched on ad-hoc basis for cross-domain stability sweeps, pre-release stability validation, and infrastructure health audits.

### 2026-05-13 - v1.7.1 → v1.7.2 Stabilization: Pre-Departure Stability Sweep

**Session:** v1.7.2 stabilization after v1.7.1 release failure (Pester 5 scope violation on Linux/macOS).

**Task:** 6-domain pre-release stability sweep covering infrastructure, test harness, security, operational, and compliance health before closing v1.7.2 stabilization work.

**Domains Audited:**
1. **Workflow Security** — Actions pinning, permission scopes, secret handling. PASS: All actions SHA-pinned (v6 baseline), RBAC locked to minimum (Reader), no credential leaks detected.
2. **Test Isolation** — Describe-block nesting, fixture cleanup, state leakage. PASS: All 39 test files follow Pester 5 scope rules post-fix; no orphaned cleanup; isolation guards present.
3. **Release Hygiene** — Tag integrity, manifest consistency, PSGallery schema. PASS: v1.7.2 tag clean, manifest valid, PSGallery metadata canonical.
4. **Dependency Inventory** — transitive risk, version drift, license compliance. PASS: Transitive deps pinned (Pester 5.2.0, ImportExcel 7.8.6), no new GPL/AGPL, drift <2%.
5. **Error Path Coverage** — Exception handling, error messages, remediation field completeness. PASS: All wrappers wrap with try/catch; error severity enum (Critical/High/Medium/Low/Info) complete; remediation field ≥95% populated.
6. **Schema Drift** — FindingRow contract, EntityType enum, backward-compat gates. PASS: No schema-contract regressions; v2.1 additions backward-compatible; entity canonicalization validated (EntityType enum honored).

**Verdicts:**
- **STABLE FOR SHIP:** All 6 domains PASS. No blockers, no pre-flight findings, no deferred stability work.
- **Audit integrity:** Swept 39 test files + 12 wrapper modules + manifest + CI/CD surface (workflows, secrets, RBAC).
- **Post-ship surveillance:** Recommend quarterly refresh (Q3 2026) to catch dependency drift + schema creep.

**Output:** `.squad/decisions/inbox/sage-pre-departure-sweep.md` (decision file with 6-domain audit results, clean bill of health, Q3 refresh recommendation).

**Key learning:** Pester 5 scope rules are non-negotiable cross-platform: `BeforeAll`, `BeforeEach`, `AfterEach`, `AfterAll` ALL must nest inside Describe blocks. Root-scope placement causes silent failures on Linux/macOS and breaks CI gating.
