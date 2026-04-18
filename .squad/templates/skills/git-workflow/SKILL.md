---
name: "git-workflow"
description: "Squad branching model: main-as-trunk workflow with short-lived issue branches"
domain: "version-control"
confidence: "high"
source: "team-decision"
---

## Context

Squad uses a **main-as-trunk** model. **All feature work branches from `main` and PRs target `main`.** There is no long-lived `dev` integration branch.

| Branch | Purpose | Publishes |
|--------|---------|-----------|
| `main` | Trunk — all feature work merges here via PR | `npm publish` on tag |
| `squad/{issue}-{slug}` | Short-lived issue branches | — (deleted after merge) |
| `hotfix/{slug}` | Urgent fixes branched from main | — (PR back to main) |

## Branch Naming Convention

Issue branches MUST use: `squad/{issue-number}-{kebab-case-slug}`

Examples:
- `squad/195-fix-version-stamp-bug`
- `squad/42-add-profile-api`

Agent-prefixed names (e.g., `iris/134-main-trunk-docs`) are also acceptable when an agent owns the branch end-to-end.

## Workflow for Issue Work

1. **Branch from main:**
   ```bash
   git checkout main
   git pull origin main
   git checkout -b squad/{issue-number}-{slug}
   ```

2. **Mark issue in-progress:**
   ```bash
   gh issue edit {number} --add-label "status:in-progress"
   ```

3. **Create draft PR targeting main:**
   ```bash
   gh pr create --base main --title "{description}" --body "Closes #{issue-number}

## Self-review

### Diff summary
- {bullet 1: what changed at a high level, 3 bullets max}
- {bullet 2}
- {bullet 3}

### Risks considered
- {risk 1}: {mitigation, or 'accepted because ...'}
- {risk 2}: ...
- Out of scope on purpose: {what was deliberately NOT touched}

### Testing
- Ran: {test command(s) and pass/fail counts}
- Added: {new tests, or 'none, doc/template-only change'}
- Skipped: {tests that don't apply}, {reason, or 'n/a'}
" --draft
   ```

   The `## Self-review` block is mandatory for every squad PR (policy gate, CI enforcement deferred). See `.copilot/copilot-instructions.md` → "Squad Pre-PR Self-Review" for the full contract.

4. **Do the work.** Make changes, write tests, commit with issue reference.

5. **Push and mark ready:**
   ```bash
   git push -u origin squad/{issue-number}-{slug}
   gh pr ready
   ```

6. **After merge to main:**
   ```bash
   git checkout main
   git pull origin main
   git branch -d squad/{issue-number}-{slug}
   git push origin --delete squad/{issue-number}-{slug}
   ```

## Parallel Multi-Issue Work (Worktrees)

When the coordinator routes multiple issues simultaneously (e.g., "fix bugs X, Y, and Z"), use `git worktree` to give each agent an isolated working directory. No filesystem collisions, no branch-switching overhead.

### When to Use Worktrees vs Sequential

| Scenario | Strategy |
|----------|----------|
| Single issue | Standard workflow above — no worktree needed |
| 2+ simultaneous issues in same repo | Worktrees — one per issue |
| Work spanning multiple repos | Separate clones as siblings (see Multi-Repo below) |

### Setup

From the main clone (must be on main or any branch):

```bash
# Ensure main is current
git fetch origin main

# Create a worktree per issue — siblings to the main clone
git worktree add ../squad-195 -b squad/195-fix-stamp-bug origin/main
git worktree add ../squad-193 -b squad/193-refactor-loader origin/main
```

**Naming convention:** `../{repo-name}-{issue-number}` (e.g., `../squad-195`, `../squad-pr-42`).

Each worktree:
- Has its own working directory and index
- Is on its own `squad/{issue-number}-{slug}` branch from main
- Shares the same `.git` object store (disk-efficient)

### Per-Worktree Agent Workflow

Each agent operates inside its worktree exactly like the single-issue workflow:

```bash
cd ../squad-195

# Work normally — commits, tests, pushes
git add -A && git commit -m "fix: stamp bug (#195)"
git push -u origin squad/195-fix-stamp-bug

# Create PR targeting main (include ## Self-review block in body, see PR template above)
gh pr create --base main --title "fix: stamp bug" --body "Closes #195

## Self-review

### Diff summary
- {bullet 1: what changed, 3 bullets max}
- {bullet 2}
- {bullet 3}

### Risks considered
- {risk 1}: {mitigation}
- Out of scope on purpose: {what was deliberately NOT touched}

### Testing
- Ran: {test command(s) and pass/fail counts}
- Added: {new tests, or 'none, doc-only'}
- Skipped: {tests that don't apply}, {reason or 'n/a'}
" --draft
```

All PRs target `main` independently. Agents never interfere with each other's filesystem.

### .squad/ State in Worktrees

The `.squad/` directory exists in each worktree as a copy. This is safe because:
- `.gitattributes` declares `merge=union` on append-only files (history.md, decisions.md, logs)
- Each agent appends to its own section; union merge reconciles on PR merge to main
- **Rule:** Never rewrite or reorder `.squad/` files in a worktree — append only

### Cleanup After Merge

After a worktree's PR is merged to main:

```bash
# From the main clone
git worktree remove ../squad-195
git worktree prune          # clean stale metadata
git branch -d squad/195-fix-stamp-bug
git push origin --delete squad/195-fix-stamp-bug
```

If a worktree was deleted manually (rm -rf), `git worktree prune` recovers the state.

---

## Multi-Repo Downstream Scenarios

When work spans multiple repositories (e.g., squad-cli changes need squad-sdk changes, or a user's app depends on squad):

### Setup

Clone downstream repos as siblings to the main repo:

```
~/work/
  squad-pr/          # main repo
  squad-sdk/         # downstream dependency
  user-app/          # consumer project
```

Each repo gets its own issue branch following its own naming convention. If the downstream repo also uses Squad conventions, use `squad/{issue-number}-{slug}`.

### Coordinated PRs

- Create PRs in each repo independently
- Link them in PR descriptions:
  ```
  Closes #42

  **Depends on:** squad-sdk PR #17 (squad-sdk changes required for this feature)
  ```
- Merge order: dependencies first (e.g., squad-sdk), then dependents (e.g., squad-cli)

### Local Linking for Testing

Before pushing, verify cross-repo changes work together:

```bash
# Node.js / npm
cd ../squad-sdk && npm link
cd ../squad-pr && npm link squad-sdk

# Go
# Use replace directive in go.mod:
# replace github.com/org/squad-sdk => ../squad-sdk

# Python
cd ../squad-sdk && pip install -e .
```

**Important:** Remove local links before committing. `npm link` and `go replace` are dev-only — CI must use published packages or PR-specific refs.

### Worktrees + Multi-Repo

These compose naturally. You can have:
- Multiple worktrees in the main repo (parallel issues)
- Separate clones for downstream repos
- Each combination operates independently

---

## Anti-Patterns

- ❌ Long-lived integration branches (no `dev` — branch from `main`, PR to `main`)
- ❌ PR targeting anything other than `main` for normal feature work
- ❌ Non-conforming branch names (must be `squad/{number}-{slug}` or `{agent}/{number}-{slug}`)
- ❌ Committing directly to `main` (use PRs)
- ❌ Switching branches in the main clone while worktrees are active (use worktrees instead)
- ❌ Using worktrees for cross-repo work (use separate clones)
- ❌ Leaving stale worktrees after PR merge (clean up immediately)

## Hotfixes

Hotfixes follow the same model: branch from `main` as `hotfix/{slug}`, PR back to `main`. Tag and release once merged.
