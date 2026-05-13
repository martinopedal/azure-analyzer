# Workflow — simplification directive (effective immediately)

**Timestamp:** 2026-05-13T18:00:23Z  
**Stream:** Workflow  
**Status:** approved  
**Authority:** martinopedal

## Summary
Workflow simplification effective immediately for v1.7.0 and beyond:

### Dropped (no longer required)
- Multi-agent dispatch for routine solo work
- 3-model gates per PR
- Comment Triage Loop on every Copilot thread
- Reviewer Rejection Lockout for routine work

### Kept (non-negotiable)
- CI green as merge gate
- Fail-first regression tests for every bug fix
- Security invariants (Remove-Credentials, Schema, HTTPS-only, host allow-list, 300s timeout)
- Pester baseline enforcement

### Duck only when stuck or before high-blast-radius changes
- Swift haiku (not Opus extra-high on everything)
- Brief, focused reasoning
- Document blockers in PR sticky comment + mirror squad issue

### Bug detection preference
- Prefer fail-first regression tests over analytical critique loops
- Tests are durable, critiques are ephemeral
- Every bug fix MUST ship with fail-first proof (test that fails before fix, passes after)

This simplification reduces context overhead and accelerates routine iteration while maintaining safety and quality gates.
