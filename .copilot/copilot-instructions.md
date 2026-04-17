# Copilot Instructions - azure-analyzer

## Development Process

All code changes follow this pipeline:

1. **Build** - implement on a feature branch, run tests locally
2. **Review Gate** - 3-model code review (Opus 4.6 + Goldeneye + GPT-5.3-codex)
   - All 3 must APPROVE before merge
   - Parse-check all .ps1 files, verify no ?. syntax, check error handling
3. **Fix** - address all findings from reviewers
4. **Re-gate** - re-run review with the models that rejected, verify fixes
5. **Final Review Gate** - if re-gate passes, proceed. If not, loop back to Fix
6. **CI** - all GitHub Actions must pass (CodeQL, docs-check)
7. **Merge** - squash merge to main, delete feature branch

## Automated Review Ingestion

When a PR gets `CHANGES_REQUESTED`, or when Copilot/human review comments are added, the `pr-review-gate.yml` workflow triggers automatically. It ingests PR reviews/comments, builds a 3-model triage bundle (Claude premium + GPT codex + Goldeneye), writes the consensus plan to `.squad/decisions/inbox/`, and posts a PR summary comment with ownership and next actions. Reviewer Rejection Lockout is automatic, the rejected PR author agent is mechanically locked out from doing the revision in that gate cycle, and the consensus must name a different revision owner.

## Code Quality Rules

- PS 7.4+ only. No ?. null-conditional on variables
- $using: in ForEach-Object -Parallel must be copied to local vars before indexing
- All error paths must use Remove-Credentials for sanitization
- All CLI tool wrappers must check $LASTEXITCODE
- Use temp files for CLI JSON output, not stdout capture with 2>&1
- Every tool wrapper returns Status (Success/Failed/Skipped/PartialSuccess)
- Trivy: verify binary from official releases only (https://github.com/aquasecurity/trivy/releases)

## Documentation Rules

- Every PR that changes code must update README, CHANGELOG, PERMISSIONS.md as applicable
- Docs are rubber-ducked against actual code before merge
- No em dashes in any documentation
