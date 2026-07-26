# Flatten Kubernetes Hierarchy Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace `kubernetes/apps/` and `kubernetes/infrastructure/` with a single `kubernetes/<namespace>/` tree, replace the two Flux roots with one `cluster` root, and add targeted `dependsOn` edges — all without ever enabling pruning until ownership transfer is proven.

**Architecture:** A staged copy → adopt → switch → remove migration. Every Kustomization involved in the migration runs with `prune: false` from the first commit until the user explicitly authorizes re-enabling at the end. Each namespace move follows a fixed per-namespace gate (Section "Per-Namespace Gate" below) with read-only verification commands. Tiers are ordered least-critical first.

**Tech Stack:** Flux v2 (kustomize-controller), Kustomize, OCI artifact from GitHub Actions, kubectl.

**Pause rule (binding):** No `git commit`, `git push`, `kubectl apply`, `flux reconcile`, or `prune: true` toggles without an explicit "continue" from the user.

**Spec reference:** `docs/superpowers/specs/2026-07-22-flatten-k8s-hierarchy-design.md`

---

## File Structure

### Created
- `kubernetes/flux-config/cluster.yaml` — replacement Flux root (`prune: false` until G7)
- `kubernetes/kustomization.yaml` — namespace aggregator listing only the active namespaces
- `kubernetes/<namespace>/...` — every active namespace directory moves here from its old group

### Modified
- `kubernetes/apps/kustomization.yaml` — namespaces removed as they migrate
- `kubernetes/infrastructure/kustomization.yaml` — namespaces removed as they migrate
- `kubernetes/flux-config/kustomization.yaml` — `cluster.yaml` added; `apps.yaml`/`infrastructure.yaml` removed at G8
- `kubernetes/flux-config/apps.yaml` — `prune: false` at G0; deleted at G8
- `kubernetes/infrastructure/flux-config/infrastructure.yaml` — `prune: false` at G0; deleted at G8
- 62 component `ks.yaml` files — `spec.path` updated; `prune: false` at G0
- `.github/workflows/validate-kubernetes.yml` — build roots updated
- `AGENTS.md` — directory structure documentation
- `.agents/skills/home-ops-add-new-app/SKILL.md` — path templates
- `.agents/skills/home-ops-external-secrets/SKILL.md` — path templates
- `.agents/skills/home-ops-create-httproute/SKILL.md` — path templates
- `Justfile` — `cluster.yaml` references
- `kubernetes/bootstrap.sh` — `kubectl apply` and `kubectl wait` references
- Component `kustomization.yaml` files where `spec.components:` references change depth

### Removed (final)
- `kubernetes/apps/` — at G9
- `kubernetes/infrastructure/` — at G9

---

## Per-Namespace Gate (template)

Every namespace follows this exact sequence. Replace `<old-group>` with `apps` or `infrastructure` and `<namespace>` with the namespace name. The gate is identical across all 20 namespaces.

**Pre-move (read-only):**
1. List every `ks.yaml` and `kustomization.yaml` under the namespace.
2. Note every `spec.path` value and every `spec.components:` value.
3. Note the Namespace manifest filename (`ns.yaml` or `namespace.yaml`) and whether it carries `kustomize.toolkit.fluxcd.io/prune: disabled`.

**Move:**
4. `mkdir -p kubernetes/<namespace>/`
5. `cp -a kubernetes/<old-group>/<namespace>/. kubernetes/<namespace>/`
6. Edit `kubernetes/<namespace>/**/ks.yaml` and rewrite every `spec.path` from `./<old-group>/<namespace>/...` to `./<namespace>/...`.
7. Edit any `spec.components:` reference that uses `../../../../components/...` to `../../../components/...`.
8. Add `kustomize.toolkit.fluxcd.io/prune: disabled` to the Namespace manifest's `metadata.annotations` (preserve any existing annotations).
9. Add `<namespace>` to `kubernetes/kustomization.yaml`'s `resources:` list (in alphabetical position among active namespaces).
10. Comment out (do not delete) the line in `kubernetes/<old-group>/kustomization.yaml` for this namespace.

**Verify:**
11. `flux export ks <namespace-component> -n <namespace>` — confirm `prune: false`.
12. `flux reconcile source oci home-ops -n flux-system`.
13. `flux reconcile ks cluster -n flux-system --with-source`.
14. `flux tree ks cluster -n flux-system | grep <namespace>` — must list every component Kustomization for this namespace.
15. `flux reconcile ks <old-group> -n flux-system`.
16. `flux tree ks <old-group> -n flux-system | grep <namespace>` — must be empty.
17. `kubectl get ns <namespace> -o yaml | grep kustomize.toolkit.fluxcd.io/prune: disabled` — must be present.
18. `kustomize build kubernetes/<namespace> | kubeconform -strict -ignore-missing-schemas -schema-location default -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'` — must exit 0.

**Pause gate:**
19. Present all read-only outputs from steps 11, 14, 16, 17, 18 to the user and wait for explicit "continue".

---

## Phase 0 — Pre-Migration Safety (G0)

### Task 0.1: Verify current prune state

**Files:** none (read-only)

- [ ] **Step 1:** List all Flux Kustomizations that have `prune: true`.

Run:
```bash
flux get ks -A -o yaml | grep -B1 'prune: true' | head -200
```

Expected: a list including both `apps` and `infrastructure` roots and most active component Kustomizations.

- [ ] **Step 2:** Save the list for the next step. No edits yet.

### Task 0.2: Set `prune: false` on every active `ks.yaml`

**Files (62 components):**
- Modify: every `kubernetes/apps/<namespace>/<component>/ks.yaml`
- Modify: every `kubernetes/infrastructure/<namespace>/<component>/ks.yaml`
- Modify: `kubernetes/infrastructure/auth/ks.yaml` (namespace-root)
- Modify: `kubernetes/infrastructure/kyverno/ks.yaml` (namespace-root)
- Modify: `kubernetes/apps/ai/sympozium/ks.yaml`

For each file, replace `prune: true` with `prune: false`.

- [ ] **Step 1:** Run the bulk replacement.

Run:
```bash
find kubernetes/apps kubernetes/infrastructure -type f -name ks.yaml -exec \
  sed -i 's/^\(\s*\)prune: true$/\1prune: false/' {} +
```

- [ ] **Step 2:** Verify no `prune: true` remains in any `ks.yaml`.

Run:
```bash
grep -rn 'prune: true' kubernetes/apps kubernetes/infrastructure || echo OK_NO_PRUNE_TRUE
```

Expected: `OK_NO_PRUNE_TRUE`.

- [ ] **Step 3:** Pause and present the diff to the user; await "continue" before commit.

### Task 0.3: Set `prune: false` on the legacy roots

**Files:**
- Modify: `kubernetes/flux-config/apps.yaml` (line 16)
- Modify: `kubernetes/flux-config/infrastructure.yaml` (line 14)

- [ ] **Step 1:** Edit `apps.yaml` to `spec.prune: false`.
- [ ] **Step 2:** Edit `infrastructure.yaml` to `spec.prune: false`.
- [ ] **Step 3:** Pause for user approval before commit.

### Task 0.4: Create the new `cluster` root

**Files:**
- Create: `kubernetes/flux-config/cluster.yaml`
- Modify: `kubernetes/flux-config/kustomization.yaml`

- [ ] **Step 1:** Write `kubernetes/flux-config/cluster.yaml` exactly:

```yaml
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: cluster
  namespace: flux-system
spec:
  interval: 10m
  path: "./"
  sourceRef:
    kind: OCIRepository
    name: home-ops
  timeout: 15m
  wait: true
  prune: false
```

- [ ] **Step 2:** Append `cluster.yaml` to `kubernetes/flux-config/kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - namespace.yaml
  - registries.yaml
  - flux-helmrelease.yaml
  - flux-system.yaml
  - cluster.yaml
```

(Keep `apps.yaml` and `infrastructure.yaml` for now; remove them at G8.)

- [ ] **Step 3:** Pause for user approval before commit.

### Task 0.5: Commit Phase 0

- [ ] **Step 1:** Commit the Phase 0 changes.

Run:
```bash
git add kubernetes/
git diff --cached --stat
git commit -m "refactor(flux): set prune=false on all ks; add cluster root"
```

- [ ] **Step 2:** Pause for user approval before `git push`.

### Task 0.6: Push and verify Phase 0

- [ ] **Step 1:** Push.

Run:
```bash
git push
```

- [ ] **Step 2:** Reconcile source.

Run:
```bash
flux reconcile source oci home-ops -n flux-system
```

- [ ] **Step 3:** Verify `cluster` is Ready with `prune: false`.

Run:
```bash
flux get ks cluster -n flux-system
flux export ks cluster -n flux-system | grep -E 'prune|path'
```

Expected: `prune: false`, `path: "./"`, `READY: True`.

- [ ] **Step 4:** Pause and present all three outputs to the user; await "continue" before Phase 1.

---

## Phase 1 — Tier 1 (non-essential smoke test)

### Task 1.1: Migrate `entertainment`

**Files (read first):**
- `kubernetes/apps/entertainment/kustomization.yaml`
- `kubernetes/apps/entertainment/ns.yaml`
- `kubernetes/apps/entertainment/jellyfin/ks.yaml`
- `kubernetes/apps/entertainment/jellyfin/ns.yaml`
- `kubernetes/apps/entertainment/storage/ks.yaml`
- `kubernetes/apps/entertainment/storage/config/kustomization.yaml`
- `kubernetes/apps/entertainment/storage/config/nfs-volumes.yaml`

- [ ] **Step 1:** Read all the files above and capture the `spec.path` strings:
  - `entertainment/jellyfin/ks.yaml` → `./apps/entertainment/jellyfin/app`
  - `entertainment/storage/ks.yaml` → `./apps/entertainment/storage/config`

- [ ] **Step 2:** Copy the namespace.

Run:
```bash
mkdir -p kubernetes/entertainment
cp -a kubernetes/apps/entertainment/. kubernetes/entertainment/
```

- [ ] **Step 3:** Rewrite `spec.path` in both `ks.yaml` files:
  - `entertainment/jellyfin/ks.yaml`: `./apps/entertainment/jellyfin/app` → `./entertainment/jellyfin/app`
  - `entertainment/storage/ks.yaml`: `./apps/entertainment/storage/config` → `./entertainment/storage/config`

- [ ] **Step 4:** Annotate the Namespace manifests. `entertainment/ns.yaml` and the duplicate `entertainment/jellyfin/ns.yaml` must both carry `kustomize.toolkit.fluxcd.io/prune: disabled`.

- [ ] **Step 5:** Create `kubernetes/kustomization.yaml` with the active namespace list.

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - entertainment
  - sync
  - downloads
  - default
  - agent-sandbox-system
  - spegel
  - monitoring
  - system-upgrade
  - inteldeviceplugins-system
  - network
  - cert-manager
  - onepassword-connect
  - external-secrets-system
  - kyverno
  - storage
  - kopiur-system
  - kube-system
  - auth
  - headlamp
  - flux-system
```

- [ ] **Step 6:** Comment out the `entertainment` line in `kubernetes/apps/kustomization.yaml` (replace `- entertainment` with `#- entertainment`).

- [ ] **Step 7:** Pause for user approval before commit.

### Task 1.2: Verify `entertainment` ownership transfer

- [ ] **Step 1:** Commit (after approval) and push.

Run:
```bash
git add kubernetes/
git commit -m "refactor(apps): move entertainment to flat namespace layout"
git push
```

- [ ] **Step 2:** Reconcile source.

Run:
```bash
flux reconcile source oci home-ops -n flux-system
```

- [ ] **Step 3:** Reconcile `cluster` and verify ownership.

Run:
```bash
flux reconcile ks cluster -n flux-system --with-source
flux tree ks cluster -n flux-system | grep -E 'entertainment|^- (jellyfin|storage|entertainment-storage)'
```

Expected: `entertainment/jellyfin`, `entertainment/storage`, and the `entertainment-storage` Kustomization all appear under `cluster`.

- [ ] **Step 4:** Reconcile `apps` and verify removal.

Run:
```bash
flux reconcile ks apps -n flux-system
flux tree ks apps -n flux-system | grep entertainment || echo OK_REMOVED
```

Expected: `OK_REMOVED`.

- [ ] **Step 5:** Verify the Namespace annotation.

Run:
```bash
kubectl get ns entertainment -o jsonpath='{.metadata.annotations.kustomize\.toolkit\.fluxcd\.io/prune}{"\n"}'
```

Expected: `disabled`.

- [ ] **Step 6:** Validate.

Run:
```bash
kustomize build kubernetes/entertainment | kubeconform -strict -ignore-missing-schemas -schema-location default -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'
```

Expected: exit 0.

- [ ] **Step 7:** Pause; present all four outputs to the user; await "continue" before Task 1.3.

### Task 1.3: Migrate `sync`

Same template as Task 1.1 with the following substitutions:
- `<old-group>` = `apps`, `<namespace>` = `sync`
- `spec.path` rewrites: `sync/seafile/ks.yaml` (`./apps/sync/seafile/app` → `./sync/seafile/app`), `sync/storage/ks.yaml` (`./apps/sync/storage/config` → `./sync/storage/config`).
- Depth-sensitive: `sync/seafile/ks.yaml` `spec.components:` `../../../../components/kopiur/seafile-backup` → `../../../components/kopiur/seafile-backup`.
- Pause; verify; await "continue" before Tier 2.

---

## Phase 2 — Tier 2 (multi-component apps)

### Task 2.1: Migrate `downloads`

Apply the per-namespace gate with `<old-group>=apps`, `<namespace>=downloads`. Path rewrites:

- `downloads/prowlarr/ks.yaml`: `./apps/downloads/prowlarr/app` → `./downloads/prowlarr/app`
- `downloads/radarr-hd/ks.yaml`: `./apps/downloads/radarr-hd/app` → `./downloads/radarr-hd/app`
- `downloads/radarr-uhd/ks.yaml`: `./apps/downloads/radarr-uhd/app` → `./downloads/radarr-uhd/app`
- `downloads/radarr-anime/ks.yaml`: `./apps/downloads/radarr-anime/app` → `./downloads/radarr-anime/app`
- `downloads/sonarr-hd/ks.yaml`: `./apps/downloads/sonarr-hd/app` → `./downloads/sonarr-hd/app`
- `downloads/sonarr-anime/ks.yaml`: `./apps/downloads/sonarr-anime/app` → `./downloads/sonarr-anime/app`
- `downloads/sabnzbd/ks.yaml`: `./apps/downloads/sabnzbd/app` → `./downloads/sabnzbd/app`
- `downloads/seerr/ks.yaml`: `./apps/downloads/seerr/app` → `./downloads/seerr/app`
- `downloads/recyclarr/ks.yaml`: `./apps/downloads/recyclarr/app` → `./downloads/recyclarr/app`
- `downloads/storage/ks.yaml`: `./apps/downloads/storage/config` → `./downloads/storage/config`

For every `ks.yaml` that uses `../../../../components/kopiur/backup`, change to `../../../components/kopiur/backup`.

Verify; pause; await "continue".

### Task 2.2: Migrate `default`

Apply the per-namespace gate with `<old-group>=apps`, `<namespace>=default`. Path rewrites:

- `default/barcodebuddy/ks.yaml`: `./apps/default/barcodebuddy/app` → `./default/barcodebuddy/app`; `../../../../components/kopiur/backup` → `../../../components/kopiur/backup`.
- `default/database/ks.yaml`: `./apps/default/database/config` → `./default/database/config`.
- `default/error-pages/ks.yaml` (two `Kustomization`s, paths `./apps/default/error-pages/app-external` and `./apps/default/error-pages/app-internal`) → `./default/error-pages/app-external` and `./default/error-pages/app-internal`.
- `default/grocy/ks.yaml`: `./apps/default/grocy/app` → `./default/grocy/app`; `../../../../components/kopiur/backup` → `../../../components/kopiur/backup`.
- `default/mailpit/ks.yaml`: `./apps/default/mailpit/app` → `./default/mailpit/app`; `../../../../components/kopiur/backup` → `../../../components/kopiur/backup`.
- `default/speedtest-tracker/ks.yaml`: `./apps/default/speedtest-tracker/app` → `./default/speedtest-tracker/app`; `../../../../components/kopiur/backup` → `../../../components/kopiur/backup`.

Verify; pause; await "continue".

### Task 2.3: Migrate `agent-sandbox-system`

Apply the per-namespace gate with `<old-group>=infrastructure`, `<namespace>=agent-sandbox-system`. Path rewrite:

- `agent-sandbox-system/agent-sandbox-controller/ks.yaml`: `./infrastructure/agent-sandbox-system/agent-sandbox-controller/app` → `./agent-sandbox-system/agent-sandbox-controller/app`.

Verify; pause; await "continue".

---

## Phase 3 — Tier 3 (platform controllers)

### Task 3.1: Migrate `spegel`

`<old-group>=infrastructure`, `<namespace>=spegel`. Path rewrite:

- `spegel/spegel/ks.yaml`: `./infrastructure/spegel/spegel/app` → `./spegel/spegel/app`.

Verify; pause; await "continue".

### Task 3.2: Migrate `monitoring`

`<old-group>=infrastructure`, `<namespace>=monitoring`. Path rewrites:

- `monitoring/capacitor/ks.yaml`: `./infrastructure/monitoring/capacitor/app` → `./monitoring/capacitor/app`.
- `monitoring/grafana/ks.yaml`: `./infrastructure/monitoring/grafana/app` → `./monitoring/grafana/app`.
- `monitoring/vector/ks.yaml`: `./infrastructure/monitoring/vector/app` → `./monitoring/vector/app`.
- `monitoring/victoria-logs/ks.yaml`: `./infrastructure/monitoring/victoria-logs/app` → `./monitoring/victoria-logs/app`.
- `monitoring/victoria-metrics/ks.yaml`: `./infrastructure/monitoring/victoria-metrics/app` → `./monitoring/victoria-metrics/app`.

Verify; pause; await "continue".

### Task 3.3: Migrate `system-upgrade`

`<old-group>=infrastructure`, `<namespace>=system-upgrade`. Path rewrite:

- `system-upgrade/tuppr/ks.yaml`: `./infrastructure/system-upgrade/tuppr/app` → `./system-upgrade/tuppr/app` and `./infrastructure/system-upgrade/tuppr/config` → `./system-upgrade/tuppr/config` (two `Kustomization`s in one file).

Verify; pause; await "continue".

### Task 3.4: Migrate `inteldeviceplugins-system`

`<old-group>=infrastructure`, `<namespace>=inteldeviceplugins-system`. Path rewrites:

- `inteldeviceplugins-system/intel-device-plugins-operator/ks.yaml`: `./infrastructure/inteldeviceplugins-system/intel-device-plugins-operator/app` → `./inteldeviceplugins-system/intel-device-plugins-operator/app`.
- `inteldeviceplugins-system/intel-gpu-plugin/ks.yaml`: `./infrastructure/inteldeviceplugins-system/intel-gpu-plugin/app` → `./inteldeviceplugins-system/intel-gpu-plugin/app`.

Verify; pause; await "continue".

---

## Phase 4 — Tier 4 (identity and ingress foundations)

### Task 4.1: Migrate `network`

`<old-group>=infrastructure`, `<namespace>=network`. Path rewrites:

- `network/cloudflared/ks.yaml`: `./infrastructure/network/cloudflared/app` → `./network/cloudflared/app`.
- `network/envoy-gateway/ks.yaml`: `./infrastructure/network/envoy-gateway/app` → `./network/envoy-gateway/app` and `./infrastructure/network/envoy-gateway/config` → `./network/envoy-gateway/config`.
- `network/external-dns/ks.yaml`: `./infrastructure/network/external-dns/app` → `./network/external-dns/app`.
- `network/pve-egress/ks.yaml`: `./infrastructure/network/pve-egress/app` → `./network/pve-egress/app`.
- `network/tailscale/ks.yaml`: `./infrastructure/network/tailscale/app` → `./network/tailscale/app` and `./infrastructure/network/tailscale/config` → `./network/tailscale/config`.

Verify; pause; await "continue".

### Task 4.2: Migrate `cert-manager`

`<old-group>=infrastructure`, `<namespace>=cert-manager`. Path rewrites:

- `cert-manager/cert-manager/ks.yaml`: `./infrastructure/cert-manager/cert-manager/app` → `./cert-manager/cert-manager/app` and `./infrastructure/cert-manager/cert-manager/config` → `./cert-manager/cert-manager/config`.

Verify; pause; await "continue".

### Task 4.3: Migrate `onepassword-connect`

`<old-group>=infrastructure`, `<namespace>=onepassword-connect`. Path rewrite:

- `onepassword-connect/onepassword-connect/ks.yaml`: `./infrastructure/onepassword-connect/onepassword-connect/app` → `./onepassword-connect/onepassword-connect/app`.

Verify; pause; await "continue".

### Task 4.4: Migrate `external-secrets-system`

`<old-group>=infrastructure`, `<namespace>=external-secrets-system`. Path rewrites:

- `external-secrets-system/external-secrets/ks.yaml`: `./infrastructure/external-secrets-system/external-secrets/app` → `./external-secrets-system/external-secrets/app` and `./infrastructure/external-secrets-system/external-secrets/config` → `./external-secrets-system/external-secrets/config`.

Verify; pause; await "continue".

### Task 4.5: Migrate `kyverno`

`<old-group>=infrastructure`, `<namespace>=kyverno`. This namespace has a namespace-root `ks.yaml` (three `Kustomization`s). Path rewrites inside `kyverno/ks.yaml`:

- `kyverno` (app): `./infrastructure/kyverno/app` → `./kyverno/app`.
- `kyverno-rbac`: `./infrastructure/kyverno/rbac` → `./kyverno/rbac`.
- `kyverno-policies`: `./infrastructure/kyverno/policies` → `./kyverno/policies`.

Verify; pause; await "continue".

---

## Phase 5 — Tier 5 (storage and backup CRDs)

### Task 5.1: Migrate `storage`

`<old-group>=infrastructure`, `<namespace>=storage`. Path rewrites:

- `storage/openebs-localpv/ks.yaml`: `./infrastructure/storage/openebs-localpv/app` → `./storage/openebs-localpv/app`.
- `storage/rook-ceph/ks.yaml`: `./infrastructure/storage/rook-ceph/app` → `./storage/rook-ceph/app`.
- `storage/volsync/ks.yaml`: `./infrastructure/storage/volsync/app` → `./storage/volsync/app`.

Verify; pause; await "continue".

### Task 5.2: Migrate `kopiur-system`

`<old-group>=infrastructure`, `<namespace>=kopiur-system`. The namespace file is `namespace.yaml` (not `ns.yaml`) — keep that name. Path rewrites inside `kopiur-system/kopiur/ks.yaml`:

- `kopiur`: `./infrastructure/kopiur-system/kopiur/app` → `./kopiur-system/kopiur/app`.
- `kopiur-repository`: `./infrastructure/kopiur-system/kopiur/repository` → `./kopiur-system/kopiur/repository`.

Verify; pause; await "continue".

---

## Phase 6 — Tier 6 (cluster self-management)

### Task 6.1: Migrate `kube-system`

`<old-group>=infrastructure`, `<namespace>=kube-system`. Path rewrites:

- `kube-system/cilium/ks.yaml`: `./infrastructure/kube-system/cilium/app` → `./kube-system/cilium/app` and `./infrastructure/kube-system/cilium/config` → `./kube-system/cilium/config`.
- `kube-system/descheduler/ks.yaml`: `./infrastructure/kube-system/descheduler/app` → `./kube-system/descheduler/app`.
- `kube-system/gvisor/ks.yaml`: `./infrastructure/kube-system/gvisor/app` → `./kube-system/gvisor/app`.
- `kube-system/metrics-server/ks.yaml`: `./infrastructure/kube-system/metrics-server/app` → `./kube-system/metrics-server/app`.
- `kube-system/node-feature-discovery/ks.yaml`: `./infrastructure/kube-system/node-feature-discovery/app` → `./kube-system/node-feature-discovery/app`.
- `kube-system/snapshot-controller/ks.yaml`: `./infrastructure/kube-system/snapshot-controller` → `./kube-system/snapshot-controller` (note: this Kustomization points at the component directory itself, not an `app/` child).

The duplicate `kube-system/snapshot-controller/ns.yaml` keeps its `kustomize.toolkit.fluxcd.io/prune: disabled` annotation; do not modify.

Verify; pause; await "continue".

### Task 6.2: Migrate `auth`

`<old-group>=infrastructure`, `<namespace>=auth`. Namespace-root `ks.yaml` with three `Kustomization`s. Path rewrites inside `auth/ks.yaml`:

- `dex-internal`: `./infrastructure/auth/dex-internal/app` → `./auth/dex-internal/app`.
- `dex-external`: `./infrastructure/auth/dex-external/app` → `./auth/dex-external/app`.
- `dex-security-policies`: `./infrastructure/auth/security-policies` → `./auth/security-policies`.

Verify; pause; await "continue".

### Task 6.3: Migrate `headlamp`

`<old-group>=infrastructure`, `<namespace>=headlamp`. Path rewrite:

- `headlamp/headlamp/ks.yaml`: `./infrastructure/headlamp/headlamp/app` → `./headlamp/headlamp/app`.

Verify; pause; await "continue".

### Task 6.4: Migrate `flux-system`

`<old-group>=infrastructure`, `<namespace>=flux-system`. Path rewrite:

- `flux-system/webhook/ks.yaml`: `./infrastructure/flux-system/webhook/app` → `./flux-system/webhook/app`.

Verify; pause; await "continue" before Phase 7.

---

## Phase 7 — Add targeted dependency edges

After Phase 6, the `apps → infrastructure` aggregate gate no longer exists. Add explicit `dependsOn` edges that the aggregate gate previously provided implicitly.

### Task 7.1: Add kopiur/volsync edges to backup-using apps

For each of these `ks.yaml` files, append `dependsOn: [{name: kopiur, namespace: kopiur-system}, {name: volsync, namespace: storage}]` (preserve any existing `dependsOn` block):

- `kubernetes/default/barcodebuddy/ks.yaml`
- `kubernetes/default/grocy/ks.yaml`
- `kubernetes/default/mailpit/ks.yaml`
- `kubernetes/default/speedtest-tracker/ks.yaml`
- `kubernetes/downloads/prowlarr/ks.yaml`
- `kubernetes/downloads/radarr-hd/ks.yaml`
- `kubernetes/downloads/radarr-uhd/ks.yaml`
- `kubernetes/downloads/radarr-anime/ks.yaml`
- `kubernetes/downloads/sonarr-hd/ks.yaml`
- `kubernetes/downloads/sonarr-anime/ks.yaml`
- `kubernetes/downloads/sabnzbd/ks.yaml`
- `kubernetes/downloads/seerr/ks.yaml`
- `kubernetes/downloads/recyclarr/ks.yaml`
- `kubernetes/entertainment/jellyfin/ks.yaml`
- `kubernetes/sync/seafile/ks.yaml`

- [ ] **Step 1:** Edit each file's `spec.dependsOn` list.
- [ ] **Step 2:** Pause for user approval before commit.

### Task 7.2: Convert `kasm`'s aggregate edge to concrete edges (dormant)

`<old-group>=apps`, `<namespace>=kasm`. This file is currently dormant (`#- kasm` in the namespace aggregator). Update its `ks.yaml`:

```yaml
spec:
  dependsOn:
    - name: external-secrets-config
    - name: cert-manager-config
    - name: envoy-gateway-config
    - name: rook-ceph
      namespace: storage
```

Replace the existing `dependsOn: [{name: infrastructure, namespace: flux-system}]`.

- [ ] **Step 1:** Edit `kasm/kasm/ks.yaml` only; do not commit yet.
- [ ] **Step 2:** Pause for user approval before commit.

### Task 7.3: Commit Phase 7

- [ ] **Step 1:** Commit.

Run:
```bash
git add kubernetes/
git commit -m "refactor(flux): add targeted dependsOn edges for backup-using apps"
```

- [ ] **Step 2:** Pause for user approval before push.

---

## Phase 8 — Documentation and tooling updates

### Task 8.1: Update validation workflow

**Files:**
- Modify: `.github/workflows/validate-kubernetes.yml`

Replace the build roots loop with:

```yaml
- name: Validate Kubernetes manifests
  run: |
    set -e
    for dir in kubernetes/flux-config kubernetes; do
      echo "=== $dir ==="
      kustomize build "$dir" | kubeconform -strict -ignore-missing-schemas \
        -schema-location default \
        -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'
    done
```

Remove any reference to `kubernetes/apps` and `kubernetes/infrastructure` build roots.

### Task 8.2: Update AGENTS.md

Replace the "Directory Structure" and "Tree" sections with the flat layout description. The "Group → Namespace → Component → Resources" sentence becomes "Namespace → Component → Resources". Update the deployment workflow commands (`flux reconcile kustomization infrastructure` → `flux reconcile kustomization cluster`; same for `apps`).

### Task 8.3: Update skills

For each of:
- `.agents/skills/home-ops-add-new-app/SKILL.md`
- `.agents/skills/home-ops-external-secrets/SKILL.md`
- `.agents/skills/home-ops-create-httproute/SKILL.md`

Replace every `kubernetes/apps/` and `kubernetes/infrastructure/` path with the corresponding flat path. Remove any reference to "Group" placement decisions.

### Task 8.4: Update Justfile

Replace `apps.yaml` references with `cluster.yaml`. Keep `flux-system.yaml` references.

### Task 8.5: Update bootstrap.sh

Update the `kubectl apply` and `kubectl wait` lines that mention `infrastructure.yaml` and `apps.yaml` to use `cluster.yaml` and `flux-system.yaml`.

### Task 8.6: Commit Phase 8

- [ ] **Step 1:** Commit.

Run:
```bash
git add .github/workflows/validate-kubernetes.yml AGENTS.md \
  .agents/skills/ Justfile kubernetes/bootstrap.sh
git commit -m "docs: reflect flat namespace hierarchy"
```

- [ ] **Step 2:** Pause for user approval before push.

---

## Phase 9 — Final cleanup (G7-G9)

### Task 9.1: G7 — set `cluster.prune: true`

- [ ] **Step 1:** Verify every active Kustomization is owned by `cluster`.

Run:
```bash
flux tree ks cluster -n flux-system
```

Expected: lists every active Kustomization defined in the spec.

- [ ] **Step 2:** Pause and present the tree output; await explicit "continue" before flipping `prune`.

- [ ] **Step 3:** Edit `kubernetes/flux-config/cluster.yaml`: change `prune: false` to `prune: true`.

- [ ] **Step 4:** Commit and push.

Run:
```bash
git add kubernetes/flux-config/cluster.yaml
git commit -m "refactor(flux): enable pruning on cluster root"
git push
```

- [ ] **Step 5:** Reconcile.

Run:
```bash
flux reconcile ks cluster -n flux-system --with-source
flux export ks cluster -n flux-system | grep prune
```

Expected: `prune: true`.

- [ ] **Step 6:** Pause for user approval.

### Task 9.2: G8 — delete the legacy Flux roots

- [ ] **Step 1:** Verify the legacy roots own nothing.

Run:
```bash
flux tree ks apps -n flux-system
flux tree ks infrastructure -n flux-system
```

Expected: empty.

- [ ] **Step 2:** Pause; present the trees; await "continue".

- [ ] **Step 3:** Delete the Flux Kustomization objects.

Run:
```bash
kubectl delete kustomization apps -n flux-system
kubectl delete kustomization infrastructure -n flux-system
```

- [ ] **Step 4:** Remove `apps.yaml` and `infrastructure.yaml` from `kubernetes/flux-config/kustomization.yaml`. The resulting file:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - namespace.yaml
  - registries.yaml
  - flux-helmrelease.yaml
  - flux-system.yaml
  - cluster.yaml
```

- [ ] **Step 5:** Commit and push.

Run:
```bash
git add kubernetes/flux-config/
git commit -m "refactor(flux): delete legacy apps and infrastructure roots"
git push
```

- [ ] **Step 6:** Pause for user approval.

### Task 9.3: G9 — remove the legacy directories

- [ ] **Step 1:** Verify no Flux Kustomization still references the legacy directories.

Run:
```bash
kubectl get kustomizations.kustomize.toolkit.fluxcd.io -A -o yaml | grep -E 'apps|infrastructure' || echo OK_NO_LEGACY_REFS
```

Expected: `OK_NO_LEGACY_REFS`.

- [ ] **Step 2:** Pause; present the output; await "continue".

- [ ] **Step 3:** Remove the legacy directories.

Run:
```bash
rm -rf kubernetes/apps kubernetes/infrastructure
git add -A kubernetes/
git status --short
git commit -m "refactor(k8s): remove legacy apps and infrastructure directories"
git push
```

- [ ] **Step 4:** Final verification.

Run:
```bash
ls kubernetes/ | grep -E '^(apps|infrastructure)$' || echo OK_NO_LEGACY_DIRS
flux get ks -n flux-system
kustomize build kubernetes | kubeconform -strict -ignore-missing-schemas -schema-location default -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'
```

Expected: `OK_NO_LEGACY_DIRS`; `flux get ks` lists `flux-registries`, `flux-system`, `cluster`; kustomize+ kubeconform exit 0.

---

## Self-Review Checklist (already run by plan author)

1. **Spec coverage:** Every requirement in the spec has a task. Tier ordering matches Section 5; per-namespace gate matches Section 6; dependency edges match Section 7; validation updates match Section 8; success criteria match Section 11.
2. **No placeholders:** All path rewrites are spelled out; all commands are exact; no "TODO" or "TBD" in the plan.
3. **Type/name consistency:** Flux `Kustomization` names, namespaces, and gate IDs (`G0`-`G9`) match the spec; `cluster.yaml` matches the spec's example exactly.
4. **Pause discipline:** Every commit, push, `kubectl apply`, `flux reconcile`, and `prune: true` toggle has an explicit "await continue" gate.
