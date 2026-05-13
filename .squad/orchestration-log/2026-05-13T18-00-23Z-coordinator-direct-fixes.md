# Coordinator — direct bug fixes (Sentinel PR #1110 pre-merge)

**Timestamp:** 2026-05-13T18:00:23Z  
**Stream:** Coordinator  
**PR:** #1110 (Sentinel)  
**Status:** merged  
**Commits:** [hashtable-containskey-antipattern] [remove-credentials-wrapping]

## Summary
Pre-merge bug fixes applied directly to Sentinel's PR #1110 before final merge:

1. **PSObject.Properties.Name antipattern** — Fixed iteration pattern against [hashtable] return type in AuditorDataFlow.Tests.ps1. Switched to .ContainsKey() for robust hashtable membership testing.

2. **RISK-3: Remove-Credentials wrapping** — Added Remove-Credentials wrapping at two critical sinks:
   - AuditorReportBuilder.ps1:898 (HTML report sink)
   - AuditorReportBuilder.ps1:915 (MD report sink)
   - Added AuditorParity Test 39 with fail-first regression proof

Both fixes completed and verified green before merge.
