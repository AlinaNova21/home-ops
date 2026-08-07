# Renovate Config Migration to home-operations/renovate-presets

**Date:** 2026-08-07
**Status:** Approved
**Scope:** `.github/renovate.json` + 8 exportarr/seerr `# renovate:` annotations in `kubernetes/downloads/*`

## Problem

`.github/renovate.json` hand-maintains a growing list of managers, custom
managers, and file-pattern rules that overlap with the
[`home-operations/renovate-presets`](https://github.com/home-operations/renovate-presets)
bundle (v6.0.0, released 2026-08-07). The pre-#788 config produced semantic
commit styles (`fix(helm): update chart …`) that the rewrite (#788) dropped in
favor of generic `chore(deps): …` messages. Goal: standardize on the presets
repo as the source of truth, keep only what presets deliberately don't ship
(automerge policy, labels) local, and reduce maintenance.

## Preset audit (v6.0.0)

App presets under `apps/` are **opt-in** (6.0.0 breaking change: they were
removed from `default.json`). Only `apps/talosFactory.json5` applies:

| Preset | Applies? | Why |
|---|---|---|
| `apps/talosFactory` | ✅ | `talos/whoverse/clusterconfig/*.yaml` contain `factory.talos.dev/…/installer:…:v1.13.5` images, currently untracked |
| `apps/cnpg` | ❌ | No CNPG anywhere; memos uses an external postgres |
| `apps/grafanaDashboards` | ❌ | Dashboards are embedded `spec.json` in GrafanaDashboard CRs — no `grafanaCom`/grafana.com URL refs |
| `apps/llamacpp`, `apps/phanpy`, `apps/searxng` | ❌ | None of these apps run here |

The generic bundle (`default.json`) is extended wholesale: base config,
manager file patterns, annotated + oci managers, all overrides (mise, helmfile,
changelogs), and both policies (semanticCommits, zer0ver).

## Solution

Replace the hand-rolled managers/customManagers with preset extends; keep
automerge + label rules local (presets ship no automerge policy):

```jsonc
{
  "$schema": "https://docs.renovatebot.com/renovate-schema.json",
  "extends": [
    "github>home-operations/renovate-presets#6.0.0",                          // generic bundle
    "github>home-operations/renovate-presets//apps/talosFactory.json5#6.0.0", // opt-in: Talos
    ":timezone(America/Chicago)"                                             // TZ for scheduling
  ],
  "pinDigests": true,   // top-level, after extends: overrides the github-actions digest helper
  "packageRules": [ /* automerge policy + labels, unchanged */ ]
}
```

Preset upgrades arrive via Renovate's renovate-config self-update PRs
(tag-pinned, so there is a review point per bump).

### Accepted behavior deltas

1. **Broad manager file patterns** — flux/kubernetes scan all `.ya?ml`. Talos
   machine configs start being tracked: `kubelet` (covered by the existing
   no-automerge guard) plus new `kube-apiserver` / `kube-proxy` /
   `kube-scheduler` (`registry.k8s.io`, `:v1.36.2`). Watch for noise; add a
   targeted disable rule only if it materializes.
2. **`factory.talos.dev` installer images** tracked via the talosFactory
   custom datasource (currently untracked).
3. **Annotated manager** replaces the local `version:`-only customManager
   (handles `tag:`/`=`/quotes/anchors). The 8 exportarr/seerr `# renovate:`
   annotations become duplicate deps (the flux manager already tracks those
   images) → **annotations deleted**.
4. **Semantic commit style** restored: `fix(helm): update chart …`,
   `fix(container): update image …`; majors become `feat(...)!:`.
5. **zer0ver policy** — 0.x minors get `!` prefix + `major-` branch routing.
   Existing `!/^0/` automerge guards remain compatible.
6. **Dependency Dashboard** enabled ("Renovate Dashboard 🤖" issue).
7. **`:disableRateLimiting`** — no hourly PR cap (matches heavy automerge).
8. **mise / helmfile / changelog overrides** — mise.toml single-word tools,
   bootstrap helmfile depNames, cloudflared changelog.
9. **`helpers:pinGitHubActionDigestsToSemver`** cancelled out by local
   `pinDigests: true` (extends merge before top-level config).

## Validation

- `npx renovate-config-validator` on the new config (extends resolve, schema)
- `pre-commit run --all-files` (gitleaks + trufflehog)
- `just flate-test` (annotation removals touch `kubernetes/`)

## Rollout

Merge to main → GitHub-hosted Renovate picks up the new config on next run.
Expected first-run outcomes: new dep extraction on talos configs, semantic
commit style on new PRs, dependency dashboard issue created.
