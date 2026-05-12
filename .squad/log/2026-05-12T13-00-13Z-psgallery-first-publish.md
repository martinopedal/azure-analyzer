# Session: AzureAnalyzer — first PSGallery publish (v1.4.5)

**Date:** 2026-05-12  
**Milestone:** 🎉 AzureAnalyzer is now distributable via `Install-Module` from PSGallery  
**Issue closed:** [#963](https://github.com/martinopedal/azure-analyzer/issues/963)  

## Context

For 18 months, AzureAnalyzer shipped only as a clone-and-import module. Pre-v1.4.5 workflow:

```powershell
git clone https://github.com/martinopedal/azure-analyzer
Import-Module ./AzureAnalyzer
```

Barrier: manifest (`.psd1`) lacked PSGallery metadata (real GUID, Tags, Uris, ReleaseNotes). Issue #963 tracked PSGallery readiness, spawning 3 PRs:

1. **PR #1047** (Sage) — PSGallery research brief + design
2. **PR #1049** (Forge) — manifest rotation (new GUID), README External Tools, ci.yml test, PERMISSIONS section
3. **PR #1051** (Forge) — fix `release.yml` GPG validator (blockers from PR #1049 omission)

## Outcome

**v1.4.5 published 2026-05-12 12:55:49 UTC.** Users can now:

```powershell
Install-Module -Name AzureAnalyzer -Repository PSGallery
Import-Module AzureAnalyzer
Invoke-AzureAnalyzer -TenantId '...'
```

## What PSGallery distribution unlocks

- ✅ One-command install (no git clone, no path navigation)
- ✅ Automatic updates via `Update-Module AzureAnalyzer`
- ✅ Discover-ability in `Find-Module` (search term "Azure" + metadata)
- ✅ Cross-platform compatibility (PowerShell 5.1+, Windows/macOS/Linux)
- ✅ Corporate distribution (air-gapped installs via local repository mirrors)

## Root cause of first-publish failure

PR #1049 ("PSGallery publishing readiness") shipped four closure items but omitted the release.yml validator fix:

```
release.yml:
  Validate annotated + signed tag:
    if: tag.objectType == 'tag' && has_gpg_signature
```

release-please ships **lightweight tags** (object type `commit`, no PGP signature), so the gate failed deterministically. Validator lived in the codebase despite Sage's Path A brief calling it out as the required change. First real publish tested the readiness, not CI.

## Recovery

Applied **Option A** (safest, idempotent):

1. Delete broken release + tag
2. Merge PR #1051 fix to main
3. Re-create tag at fixed HEAD
4. Re-run release.yml from fixed validator

Outcome: run [25735618882](https://github.com/martinopedal/azure-analyzer/actions/runs/25735618882) green end-to-end. PSGallery smoke test passed (`Find-Module`, `Save-Module`, manifest version assertion).

## Learnings

- **Readiness ≠ CI passing.** Green tests on a "readiness PR" are necessary but not sufficient. The readiness is only proven by the next real publish.
- **release-please ships lightweight tags forever.** No configuration option. Either drop the annotated/signed requirement, or add app-level GPG signing. PSGallery does not require GPG, so dropping the requirement is correct.
- **Walk the source brief vs the actual diff.** PR #1049 closed 3/4 work items but left the validator in place despite Sage's brief explicitly listing it as the fix needed. Lesson: use a per-item checklist during PR review to catch omissions.

## Coordinator actions

- Issue #963 commented with PSGallery verification details and run links
- Auto-merge enabled on PR #1052 (v1.4.6 follow-up, cut by release-please from #1051 merge)
- Branch protections remain: linear history, no force-push, enforce_admins=true, 0 required reviewers
