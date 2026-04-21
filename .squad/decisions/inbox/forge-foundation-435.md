## forge-foundation-435

### Summary
Implemented Phase 0 foundation for issue #435 with additive schema updates, report architecture picker, report manifest writer, verification stubs with one-step auto-upgrade, normalizer edge-collector contract wiring, synthetic fixture generator, CI Pester count gate, sanitization parity hardening, and required README/CHANGELOG updates.

### Files changed
- `.github/workflows/ci.yml`
- `CHANGELOG.md`
- `Invoke-AzureAnalyzer.ps1`
- `README.md`
- `modules/shared/ReportArchitecture.ps1`
- `modules/shared/ReportManifest.ps1`
- `modules/shared/ReportVerification.ps1`
- `modules/shared/Sanitize.ps1`
- `modules/shared/Schema.ps1`
- `tests/fixtures/Generate-SyntheticFixture.ps1`
- `tests/fixtures/SyntheticFixture.Tests.ps1`
- `tests/shared/DualReadRegression.Tests.ps1`
- `tests/shared/EdgeCollectorContract.Tests.ps1`
- `tests/shared/ReportArchitecture.Tests.ps1`
- `tests/shared/ReportManifest.Tests.ps1`
- `tests/shared/ReportVerification.Tests.ps1`
- `tests/shared/Sanitize.Tests.ps1`
- `tests/shared/Schema.Edges.Tests.ps1`
- `tests/shared/Schema.Tests.ps1`

### Test count delta
- Baseline before changes: 1523 total (1518 passed, 5 skipped)
- After changes: 1543 total (1538 passed, 5 skipped)
- Delta: +20 total tests, +20 passed, 0 new failures

### PR
- Draft PR: https://github.com/martinopedal/azure-analyzer/pull/445
