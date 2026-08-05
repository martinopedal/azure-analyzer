# Interactive triage report

Pass `-InteractiveReport` to turn the static HTML output into an in-browser triage
surface where reviewers can mark findings as false positives, filter the table, and
export a decision list that feeds directly into the suppression pipeline.

```powershell
Invoke-AzureAnalyzer -SubscriptionId "<subscription-id>" -InteractiveReport
```

Or generate from an existing results file:

```powershell
.\New-HtmlReport.ps1 -InputPath output\results.json -OutputPath output\report-interactive.html -Interactive
```

## What the interactive layer adds

The report is a single self-contained HTML file. No server. No build step. Open it in
any modern browser, including air-gapped environments.

### Mark false positive

Every row has a **Mark FP** button. Click it to mark a finding as a false positive.
The row is dimmed; the button label flips to **Unmark FP**. Marks are written to
`localStorage` keyed by `aa-triage-v1-{pathname}`, so they survive a page reload
and persist for the lifetime of the local browser profile.

### FP filter

Three buttons in the findings toolbar control which rows are visible:

| Button | Behaviour |
|---|---|
| All | Show all findings regardless of FP status (default) |
| Hide FP | Hide rows marked as false positive |
| Only FP | Show only rows marked as false positive |

The filter composes with the existing severity, tool, subscription, and search filters.

### Live severity counts

The severity count strip in the header adjusts as you mark rows. Each count shows the
adjusted number. Where rows have been marked, the original count appears in parentheses
so the delta is always visible.

### Export suppression JSON

**Export suppression JSON** downloads a `suppression.json` file compatible with
`Import-SuppressionList` (the `-SuppressionFile` parameter). Each marked finding
becomes one entry:

```json
{
  "schemaVersion": "1.0",
  "suppressions": [
    {
      "key": "a1b2c3d4e5f60718",
      "reason": "Marked false-positive in interactive report (2026-08-05T14:00:52.662Z)",
      "source": "azqr",
      "title": "aks-004"
    }
  ]
}
```

The `key` field is the stable `FindingKey` (SHA-256 over `source|rule|entity`, first
16 hex chars, computed by `Get-FindingKey` in `modules/shared/Suppression.ps1`). The
`source` and `title` fields are informational only; `Import-SuppressionList` resolves
by `key` when it is present.

The `reason` field includes a UTC timestamp so the suppression file is auditable
without out-of-band context.

### Round trip to a suppression file

The headline capability: a reviewer triages findings in the browser, clicks
**Export suppression JSON**, and hands the file to the scan operator. The operator
drops it next to the scan and re-runs:

```powershell
Invoke-AzureAnalyzer -SubscriptionId "<subscription-id>" -SuppressionFile .\suppression.json
```

No hand-editing. The exported file is valid input to `Import-SuppressionList`
immediately. Findings marked in the browser disappear from severity counts and report
views on every subsequent scan.

### Export CSV (with FP)

**Export CSV (with FP)** downloads the standard findings CSV with a `false_positive`
column appended to every row (`true` or `false`). Only rows currently visible (not
hidden by other filters) are included.

### Import suppression JSON

**Import suppression JSON** restores marks from a `suppression.json` file. This is how
marks are transferred to a second machine: export from machine A, import on machine B.
The file must have a `suppressions` array with entries carrying a `key` field. Entries
without a matching row in the current report are silently ignored.

## Byte-identical static output

When `-Interactive` / `-InteractiveReport` is not set, `New-HtmlReport.ps1` produces
output that is byte-identical to the existing static renderer. The
`tests/samples/SampleDrift.Tests.ps1` test enforces this. Do not regenerate the
committed sample to paper over drift.

## Identity: FindingKey

The client-side identity for marking is `FindingKey`, a 16-hex-char SHA-256 digest
over `source|rule|entity` (lowercase, trimmed), computed by `Get-FindingKey` in
`modules/shared/Suppression.ps1`. It is the same key the suppression list uses, so
marks exported from the browser and suppression applied at scan time are always
consistent. No second identity scheme exists in the interactive layer.

## Design note: issue 1231

Issue 1231 ("shrink interactive report payload via stable hashed finding id") is the
direct follow-up. The current implementation emits finding identity as `data-fk`
per row, which is ready for the deduplication pass 1231 will add. No redesign is
needed; 1231 is a tightening of the payload format, not a rewrite of the triage layer.