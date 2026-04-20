# Skill: repo-link-sweep

Reusable workflow for safely relocating documentation in a multi-surface repo (root docs, `.squad/`, `.copilot/`, `.github/`, modules, tests) without breaking inbound links.

## When to use

- Splitting a flat `docs/` tree into nested categories (consumer/contributor/governance).
- Renaming any tier-1 doc (`README.md`, `CONTRIBUTING.md`, `AI_GOVERNANCE.md`, ...).
- Moving inline tables / sections into dedicated pages.

## Workflow

### 1. Move with history

For every file: `git mv <old> <new>`. Always. Do not copy + delete.

### 2. Stub at every old path (text-only)

GitHub's markdown sanitizer strips `<meta>` and `<script>`, so meta-refresh redirects do nothing. The stub must be plain markdown:

```
# Moved

This page has moved to [new-path](relative/path/to/new-path).

The old path is preserved as a stub through the next minor release and will be removed thereafter.
```

Stub at **old** path. Use a relative link from the stub's directory.

### 3. Sweep inbound references

```powershell
rg -n --no-heading "<old-path-1>|<old-path-2>|..." `
  --glob "!.squad/agents/*/history.md" `
  --glob "!.squad/log/**" `
  --glob "!.squad/orchestration-log/**" `
  --glob "!CHANGELOG.md" `
  --glob "!.git/**"
```

**Always-skip globs** (these are append-only or historical truth):

- `.squad/agents/*/history.md` - personal agent logs
- `.squad/log/**`, `.squad/orchestration-log/**` - dispatch logs
- `CHANGELOG.md` - historical record; new entry only when a PR explicitly owns it

**Always-restricted in some PRs** (check PR scope / authority limits):

- `README.md`, `PERMISSIONS.md`, `SECURITY.md` - tier-1 docs often owned by a later PR. Stubs cover the gap.

### 4. Patch what remains

- `CONTRIBUTING.md` - usually small surgical edit (one-line pointers).
- `.github/workflows/*.yml` - look for hardcoded doc filenames in `actions/github-script` snippets. Pattern: an `isDoc` predicate over a flat array. Convert to `rootDocs.includes(f) || pathPatterns.some(p => p.test(f))` to admit nested trees.
- `.squad/*.md`, `.copilot/**` - direct path edits.
- PowerShell modules - usually `Write-Host`/`Write-Information` strings; harmless if missed but worth catching.

### 5. Em-dash gate

Before commit:

```powershell
rg -l -- "-" <list of new/modified .md files>
```

Must return zero. Use `-` (hyphen) or rephrase. Repo rule: no em dashes in documentation, ever.

### 6. Commit strategy

Three sequential commits (do NOT parallelize - `git index.lock` collisions corrupt commit grouping):

1. **Moves + stubs** (`docs: move <area> ... with redirect stubs`)
2. **CI / workflow patches** (`ci: teach <workflow> about <new tree>`)
3. **Indexes + pointers** (`docs: add <area> index pages and <root> pointer`)

Each commit needs the `Co-authored-by: Copilot <...>` trailer.

### 7. Verify success

```powershell
rg "<old-path-pattern>" --glob "!.git/**"
```

Expected hits post-merge: only the intentional stubs at old paths, plus references in any explicitly-out-of-scope tier-1 docs (which resolve via stubs).

## Gotchas

- **Rename detection breaks when stub is written at old path.** `git status` shows "M old + A new" instead of "R old -> new". History is still preserved because `git log --follow` runs detection at log time, and a 200-byte stub falls below the 50% similarity threshold vs a multi-KB doc. If you need the rename to show in `git log --name-status`, do the move + commit + then add stubs in a follow-up commit.
- **Authority limits override the "patch every hit" instruction.** Always cross-check the task brief's authority block before editing tier-1 docs in another PR's scope.
- **Parallel `git commit` collides on `index.lock`.** Always serialize git operations that mutate the index.
- **Line numbers in task briefs go stale.** A "known hit at file X line Y" should be re-confirmed with `rg`; the underlying file may have been edited since the brief was written.
- **`docs-check.yml` failure messages also reference doc paths.** Update both the `isDoc` predicate AND the `core.setFailed` message.

## References

- First applied: PR #243 (`docs: split docs/ into consumer/ and contributor/ (PR-1 of 5)`), commit `ed6041d07068c990f5fa0dded25f39be5d836870`.
- Consolidated plan: `.squad/decisions/inbox/coordinator-restructure-consolidated-plan-2026-04-20T12-30-00Z.md`.
