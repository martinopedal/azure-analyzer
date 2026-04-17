# Project Context

- **Owner:** martinopedal
- **Project:** ALZ Additional Graph Queries — Security aggregation and unified recommendation engine
- **Stack:** PowerShell, JSON, azqr (Azure Quick Review), CSV/HTML report generation
- **Created:** 2026-04-14

## Notes

- **2024-12-19:** PII audit scheduled for future sprint (Scribe session tracking)

## Learnings

<!-- Append new learnings below. Each entry is something lasting about the project. -->
- **2026-04-17:** 3-model PR consensus is now formalized as Claude premium + GPT codex + Goldeneye prompt-bundle triage, with merged consensus/disputed findings and deterministic verdict precedence (`CHANGES_REQUESTED` beats `COMMENTED` beats `APPROVED`).
- **2026-04-17:** Reviewer Rejection Lockout is mechanically enforced in the PR review gate helper by rejecting any replacement owner equal to the PR author and always recording lockout + replacement in the consensus document.
- **2026-04-17:** PR review ingestion relies on GitHub Pull Request Reviews API (`/pulls/{n}/reviews`) plus line comments API (`/pulls/{n}/comments`) with paginated/slurped JSON parsing and retryable error handling for rate limits.
- **2026-04-18 (Issue #100):** Error sanitization audit — grep pattern that caught all unsanitized writes: `Exception\.Message|Error\.Message|\.Message` with manual review of each hit. Zero false positives from `Write-Verbose` or `Write-Warning` (console streams, not disk). Key boundary: wrap at error-capture time (in catch block), not at every write-site, to ensure consistency. Test fixtures for SAS URI, bearer token, connection string, and multi-secret scenarios validate disk-write paths. Pattern established: `Message = (Remove-Credentials $_.Exception.Message)` or `Message = "Context: $(Remove-Credentials $_.Exception.Message)"` for interpolated strings.
