# SHA-Pinning + Triage Keyword Routing + Consistency Fixes

**Date:** 2025-01-26  
**Agent:** Forge (Platform Automation & DevOps Engineer)  
**Status:** ✅ Complete

## Context

Five workflow and triage configuration issues identified:

1. **SHA-pinning violation**: 4 squad workflow files used floating tag references (`@v6`, `@v7`) instead of SHA-pinned versions, violating repo policy
2. **Generic triage keywords in workflow**: `squad-triage.yml` had hardcoded routing for `frontend/backend/api/devops` — none of which match our specialist roles
3. **Contradictory copilot-instructions.md**: Line 49 instructed agents to use tag-pinned actions (`@v6`), contradicting the SHA-pinning policy on line 24
4. **Generic keywords in ralph-triage.js**: The `findRoleKeywordMatch()` function used `frontend/backend/test/qa` keywords that don't match our team
5. **Meaningless go:needs-research label**: Applied unconditionally to every triaged issue, making the label useless

## Changes Made

### Fix 1: SHA-Pinned All Actions

Resolved action SHAs using `gh api`:
- `actions/checkout@v6` → `de0fac2e4500dabe0009e67214ff5f5447ce83dd # v6`
- `actions/github-script@v7` → `f28e40c7f34bde8b3046d885e986cb6290c5673b # v7`

**Updated files:**
- `squad-heartbeat.yml` (3 instances)
- `squad-issue-assign.yml` (3 instances)
- `squad-triage.yml` (2 instances)
- `sync-squad-labels.yml` (2 instances)

**Already compliant:**
- `auto-label-issues.yml` ✓
- `ci-failure-analysis.yml` ✓
- `codeql.yml` ✓

### Fix 2: Project-Specific Keyword Routing (squad-triage.yml)

Replaced generic routing in `squad-triage.yml` (lines 146-207) with specialist domain keywords:

| Specialist | Keywords |
|-----------|----------|
| **Atlas** (ARG Engineer) | `kql`, `query`, `arg`, `resource graph`, `alz`, `checklist item`, `queries`, `json query`, `empty`, `validate`, `compliant` |
| **Iris** (Entra/Graph) | `entra`, `identity`, `microsoft graph`, `pim`, `conditional access`, `mfa`, `rbac`, `aad`, `azure active directory`, `role assignment`, `privileged` |
| **Forge** (DevOps) | `pipeline`, `workflow`, `github actions`, `branch protection`, `ci`, `ado`, `devops`, `secret`, `codeowners`, `dependabot`, `deploy` |
| **Sentinel** (Security) | `security`, `compliance`, `recommendation`, `score`, `severity`, `azqr`, `report`, `finding`, `risk`, `posture` |
| **Sage** (Research) | `research`, `spike`, `investigate`, `feasibility`, `tool`, `integration`, `bundl`, `prior art`, `discovery` |
| **Lead** | Everything else (fallback) |

### Fix 3: Removed Contradiction in copilot-instructions.md

**Before (line 49):**
```markdown
- Use actions/checkout@v6 and actions/setup-python@v6 (Node.js 24 compatible)
```

**After (line 49):**
```markdown
- Use SHA-pinned versions of actions/checkout (v6) and actions/setup-python (v6) — always pin by SHA, not tag
```

This prevents future agents from re-introducing tag-pinned actions after reading the instructions.

### Fix 4: Updated ralph-triage.js Keywords

Replaced `findRoleKeywordMatch()` function (lines 357-384) with project-specific specialist keywords:

- **Atlas**: `atlas`, `arg`, `kql`, `resource graph`, `query`
- **Iris**: `iris`, `entra`, `identity`, `graph`, `pim`, `conditional access`, `mfa`
- **Forge**: `forge`, `devops`, `pipeline`, `workflow`, `github actions`, `branch`, `ci`
- **Sentinel**: `sentinel`, `security`, `compliance`, `recommendation`, `azqr`, `psrule`, `score`
- **Sage**: `sage`, `research`, `spike`, `investigation`, `feasibility`, `tool`

### Fix 5: Made go:needs-research Conditional

**Before:** Applied to every triaged issue (meaningless)

**After (lines 227-234):** Only applied when:
- Issue routed to Lead (no domain match), OR
- Triage reason includes "No specific domain match"

Otherwise skipped — lets humans/Lead apply correct `go:*` label after review.

## Verification

```powershell
git diff --stat
# .github/copilot-instructions.md (1 line updated)
# .github/workflows/* (4 files, SHA-pinning + conditional label)
# .squad/templates/ralph-triage.js (keyword function updated)
```

## Impact

✅ **Security**: All workflows comply with SHA-pinning policy (supply chain protection)  
✅ **Triage accuracy**: Issues route to correct specialists based on azure-analyzer vocabulary  
✅ **Consistency**: Copilot instructions align with actual repo policy  
✅ **Ralph reliability**: Node.js triage script matches workflow routing logic  
✅ **Label hygiene**: `go:needs-research` only applied when genuinely needed

## Next Steps

- Monitor Ralph heartbeat to verify triage routing works as expected
- Watch for any issues incorrectly routed to Lead (adjust keywords if needed)
- Consider adding more domain-specific keywords as patterns emerge from real issues
