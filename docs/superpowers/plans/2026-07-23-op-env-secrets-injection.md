# Generic 1Password env injection Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Wire workstation CLIs (kopia first) to 1Password-backed secrets via `op inject`, with `mise run secrets:env` to refresh `.env` and `mise run kopia:connect` to wire the local kopia CLI to the kopiur-managed repo.

**Architecture:** Tracked `.op.env` URI template → `op inject -i .op.env -o .env` → gitignored `.env` → auto-loaded by mise via the existing `_.file = ".env"` directive. Tool-specific helpers (`kopia:connect`) are one-line mise tasks.

**Tech Stack:** `op` (1Password CLI, user-level mise), `kopia` (pinned in repo `mise.toml:44`), `mise` tasks, `gitleaks` path allowlist.

**Companion spec:** `docs/superpowers/specs/2026-07-23-op-env-secrets-injection-design.md`

---

## File Structure

| File | Action | Purpose |
|---|---|---|
| `.op.env` | Create | Tracked URI template with `op://…` references; comments group sections (kopia first) |
| `mise.toml` | Modify | Append `[tasks."secrets:env"]` and `[tasks."kopia:connect"]` |
| `.gitleaks.toml` | Modify | Append `'''\.op\.env'''` to the path allowlist |
| `AGENTS.md` | Modify | Append a new top-level `## Workstation Secrets` section |
| `.env` | Generated | Created by `op inject`; gitignored; auto-loaded by mise |

No script files, no Justfile changes, no Kubernetes changes.

---

## Task 1: Create `.op.env` template

**Files:**
- Create: `.op.env` (repo root)

- [ ] **Step 1: Verify `.env` is already gitignored**

Run: `git check-ignore .env`
Expected: prints `.env` (path is ignored). If it prints nothing or errors, fix `.gitignore:9` before proceeding.

- [ ] **Step 2: Write `.op.env` at the repo root**

Write the following content exactly (note the trailing newline after the last comment line):

```bash
# Source for `mise run secrets:env`. Add new tools by appending a commented section.
# Resolves to .env (gitignored). Mise loads .env on `mise exec`.

# ─── kopia ──────────────────────────────────────────────────────────────────
# Mirrors kubernetes/kopiur-system/kopiur/repository/{externalsecret,clusterrepository}.yaml
KOPIA_PASSWORD="op://home-ops/volsync-kopia-password/password"
AWS_ACCESS_KEY_ID="op://home-ops/backblaze-k8s-backup/key-id"
AWS_SECRET_ACCESS_KEY="op://home-ops/backblaze-k8s-backup/credential"
AWS_REGION="us-west-001"

# ─── (add future tools here) ────────────────────────────────────────────────
```

- [ ] **Step 3: Verify the file**

Run: `cat .op.env`
Expected: Output matches the content from Step 2.

- [ ] **Step 4: Commit**

```bash
git add .op.env
git commit -m "feat: add .op.env template for 1Password secret injection"
```

---

## Task 2: Append mise tasks

**Files:**
- Modify: `mise.toml` (append two `[tasks.*]` blocks after the existing `[tasks."hooks:install"]` block at line 54)

- [ ] **Step 1: Confirm the end of `mise.toml`**

Run: `tail -10 mise.toml`
Expected: ends with the `run = ['pre-commit install --install-hooks --overwrite']` line and its closing `]`.

- [ ] **Step 2: Append the new task blocks**

Open `mise.toml` and append the following after the existing `hooks:install` block (preserve the existing trailing newline and add one blank line before the new block):

```toml

[tasks."secrets:env"]
description = "Inject 1Password secrets from .op.env into .env"
run = ['op inject -i .op.env -o .env']

[tasks."kopia:connect"]
description = "Connect workstation kopia CLI to the kopiur cluster repository (requires `mise run secrets:env` first)"
run = [
  'kopia repository connect s3 --endpoint=s3.us-west-001.backblazeb2.com --region=us-west-001 --bucket=whoverse-k8s-backups --prefix=kopiur',
]
```

- [ ] **Step 3: Verify the tasks are registered**

Run: `mise tasks ls 2>&1 | grep -E 'secrets:env|kopia:connect'`
Expected: prints both `secrets:env` and `kopia:connect`.

- [ ] **Step 4: Verify the task descriptions**

Run: `mise tasks ls --all 2>&1 | grep -E '(secrets:env|kopia:connect)' -A 2`
Expected: shows the `description = ...` line under each task.

- [ ] **Step 5: Commit**

```bash
git add mise.toml
git commit -m "feat(mise): add secrets:env and kopia:connect tasks"
```

---

## Task 3: Add gitleaks path allowlist

**Files:**
- Modify: `.gitleaks.toml`

- [ ] **Step 1: Inspect current allowlist**

Run: `cat .gitleaks.toml`
Expected: contains one `[[allowlists]]` block with `paths = ['charts/kasm/.*\.lock', '\.gitleaks\.toml']`.

- [ ] **Step 2: Add the `.op.env` path entry**

Edit `.gitleaks.toml` and add `'''\.op\.env'''` as the third element of the `paths` array:

```toml
title = "home-ops gitleaks config"

[extend]
useDefault = true

[[allowlists]]
description = "Generated / vendored content not authored here"
paths = [
  '''charts/kasm/.*\.lock''',
  '''\.gitleaks\.toml''',
  '''\.op\.env''',
]
```

- [ ] **Step 3: Verify gitleaks passes**

Run: `pre-commit run gitleaks --all-files`
Expected: "Detect hardcoded secrets (gitleaks) ............... Passed"

- [ ] **Step 4: Commit**

```bash
git add .gitleaks.toml
git commit -m "chore(gitleaks): allowlist .op.env URI templates"
```

---

## Task 4: Document the workflow in AGENTS.md

**Files:**
- Modify: `AGENTS.md` (append a new top-level section at the end of the file)

- [ ] **Step 1: Append the `## Workstation Secrets` section**

Add the following at the end of `AGENTS.md` (preserve any trailing newline, then add one blank line before the new section):

```markdown

## Workstation Secrets

1Password-backed env vars for workstation CLIs live in a tracked template at the repo root and resolve to a gitignored `.env` via `op inject`.

```bash
mise run secrets:env      # refresh .env from .op.env (requires `op` signed in)
mise run kopia:connect    # connect local kopia CLI to the kopiur-managed repo
mise exec -- kopia snapshot ls
```

- `.op.env` holds `op://…` URI templates in commented sections (`# ─── kopia ───` is the first). Values mirror the corresponding in-cluster `ExternalSecret` items.
- Adding a new tool: append `KEY="op://vault/item/field"` lines inside a new commented section in `.op.env`, then `mise run secrets:env` to refresh.
- `.env` is gitignored and never tracked. Do not add manual entries there — use `mise.toml [env]` for persistent vars.
- Tool-specific helpers (e.g. `kopia:connect`) live as one-line mise tasks alongside `secrets:env`.
```

- [ ] **Step 2: Verify the section was added**

Run: `grep -n '^## Workstation Secrets' AGENTS.md`
Expected: prints a line number where the new section starts.

- [ ] **Step 3: Verify the section renders cleanly**

Run: `grep -A 1 '^## Workstation Secrets' AGENTS.md`
Expected: shows the heading followed by the lead paragraph.

- [ ] **Step 4: Commit**

```bash
git add AGENTS.md
git commit -m "docs: document workstation secrets workflow"
```

---

## Task 5: End-to-end smoke test (manual verification)

**Files:** none (verification only)

**Note:** This task requires `op` biometric sign-in and a reachable S3 bucket.
It cannot be run from CI or by a non-interactive agent. The implementer runs
it once locally after the commits land; until then the task remains open.
Steps 4 (`.env` gitignored), 8 (full pre-commit), and 9 (final repo state)
were verified mechanically and pass.

- [ ] **Step 1: Prerequisites — `op` signed in and items present**

Run: `op whoami`
Expected: prints the account email. If it errors, run `op signin` first.

Run: `op item get volsync-kopia-password --vault home-ops --fields password >/dev/null && op item get backblaze-k8s-backup --vault home-ops --fields key-id >/dev/null && echo ok`
Expected: prints `ok`. If anything errors, the 1Password items are missing or the vault name differs.

- [ ] **Step 2: Run `secrets:env`**

Run: `mise run secrets:env`
Expected: exits 0; `.env` is created at the repo root.

- [ ] **Step 3: Verify `.env` content**

Run: `grep -E '^(KOPIA_PASSWORD|AWS_ACCESS_KEY_ID|AWS_SECRET_ACCESS_KEY|AWS_REGION)=' .env`
Expected: prints four lines, each with a non-empty value that does NOT contain `op://`.

- [ ] **Step 4: Verify `.env` is gitignored**

Run: `git check-ignore .env`
Expected: prints `.env`. (The path is ignored, confirming `.gitignore:9` covers it.)

- [ ] **Step 5: Run `kopia:connect`**

Run: `mise run kopia:connect`
Expected: kopia connects to the S3 backend, prints a "Connected to repository" or similar confirmation, exits 0. The endpoint, bucket, and prefix shown should match the values in `kubernetes/kopiur-system/kopiur/repository/clusterrepository.yaml:13-17`.

- [ ] **Step 6: Verify kopia can read the repository**

Run: `mise exec -- kopia repository status`
Expected: reports the connected S3 repository at `s3://s3.us-west-001.backblazeb2.com/whoverse-k8s-backups/kopiur`.

- [ ] **Step 7: Verify re-running `secrets:env` is idempotent**

Run: `mise run secrets:env && mise run secrets:env`
Expected: both runs exit 0; `.env` content is unchanged (run `git status` to confirm no spurious changes).

- [ ] **Step 8: Run full pre-commit to verify no regressions**

Run: `pre-commit run --all-files`
Expected: all hooks (gitleaks, trufflehog) pass.

- [ ] **Step 9: Verify final repo state**

Run: `git status`
Expected: working tree clean; the four commits from Tasks 1-4 are present on the branch.

---

## Self-Review

**Spec coverage:**
- §5.1 `.op.env` create → Task 1
- §5.2 `mise.toml` tasks → Task 2
- §5.2 `.gitleaks.toml` allowlist → Task 3
- §5.2 `AGENTS.md` section → Task 4
- §5.3 NOT-modified files → no tasks (correct: `.gitignore`, `Justfile`, `kubernetes/**`, `mise.toml [env]` block stay as-is)
- §6 Validation → Task 5
- §6 Negative tests (delete `.op.env`, sign out of `op`, run `kopia:connect` without `secrets:env`) → not in plan; documented in spec §5.5 as recoverable failure modes. Adding them would force destructive ops (sign-out, file deletion) on the engineer's workstation, so they are intentionally excluded from the implementation plan.

**Placeholder scan:** no "TBD", "TODO", "implement later", "similar to Task N", or vague "add appropriate error handling" present. All commands are exact.

**Type consistency:** no types/classes/function names in this change; N/A.

**Risks acknowledged:** if `op` is not signed in, Task 5 fails fast at Step 1. If the 1Password items have been renamed (e.g. `volsync-kopia-password` → `kopiur-kopia-password` per the planned follow-up), Task 5 Step 1 errors and `.op.env` needs an update before retry — this is the intended drift-detection behavior.
