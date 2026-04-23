# samples/ Provenance
Regenerate: `pwsh .\scripts\Regenerate-Samples.ps1`
| File | Generator | Source |
|------|-----------|--------|
| sample-findings-v2.json | Regenerate-Samples.ps1 | tests/fixtures/synthetic-multi-tool.json |
| sample-entities.json | Regenerate-Samples.ps1 | (empty v3 store) |
| sample-report-v2-mockup.html | New-HtmlReport.ps1 | sample-findings-v2.json |
| sample-report-v2-mockup.md | New-MdReport.ps1 | sample-findings-v2.json |
