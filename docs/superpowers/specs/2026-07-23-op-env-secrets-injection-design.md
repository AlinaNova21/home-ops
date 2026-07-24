# Generic 1Password env injection for workstation CLIs (kopia as first consumer)

- **Date:** 2026-07-23
- **Status:** Draft, pending user review
- **Owner:** home-ops maintainers

## 1. Problem

The kopia CLI is installed via `mise.toml:44` but the workstation has no wiring
to authenticate it against the kopiur-managed Backblaze B2 repository. The
cluster side already sources three secrets (`KOPIA_PASSWORD`,
`AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`) from 1Password via External
Secrets Operator (`kubernetes/kopiur-system/kopiur/repository/externalsecret.yaml`),
so the credential material exists — it is just unreachable from a workstation
shell. A developer wanting to run `kopia snapshot ls` or `kopia restore` today
has to copy values out of 1Password by hand, paste them into the shell, and
remember to clean up afterward.

The same gap will recur for every other CLI tool that needs a 1Password-backed
secret (e.g. `cloudflared`, `1password CLI`, future tooling). Building a
kopia-specific injector would force a rewrite for each new consumer.

## 2. Goal

Introduce a small, generic 1Password env-injection pattern that:

- Pulls secret material from 1Password into a gitignored `.env` using `op inject`.
- Auto-loads the resulting `.env` into every `mise exec` shell (via the existing
  `_.file = ".env"` directive in `mise.toml:11`).
- Is extensible: adding a new tool = appending `KEY="op://..."` lines to a
  single tracked template.
- Ships one kopia-specific helper task that connects the local `kopia` CLI to
  the kopiur cluster repository.

### In scope

- `.op.env` template at the repo root (tracked).
- One mise task (`secrets:env`) that runs `op inject -i .op.env -o .env`.
- One mise task (`kopia:connect`) that connects the local kopia CLI to the
  kopiur cluster repository.
- A gitleaks path allowlist for `.op.env` (URI templates only; never holds
  real secrets).
- Documentation of the workflow in `AGENTS.md`.

### Out of scope

- Any additional kopia subcommand tasks (`snapshots`, `mount`, `restore`,
  `status`, `disconnect`). Adding these is a follow-up that follows the same
  one-line-per-task pattern as `kopia:connect`.
- A Justfile wrapper (`just secrets-env`). `mise run secrets:env` is sufficient.
- A postinstall hook that auto-runs `secrets:env`. Would force a 1Password
  biometric prompt on every `mise install`.
- Renaming the shared 1Password item `volsync-kopia-password` to
  `kopiur-kopia-password`. Separate cleanup tracked in
  `docs/superpowers/specs/2026-07-23-drop-volsync-design.md:157`.
- Modifying the in-cluster kopiur configuration in any way. This change is
  workstation-side only.
- Editing `kubernetes/scripts/deploy-infrastructure.sh`. Not affected.

## 3. Current State

| Path | Type | Notes |
|---|---|---|
| `mise.toml:11` | mise `[env]` | `_.file = ".env"` — auto-loads `.env` if it exists |
| `mise.toml:14-15` | mise `[env]` | `KUBECONFIG` / `TALOSCONFIG` declared directly in `mise.toml`, not in `.env` |
| `mise.toml:44` | mise `[tools]` | `kopia = "latest"` — already on the path |
| `~/.config/mise/conf.d/00-local.toml` | user-level mise | `op = "latest"` — already installed user-side |
| `.env` | gitignored, **does not exist** | Never been created in this repo |
| `.op.env` | **does not exist** | New file |
| `.gitignore:9-10` | gitignore | Lists `.env` and `.envrc` (local credential/config files) |
| `.gitleaks.toml` | secret scanner config | Path allowlist currently only `charts/kasm/*.lock` and `.gitleaks.toml` |
| `kubernetes/kopiur-system/kopiur/repository/externalsecret.yaml:18` | ExternalSecret | Reads `volsync-kopia-password` from 1Password vault `home-ops` |
| `kubernetes/kopiur-system/kopiur/repository/externalsecret.yaml:21-26` | ExternalSecret | Reads `backblaze-k8s-backup` (key-id, credential) from vault `home-ops` |
| `kubernetes/kopiur-system/kopiur/repository/clusterrepository.yaml:13-17` | ClusterRepository | Bucket `whoverse-k8s-backups`, prefix `kopiur`, endpoint `s3.us-west-001.backblazeb2.com`, region `us-west-001` |
| `kubernetes/external-secrets-system/external-secrets/config/clustersecretstore.yaml` | ClusterSecretStore | Vault alias `home-ops` → priority 1; canonical cluster-side reference |

The workstation currently has no `.env` and no `.op.env`. `mise.toml` already
declares `_.file = ".env"` so any future `.env` is auto-loaded; no mise env
config change is required for this design.

## 4. Target State

- A tracked `.op.env` at the repo root with one or more commented sections,
  each containing `KEY="op://vault/item/field"` lines. The kopia section is the
  first; future tools append their own section.
- `mise run secrets:env` runs `op inject -i .op.env -o .env`, producing a
  gitignored `.env` with resolved values. Re-running overwrites `.env` cleanly.
- `mise run kopia:connect` runs
  `kopia repository connect s3 --endpoint=s3.us-west-001.backblazeb2.com --region=us-west-001 --bucket=whoverse-k8s-backups --prefix=kopiur`,
  which uses the env-injected `KOPIA_PASSWORD`, `AWS_ACCESS_KEY_ID`,
  `AWS_SECRET_ACCESS_KEY`, and `AWS_REGION` for authentication.
- A `mise exec -- kopia …` shell now sees `KOPIA_PASSWORD`, `AWS_*` as ordinary
  environment variables and can connect/restore/inspect without manual
  secret handling.
- `.gitleaks.toml` allowlists `\.op\.env` so the URI templates do not
  produce false positives.
- `AGENTS.md` gets a short subsection documenting the workflow and how to
  add new sections.

## 5. Design

### 5.1 Files to add

1. **`.op.env`** (repo root, tracked). URI template; kopia is the first
   section. Future tools append new commented sections.

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

### 5.2 Files to edit

1. **`mise.toml`** (add two `[tasks.*]` blocks at the end, after the
   existing `[tasks."hooks:install"]` block).

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

2. **`.gitleaks.toml`** — append `'''\.op\.env'''` to the existing `paths`
   allowlist under `[[allowlists]]`.

3. **`AGENTS.md`** — add a new `## Workstation Secrets` section (top-level
   heading, not a subsection of `## Tooling`) documenting:
   `mise run secrets:env` to refresh `.env`; `mise run kopia:connect` to
   connect the local kopia CLI to the kopiur-managed repo; how to add a new
   section to `.op.env`.

### 5.3 Files NOT modified

- `.gitignore` — already lists `.env` (line 36). No change.
- `kubernetes/**` — workstation-side change only; the cluster-side kopiur
  resources are untouched.
- `Justfile` — no wrapper recipe (decided against in brainstorming).
- `mise.toml [env]` block — `_.file = ".env"` already exists and is
  sufficient; no additions needed.

### 5.4 Why this is generic

- `.op.env` is plain text. Adding a new tool = adding `KEY="op://..."` lines
  inside a new commented section. No script, no sed, no awk.
- Comments are preserved by `op inject` into `.env`, so `# ─── kopia ───`
  becomes a natural section label in the generated file.
- `op inject -i .op.env -o .env` overwrites `.env` on every run. Idempotency
  is automatic; no duplicates, no drift. The current `.env` is empty (does
  not exist), so overwriting is safe. The repo convention is that persistent
  env vars live in `mise.toml [env]`, not `.env`, so this constraint is
  already enforced.
- Tool-specific helpers like `kopia:connect` are isolated one-liners; each
  new tool adds a similarly small task.

### 5.5 Failure modes

| Scenario | Behavior |
|---|---|
| `.op.env` missing | `op inject` fails with a clear "no such file" message; `.env` not written |
| `op` not signed in | `op inject` exits non-zero; `.env` not written |
| 1Password item missing | `op inject` errors on that specific field; task exits non-zero |
| `.env` is read-only | `op inject -o .env` fails; task exits non-zero |
| User runs `kopia:connect` without `secrets:env` | `kopia` exits with "repository not connected" or "no password"; user re-runs `secrets:env` |

All failure modes leave the system in a recoverable state — no partial
writes, no orphans.

### 5.6 Security

- `.op.env` holds 1Password URI references (`op://…`) only, never secret
  material. Safe to track.
- `.env` is gitignored. Never committed.
- `op inject` writes real secret values to `.env` (mode depends on umask,
  typically `0644`). Workstation-only file on a single-user machine; risk is
  bounded. Adding stricter perms (e.g. `chmod 600 .env`) is a follow-up if
  desired but is not in scope for this change.
- `.gitleaks.toml` allowlist is path-based (`\.op\.env`); gitleaks default
  rules are not relaxed. TruffleHog is unaffected.

## 6. Validation

### Build / lint

- `kustomize build kubernetes | kubeconform -strict -ignore-missing-schemas …`
  must still pass. (This change touches no `kubernetes/**` files, so it is
  expected to pass unchanged.)
- `pre-commit run --all-files` should pass. The `.op.env` URI templates do
  not match default gitleaks or trufflehog secret patterns; the path
  allowlist is precautionary.

### Behavioral

- `mise run secrets:env` produces `.env` with resolved values. Verify with
  `grep -E '^KOPIA_PASSWORD=' .env` — should print a single line with a
  non-empty value (the actual password).
- `mise run kopia:connect` then `mise exec -- kopia repository status`
  should report the connected S3 repository at
  `s3://s3.us-west-001.backblazeb2.com/whoverse-k8s-backups/kopiur`.
- Re-running `mise run secrets:env` must produce a deterministic `.env`
  (same content byte-for-byte, modulo timestamps if any are injected).
- Adding a new section to `.op.env` (e.g. `# ─── test ───` with a dummy
  variable) and re-running `secrets:env` must include the new variable in
  `.env`.

### Negative tests

- Delete `.op.env`, run `mise run secrets:env` → fails with "no such file".
- Sign out of `op` (`op signout`), run `mise run secrets:env` → fails
  non-zero, `.env` unchanged.
- Run `mise run kopia:connect` without first running `secrets:env` (delete
  `.env`) → `kopia` fails to authenticate; user is prompted to re-run
  `secrets:env`.

## 7. Risks and Mitigations

| Risk | Mitigation |
|---|---|
| `.env` ends up with broad `0644` perms readable by other local users | Out of scope; documented in §5.6 as a follow-up. Single-user workstation is the current operating assumption. |
| Drift between `.op.env` URIs and the in-cluster kopiur `ExternalSecret` (`externalsecret.yaml:18,21-26`) | Both reference the same 1Password items; they share a vault (`home-ops`) by definition. If the 1Password item name changes (e.g. the planned rename to `kopiur-kopia-password`), both files update in the same PR. |
| Future tools add `KOPIA_*` or `AWS_*` keys that conflict with the kopia section | Section comments make ownership obvious; `op inject` is a straight overwrite, so later sections win on collision (intentional: later = more recent intent). |
| `op` CLI version mismatch with `op inject` flag set | `op inject -i`/`-o` is stable across recent CLI versions. If a flag deprecation surfaces, the one-line task body is trivial to update. |
| `mise exec` does not load `.env` on the user's shell | `mise.toml:11` already has `_.file = ".env"`. Verified by reading the file; no change required. |
| Gitleaks false positive on `op://` strings | Path-based allowlist `\.op\.env` added in §5.2. URI strings are not real secrets. |
| User runs `kopia:connect` against an empty `.env` (forgot `secrets:env`) | kopia fails clearly; user re-runs `secrets:env`. Documented in the task description and in `AGENTS.md`. |
| The kopia bucket/endpoint/prefix in `clusterrepository.yaml` change | `kopia:connect` task body would need updating to match. §5.1 makes the mirroring relationship explicit (the values come from `clusterrepository.yaml:13-17`), signaling maintenance locality. |

## 8. Open Questions

None. All decisions resolved during brainstorming:

- Vault name = `home-ops` (matches `ClusterSecretStore/onepassword-connect`).
- Use case = restore + inspect (no UI auth needed in `.op.env`).
- File location = repo root.
- Task granularity = single `secrets:env` task, no per-section sub-tasks.
- Implementation = `op inject -i .op.env -o .env` directly, no script.
- Justfile wrapper = dropped.
- Postinstall hook = dropped (would force biometric per `mise install`).
- kopia tasks = one task only (`kopia:connect`); other kopia operations are
  follow-ups using the same one-line-per-task pattern.

## 9. Implementation Plan

A separate plan will be generated via the `writing-plans` skill after this
spec is reviewed.
