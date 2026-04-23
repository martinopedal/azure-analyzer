## Closes
<!-- REQUIRED. Use 'Closes #N' or 'Fixes #N' to auto-close the linked issue on merge.
     If this PR does not resolve a tracked issue, write 'N/A (no tracked issue, type=<docs|chore|refactor|ci>)'.
     Reviewers: do not merge without this section filled in. -->
Closes #

## Summary
<!-- What changed and why. Keep it focused. -->

## Test results
<!-- Paste relevant Pester / CI output, or note 'N/A (docs only)'. Pester baseline (≥1637 total, ≥1602 passed) must be preserved or extended. -->

## Verification checklist
- [ ] No em dashes in any new prose
- [ ] All output written to disk passes through `Remove-Credentials`
- [ ] Docs updated (README / CHANGELOG / PERMISSIONS / docs/) per `.github/copilot-instructions.md`
- [ ] Pester baseline preserved (`Invoke-Pester -Path .\tests -CI` green)
- [ ] AI-assisted work reviewed for accuracy
