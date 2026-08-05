---
name: home-ops-worktree-workflow
description: Use when modifying files in the home-ops repository — provides isolation via git worktrees, validation gates, and cleanup discipline
---

# Worktree Workflow for home-ops

## When to use

Whenever an agent needs to modify files in the repo (features, fixes, config changes, Renovate PR review). Worktrees isolate changes from the current checkout and prevent half-finished work from blocking other branches.

## Prerequisites

- `just` installed (user-level via mise)
- `.worktrees/` directory at repo root (already exists and gitignored)

## Step 1: Detect existing isolation

```bash
GIT_DIR=$(cd "$(git rev-parse --git-dir)" 2>/dev/null && pwd -P)
GIT_COMMON=$(cd "$(git rev-parse --git-common-dir)" 2>/dev/null && pwd -P)
SUBMODULE=$(git rev-parse --show-superproject-working-tree 2>/dev/null)
```

- **If `GIT_DIR != GIT_COMMON` and not in a submodule:** Already in a linked worktree. Skip to Step 4. Do NOT create a nested worktree.
- **Otherwise:** Proceed to Step 2.

## Step 2: Create worktree

Use `main` as the base for feature branches:

```bash
just worktree-create feat/my-thing
```

For existing remote branches (e.g. Renovate PRs):

```bash
just worktree-add origin/renovate/something
```

## Step 3: Enter worktree

```bash
cd .worktrees/<branch-name>
```

## Step 4: Setup

```bash
mise install                     # trust + install tools
mise run secrets:env             # regenerate .env (gitignored, not shared across worktrees)
```

Skip `secrets:env` if 1Password CLI is not available.

## Step 5: Baseline validation

Confirm the workspace starts clean before making changes:

```bash
just flate-test
```

**If tests fail:** Report failures. Do not proceed until the baseline is clean or the user confirms it's pre-existing.

## Step 6: Make changes

Use domain-specific skills as needed:
- `home-ops-add-new-app` — new application deployment
- `home-ops-app-pattern` — bjw-s HelmRelease authoring
- `home-ops-create-httproute` — Gateway API HTTPRoute
- `home-ops-external-secrets` — ExternalSecret from 1Password
- `home-ops-flate` — flate validation and diff

## Step 7: Validate

```bash
just hooks-install
pre-commit run --all-files        # gitleaks + trufflehog
just flate-test                   # kustomize build + flate validation
```

## Step 8: Commit and push

```bash
git add <files>
git commit -m "<type>(<scope>): <description>"
git push origin <branch-name>
```

Follow the repo's commit style (Conventional Commits). Use `caveman-commit` skill if available.

## Step 9: Create pull request

```bash
gh pr create --fill
```

## Step 10: Clean up

Return to the repo root and remove the worktree:

```bash
cd "$(git rev-parse --git-common-dir)/.."
just worktree-clean <branch-name>
```

## Worktree lifecycle rules

| Phase | Rule |
|---|---|
| **Create** | Always base feature branches on `main` |
| **Add** | Use `worktree-add` for existing remote branches only |
| **Work** | One feature per worktree. No nested worktrees. |
| **Validate** | Run full validation before every commit |
| **Clean** | Always remove when done. Stale worktrees confuse agents. |
| **Secrets** | `.env` is per-worktree — re-run `secrets:env` in each new one |

## Common gotchas

- **`.env` is not shared** across worktrees. Always regenerate: `mise run secrets:env`
- **SOPS decryption works natively** — worktrees share the `.git` dir, personal age key at `~/.config/sops/age/keys.txt`
- **mise.toml pins the toolchain** (repo-level); the mise binary is user-level — installs are cached globally, so they work across all worktrees
- **`git worktree remove` fails if the worktree has uncommitted changes** — commit or stash first
- **Pre-commit hooks** are installed per-worktree — run `mise run hooks:install` in each new worktree
- **Renovate branches** can be checked out with `just worktree-add origin/renovate/...` for local validation before merge
- **The existing explicit-orders gates in AGENTS.md still apply** — worktree isolation doesn't override safety rules
