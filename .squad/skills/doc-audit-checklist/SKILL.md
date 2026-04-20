# Skill: Doc Audit Checklist (consumer-vs-contributor split)

**Purpose:** Reusable checklist for auditing a repo's docs surface before a consumer-first restructure. Distilled from the 2026-04-20 azure-analyzer doc-restructure research.

## When to use

- User asks "make docs consumer-first" / "hide contributor material" / "restructure docs".
- Before any large doc move, to avoid surprises with manifest paths, link redirects, or workflow path filters.

## Checklist

1. **Catalogue every root-level `.md`** with: filename, LOC, audience (consumer / contributor / mixed), and whether it's GitHub-recognised (LICENSE, README, SECURITY, CONTRIBUTING, CODE_OF_CONDUCT, SUPPORT must stay at root).
2. **Catalogue every file under `docs/`** with the same audience tag. Look for proposal/RFC dirs and treat them as contributor.
3. **Identify the consumable artefact.** For PowerShell modules: the `.psd1` and what it dot-sources. For npm/pip: the package entry point. **Never move files referenced by the manifest without a same-PR manifest update.**
4. **Walk the consumer journey end-to-end** (discover → install → invoke → interpret → operate at scale). Note line numbers in README where each step lands. If install/prereqs are below operational examples, that's friction.
5. **Identify build artefacts polluting the root** (`*.log`, `testResults.xml`, `output*/`). They belong in `.gitignore`, not the listing.
6. **Identify renderer/template assets at the root** (`*.html`, `*.css`). They belong in `templates/` or `assets/`. Note all path constants that reference them.
7. **Inbound link audit.** Grep for the docs you plan to move across: README, CHANGELOG, `.github/workflows/**`, `.copilot/`, `.squad/`, CODEOWNERS. Each hit is a redirect-stub or in-place update item.
8. **Workflow path-filter audit.** `docs-check.yml`, `ci.yml`, release workflows often `paths:` on `docs/**`. Moves can silently disable them.
9. **`.gitattributes` audit.** Look for `export-ignore`. Archive consumers may already be partially shielded - focus the restructure on the github.com rendered surface.
10. **Distribution-channel audit.** Is the package on PSGallery / npm / PyPI? If not, document the actual install path (clone-and-import) prominently. If yes, the README install section is the highest-leverage edit.

## Decomposition pattern (5-PR sequence)

When the audit produces a doc move, decompose into:

- PR-1: chore - root cleanup (gitignore artefacts, move template assets). No doc semantics change.
- PR-2: docs - file moves + redirect stubs + index pages. README untouched (anchors still work via stubs).
- PR-3: docs - extract sections from README into the new doc pages. README still works because content is duplicated, not removed.
- PR-4: docs - README rewrite (consumer-first, references the now-extracted pages). Length target: shrink by ≥ 50%.
- PR-5: chore - sweep stale inbound link references + CHANGELOG announcement.

## Anti-patterns to avoid

- Moving manifest-referenced source files in the same PR as a docs reshuffle. Two unrelated breakages compound debug time.
- Deleting old doc paths without redirect stubs. External bookmarks and PR/issue history will 404.
- Touching the manifest GUID without flagging it as a coordinated rotation.
- Promising a PSGallery install in README before the manifest has `PrivateData.PSData` populated.

## Source

- `.squad/decisions/inbox/lead-restructure-research-2026-04-20T12-17-33Z.md` (full worked example).
