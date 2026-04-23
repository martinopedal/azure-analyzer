# Releasing azure-analyzer

This repository uses conventional commits + release-please + GitHub Releases + PSGallery publishing.

## Version source of truth

- The canonical module version is `ModuleVersion` in `/AzureAnalyzer.psd1`.
- Git tags must be `v<major>.<minor>.<patch>` and match `ModuleVersion`.
- `release-please` updates `AzureAnalyzer.psd1` and `CHANGELOG.md` in the release PR.

## Conventional commit contract

Commit type to semver mapping:

- `feat!` or `BREAKING CHANGE:` -> **major**
- `feat` -> **minor**
- `fix` / `perf` -> **patch**
- `docs` / `chore` / `ci` / `test` / `refactor` -> release notes only (no direct bump by type)

## Workflow phases

`/.github/workflows/release.yml` contains two phases:

1. **Main push phase** (`push` to `main`): `release-please` manifest mode opens/updates a release PR.
2. **Tag phase** (`push` tag `v*.*.*`): validates signed annotated tag, runs full Pester gate, builds release archive, generates SBOM and checksums, creates GitHub Release, performs PSGallery dry run + publish + smoke test.

## Release artifacts

Each tag release uploads:

- `AzureAnalyzer-v<version>.zip`
- `sbom.json` (CycloneDX)
- `SHA256SUMS.txt`

## PSGallery publish flow

The workflow uses `PSGALLERY_API_KEY` and executes:

1. `Publish-Module -WhatIf` dry run
2. real `Publish-Module`
3. smoke validation with `Find-Module` + `Save-Module`

## Breaking change policy

Treat the following as **major-version triggers**:

- removed or renamed public surface
- removed schema fields or enum values

Required policy:

- keep a deprecation window of at least one minor release
- emit `Write-FindingError` with `Category = Deprecated` during deprecation windows
- gate removals behind the `-AllowDeprecated` compatibility contract when introduced

## Rollback policy

For bad publishes:

- if within PSGallery unlist window: run `Unpublish-Module`
- otherwise ship the next patch (`x.y.z+1`) and document known-bad versions in this document
- remove bad GitHub release/tag with `gh release delete` and `git push --delete origin <tag>`
