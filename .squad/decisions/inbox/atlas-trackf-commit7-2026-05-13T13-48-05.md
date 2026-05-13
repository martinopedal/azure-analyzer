# Track F Commit 7 - Auditor Profile Wiring + Nav Chip

**Date**: 2026-05-13 13:48:05  
**Author**: Atlas (Squad Core Dev)  
**Context**: Track F (issue #506) - Auditor-driven report builder

## Decision

Wired Build-AuditorReport orchestrator into Invoke-AzureAnalyzer.ps1 via new `-Profile` parameter and added "Audit view" nav chip to New-HtmlReport.ps1.

## Implementation Details

### 1. Build-AuditorReport Orchestrator (lines 44-163)

Replaced NotImplementedException stub with full orchestration logic:

- Calls Resolve-AuditorContext to load inputs (results.json, entities.json, report-manifest.json, optional triage.json)
- Calls Get-AuditorExecutiveSummary for severity counts + framework coverage
- Calls Get-AuditorControlDomainSections to group findings by CIS/NIST/MCSB/ISO27001 control IDs
- Calls Get-AuditorAttackPathSection (Track A consumer) with -Tier parameter
- Calls Get-AuditorResilienceSection (Track B consumer) with -Tier parameter
- Calls Get-AuditorPolicyCoverageSection (Track C consumer) with -Tier parameter
- Calls Get-AuditorTriageAnnotations (Track E consumer) to join optional triage verdicts
- Calls Get-AuditorRemediationAppendix to group by exact Remediation text
- Calls Get-AuditorEvidenceExport to write CSV/JSON/XLSX with Remove-Credentials
- Calls Write-AuditorRenderTier to produce audit-report.html + audit-report.md
- Returns hashtable with HtmlPath, MdPath, EvidencePath, Manifest, SectionErrors when -PassThru specified

**Defensive degradation**: Each sub-function call wrapped in try/catch. Section errors logged to SectionErrors array but do not stop execution (declared degradation contract). Write-AuditorRenderTier failure is caught but function continues to return paths.

**Pipeline fix**: Assigned Write-AuditorRenderTier result to `` to prevent hashtable leakage into pipeline (function was returning both Write-AuditorRenderTier's hashtable AND Build-AuditorReport's hashtable as Object[]).

### 2. Invoke-AzureAnalyzer.ps1 Wiring

**Parameter addition** (lines 183-184):
- Added `-Profile` parameter with ValidateSet('Default','Auditor'), default 'Default'
- Placed after existing `-FixturePath` parameter in param block

**Dot-sourcing** (line 197):
- Added 'AuditorReportBuilder' to shared-module dot-source loop

**Invocation** (lines 2021-2045):
- After existing New-HtmlReport.ps1 and New-MdReport.ps1 calls
- Conditional on `C:\Users\martinopedal\OneDrive - Microsoft\Documents\PowerShell\Microsoft.PowerShell_profile.ps1 -eq 'Auditor'`
- Checks for Build-AuditorReport availability (Get-Command)
- Passes InputPath (results.json), EntitiesPath (entities.json), ManifestPath (report-manifest.json), OutputDirectory, PassThru=True
- Conditionally passes TriagePath if `` variable set
- Logs section errors with Remove-Credentials
- Writes `[OK] Auditor report: <path>` and `[OK] Evidence export: <path>` on success
- Warns if Build-AuditorReport not available (defensive graceful skip)

### 3. New-HtmlReport.ps1 Nav Chip Injection

**Logic** (lines 707-713):
- Checks if audit-report.html exists in same directory as report.html output
- Sets `` to `"<a href='audit-report.html'>Audit view</a>"` if present, empty string otherwise
- **ASCII only** - no em-dashes, en-dashes, or arrow symbols (markdown-check.yml enforcement)

**Injection point** (line 849):
- Modified `<nav class='sub'>` line to append `` variable
- Chip appears after "Entities" link in sub-navigation row
- Reuses existing nav link styling (no new CSS required)

### 4. Orchestrator Tests (tests/orchestrator/InvokeAzureAnalyzer.Profile.Tests.ps1)

Created new test file with 3 tests:

**Test 1** (lines 18-57): "calls Build-AuditorReport and produces audit-report.html"
- Loads auditor-small fixture (results.json, entities.json, report-manifest.json)
- Calls Build-AuditorReport with -PassThru
- Asserts result is not null/empty
- Asserts HtmlPath and MdPath exist
- Asserts HTML content contains "Azure Analyzer Audit Report"
- **Lesson learned**: Cannot use `{  = Func } | Should -Not -Throw` - scriptblock assignment doesn't propagate to outer scope. Use direct assignment instead.

**Test 2** (lines 61-79): "injects Audit view nav chip when audit-report.html exists"
- Creates audit-report.html in output directory
- Calls New-HtmlReport.ps1
- Asserts report.html contains `href='audit-report.html'>Audit view</a>`

**Test 3** (lines 81-97): "does not inject nav chip when audit-report.html is missing"
- Does NOT create audit-report.html
- Calls New-HtmlReport.ps1
- Asserts report.html does NOT contain audit-report link

### Test Results

- AuditorReportBuilder.Tests.ps1: 24/24 tests pass (no regression)
- InvokeAzureAnalyzer.Profile.Tests.ps1: 3/3 tests pass
- **Cumulative total**: 27 tests (24 + 3)

## Alternatives Considered

**Alt 1**: Make -Profile a switch (-Auditor) instead of ValidateSet
- Rejected: Harder to extend with future profiles (e.g., -Profile 'ComplianceOfficer', -Profile 'Developer')

**Alt 2**: Always generate auditor report, toggle with -SkipAuditorReport
- Rejected: Default behavior should be lightweight (minimal output); auditor report is opt-in heavyweight output

**Alt 3**: Inject nav chip via JavaScript after page load
- Rejected: Requires audit-report.html presence check in JS; server-side check is simpler and works without JS

**Alt 4**: Use em-dash or arrow in nav chip text (e.g., "Audit view →")
- Rejected: Violates ASCII-only repo invariant (markdown-check.yml)

## Consequences

**Positive**:
- Auditor profile now fully wired and end-to-end testable
- Users can run `Invoke-AzureAnalyzer.ps1 -Profile Auditor` to get audit-report.html + evidence export
- Nav chip provides discoverability when auditor report exists
- Defensive degradation allows partial success even if sub-functions fail

**Negative**:
- First orchestrator-touching commit triggers full Test/e2e matrix (~10-15 min CI run)
- -Profile parameter adds cognitive load to param block (though default 'Default' makes it opt-in)

**Next steps**:
- Commit 8: Get-AuditorDiffSection (delta vs. previous run)
- Commit 9: Final documentation update + close issue #506

## Files Modified

- `modules/shared/AuditorReportBuilder.ps1` (lines 44-163): Build-AuditorReport implementation
- `Invoke-AzureAnalyzer.ps1` (lines 183-184, 197, 2021-2045): -Profile parameter + wiring
- `New-HtmlReport.ps1` (lines 707-713, 849): Nav chip injection logic
- `tests/orchestrator/InvokeAzureAnalyzer.Profile.Tests.ps1` (new): 3 orchestrator tests

## References

- Issue #506 (Track F epic)
- Track F design doc: docs/design/track-f-auditor-redesign.md
- Lesson from Commit 4: Always verify history.md staged in docs commit
- Lesson from Commit 5: Cannot use inline if expression in Add-Member -Value parameter
- Lesson from Commit 7: Pester scriptblock assignment doesn't propagate to outer scope
