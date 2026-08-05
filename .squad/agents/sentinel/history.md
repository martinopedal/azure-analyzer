# Project Context

- **Owner:** martinopedal
- **Project:** azure-analyzer - Security Analyst & Recommendation Engine
- **Stack:** PowerShell, Pester, JSON, Security Scanners (Gitleaks, Trivy, Zizmor, Scorecard, Maester)
- **Created:** 2026-04-15

## Core Context

- **Security Invariants:** All outbound calls HTTPS-only. Host allow-list enforced for clones. Output sanitized via Remove-Credentials. 300s process execution timeout.
- **Pester & StrictMode:** Under Set-StrictMode -Version Latest, accessing non-existent properties on PSCustomObject or Hashtable throws PropertyNotFoundException. Always stamp expected fields (FindingKey, Suppressed, SuppressionReason) across all code paths.
- **Pester 5 Lifecycle Rules:** All lifecycle blocks (BeforeAll, AfterEach, etc.) MUST be inside Describe blocks - never at script root.
- **Test Isolation:** Reset $LASTEXITCODE in inally or AfterAll when testing non-zero exits to avoid leaking into downstream tests.

## Recent History

### 2026-05-13 - v1.7.2 Validation Audit
- Exercised 5 execution modes (subscription, tenant, repository, ADO, direct wrapper). Verified tool execution produces real esults.json + ntities.json with Schema 3.1.
- Scanned 44 fake-success patterns (0 matches). Direct wrapper invocation verified.
- Added LiveTool.StateIsolation.Tests.ps1 regression guard.

### 2026-08-05 - Native False-Positive Suppression List (#1229)
- **Suppression Key:** SHA-256 over source|rule|entity, first 16 hex chars, lowercased and trimmed. FindingRow.Id was rejected because 37 normalizers fallback to random GUIDs.
- **Marked, Not Dropped:** Suppressed findings remain in esults.json. Only severity counts and default report views exclude them, showing a visible suppressed count.
- **StrictMode Fix:** Fixed production bug at Invoke-AzureAnalyzer.ps1:1633 where correlator findings block omitted FindingKey/Suppressed/SuppressionReason, throwing PropertyNotFoundException under Set-StrictMode -Version Latest.
- **Files Shipped:** modules/shared/Suppression.ps1 (356 lines), 	ests/shared/Suppression.Tests.ps1 (26 tests), docs/consumer/suppression-list.md. PR #1251 merged at 4704a3c. Issue #1229 closed. Credited @haflidif in CHANGELOG.

### 2026-08-05 - Team Update
- Windows CI restored on GitHub-hosted runners (PR #1250 / #1173).
- Native false-positive suppression list shipped (PR #1251 / #1229).
- Backlog of 48 tool-pin PRs deduped down to 16 keepers.