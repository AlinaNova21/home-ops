# Flatten the Kubernetes hierarchy into a single tree

- **Date:** 2026-07-22
- **Status:** Draft, pending user review
- **Owner:** home-ops maintainers

## 1. Problem

The `kubernetes/` directory currently uses a two-level top structure that
separates workloads by category:

```text
kubernetes/apps/<namespace>/<component>/
kubernetes/infrastructure/<namespace>/<component>/
```

A single Flux `Kustomization/apps` reconciles everything below
`kubernetes/apps/` and depends on `Kustomization/infrastructure`. The split
between `apps` and `infrastructure` is purely organizational; the namespaces
themselves are disjoint and the only durable ordering guarantee between the two
groups is the single `dependsOn: [infrastructure]` edge on the `apps` root.

The two-level layout has three operational costs:

1. **Hidden ordering risk.** Every `apps/` component that uses
   `components/kopiur/backup` or `ceph-rbd` PVCs relies on the
   `apps → infrastructure` aggregate gate as an implicit barrier for the
   Kopiur, VolSync, Rook-Ceph, ExternalSecrets, Envoy Gateway, and
   cert-manager CRDs/controllers. Removing the gate without adding targeted
   edges would let cold-start reconciliations race against CRDs that have not
   yet been installed.
2. **Path churn.** New components must invent a `path:` string that includes
   both the group directory and the namespace, e.g.
   `./apps/default/barcodebuddy/app` or
   `./infrastructure/network/envoy-gateway/config`. The skill files in
   `.agents/skills/` reproduce these paths verbatim, so every contributor has
   to know whether a workload is "app" or "infrastructure".
3. **Asymmetry.** The boundary is informal. `kube-system`, `kopiur-system`,
   `flux-system`, and `cnpg-system` use the `-system` suffix; `auth`,
   `headlamp`, `monitoring`, `network`, and `storage` do not. There is no
   documentable rule for "which group does this namespace belong to", only
   history.

The goal of this design is to flatten `apps/` and `infrastructure/` into one
tree rooted at `kubernetes/<namespace>/<component>/`, replacing the two Flux
roots with a single `cluster` root, while preserving the Flux ownership
transfer protocol that the Flux migration guides require.

## 2. Target layout

```text
kubernetes/
├── kustomization.yaml                  # NEW: namespace aggregator (active list)
├── <namespace>/                        # e.g. downloads, network, kube-system
│   ├── ns.yaml                         # REQUIRED
│   ├── kustomization.yaml              # REQUIRED: ns.yaml + component ks.yaml
│   └── <component>/
│       ├── ks.yaml                     # Flux Kustomization (prune: false during migration)
│       └── app/ | config/ | repository/
└── flux-config/
    ├── kustomization.yaml              # adds cluster.yaml; keeps flux-system.yaml
    └── cluster.yaml                    # NEW: replaces apps.yaml + infrastructure.yaml
```

`kubernetes/apps/` and `kubernetes/infrastructure/` directories are removed in
the final cleanup commit. The legacy roots are not deleted until ownership
transfer is fully verified (Section 6).

`kubernetes/components/` stays at `kubernetes/components/`. Every
`spec.components:` reference that currently uses `../../../../components/...`
shortens by two `../` segments.

## 3. Flux ownership model

A single Flux `Kustomization/cluster` reconciles `./` from the same
`OCIRepository/home-ops` source. Configuration:

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
  prune: false                # until G7
```

The new `kubernetes/kustomization.yaml` lists only the namespaces currently
included in `apps/kustomization.yaml` or `infrastructure/kustomization.yaml`,
preserving all comments so that commented-out namespaces remain disabled
exactly as today.

Component `Kustomization` names, namespaces, and `metadata.namespace` values
are unchanged. Only `spec.path` and any depth-sensitive `components:` paths
change.

## 4. Pruning protocol (binding)

Per the Flux migration guides, **no `prune: true` is set on any Kustomization
during the migration.** Every Kustomization involved in the migration runs
with `prune: false` from the first commit until the user explicitly
authorizes the final re-enable.

Concretely:

1. **G0 — pre-migration.** Every active `ks.yaml` in `apps/` and
   `infrastructure/` is updated to `spec.prune: false` in a single commit.
   The legacy `apps` and `infrastructure` Flux roots also become
   `prune: false`. The new `cluster` root is created with `prune: false`.
2. **During migration.** Every new and moved `ks.yaml` keeps `prune: false`.
   Every Namespace manifest carries the
   `kustomize.toolkit.fluxcd.io/prune: disabled` annotation as a
   belt-and-suspenders safeguard.
3. **Verification gate (per namespace, per the Flux guide):**
   - `flux export ks <old-owner>` — confirm pruning is disabled in-cluster.
   - Move the namespace directory and update `spec.path`.
   - `flux reconcile ks cluster -n flux-system`.
   - `flux tree ks cluster -n flux-system` — confirm the namespace's
     Kustomizations appear under `cluster`.
   - `flux reconcile ks <old-owner>` — confirm the namespace no longer
     appears under the legacy root (`flux tree ks <old-owner>`).
   - `kubectl get ns <namespace> -o yaml` — confirm the prune-disabled
     annotation is present on the Namespace object.
4. **G7 — final re-enable.** Only after every active Kustomization has been
   individually verified with `flux tree`, the user explicitly authorizes
   setting `prune: true` on `cluster`. The legacy roots are deleted in
   the same commit (Section 9).

## 5. Stage ordering (non-essential first)

Active namespaces are migrated in six tiers. Within each tier, namespaces are
listed in the order they will be moved. Each line is a separate pause gate.

### Tier 1 — non-essential smoke test

1. `entertainment` — single `jellyfin` HelmRelease + NFS PVCs.
2. `sync` — single `seafile` + dormant `sync-storage`.

### Tier 2 — multi-component apps

3. `downloads` — adds kopiur/volsync/ceph-rbd dependency chain.
4. `default` — apps depend on kopiur/volsync; `speedtest-tracker` also needs
   `default-database`.
5. `agent-sandbox-system` — single HelmRelease, no inbound edges.

### Tier 3 — platform controllers

6. `spegel`.
7. `monitoring` — grafana, vector, victoria-metrics/logs, capacitor.
8. `system-upgrade` — tuppr.
9. `inteldeviceplugins-system`.

### Tier 4 — identity and ingress foundations

10. `network` — envoy-gateway, external-dns, cloudflared, tailscale-operator,
    pve-egress.
11. `cert-manager`.
12. `onepassword-connect`.
13. `external-secrets-system`.
14. `kyverno`.

### Tier 5 — storage and backup CRDs

15. `storage` — rook-ceph, openebs-localpv, volsync.
16. `kopiur-system`.

### Tier 6 — cluster self-management (last)

17. `kube-system` — cilium, gvisor, metrics-server, descheduler,
    node-feature-discovery, snapshot-controller. Carries the existing
    `prune: disabled` annotation on the Namespace.
18. `auth` — dex-internal, dex-external, security-policies.
19. `headlamp` — depends on `dex-security-policies`.
20. `flux-system` — webhook receiver. The `flux-system` root Kustomization
    itself is reconciled by `flux-config`, not by the namespace aggregator;
    moving the webhook receiver is the last state-changing namespace step.

## 6. Per-namespace migration gate

Repeated for every namespace, in order:

| Step | Action | Pause gate |
|---|---|---|
| 1 | Read every file in the namespace, list path-sensitive content (`spec.path`, `spec.components`, `kustomization.yaml` references, namespace annotations). | none |
| 2 | `mkdir -p kubernetes/<namespace>/` and `cp -a kubernetes/<old-group>/<namespace>/. kubernetes/<namespace>/`. Old path stays intact. `<old-group>` is `apps` or `infrastructure` per the namespace's current location. | none |
| 3 | Edit every moved `ks.yaml` to point at the new path; fix depth-sensitive `components:` references (each `../../../../components/...` becomes `../../../components/...`). | none |
| 4 | Add `kustomize.toolkit.fluxcd.io/prune: disabled` to the Namespace manifest. | none |
| 5 | Update the new `kubernetes/kustomization.yaml` to include the namespace; comment it out in the old `apps/kustomization.yaml` or `kubernetes/infrastructure/kustomization.yaml`. | none |
| 6 | Commit and push. | gate for this namespace (G1a, G1b, G2a, ...) |
| 7 | `flux reconcile source oci home-ops -n flux-system`. | none |
| 8 | `flux reconcile ks cluster -n flux-system`. | none |
| 9 | `flux tree ks cluster -n flux-system` — confirm ownership. | none |
| 10 | `flux reconcile ks <old-group> -n flux-system` and `flux tree ks <old-group> -n flux-system` — confirm removal under the legacy root. | none |
| 11 | `kubectl get ns <namespace> -o yaml` — confirm the prune-disabled annotation is applied. | none |
| 12 | Present all four read-only outputs to the user. | next gate (await "continue") |

If any step fails, stop and present the failure.

## 7. Targeted dependency edges added at Tier 4+

The existing `apps → infrastructure` aggregate gate is the only ordering
guarantee between the two groups today. After the migration, every workload
must explicitly depend on the controller or configuration Kustomization it
needs. Edges added during the migration:

| Consumer | Edge added | Why |
|---|---|---|
| `barcodebuddy`, `grocy`, `mailpit`, `sabnzbd`, `prowlarr`, `radarr-hd`, `radarr-uhd`, `radarr-anime`, `sonarr-hd`, `sonarr-anime`, `seerr`, `jellyfin`, `seafile`, `speedtest-tracker`, `recyclarr` | `kopiur`, `volsync` | Inline `SnapshotPolicy`/`SnapshotSchedule` need both CRDs. |
| `speedtest-tracker` | `default-database` | Already present, verified post-move. |
| `sabnzbd` | `downloads-storage` | Already present, verified post-move. |
| `recyclarr` | radarr/sonarr siblings | Already present, verified post-move. |
| `n8n` | `external-secrets-config` (already declared) | ClusterSecretStore. |
| `headlamp` | `dex-security-policies` (already declared; verified post-move) | Identity provider gating dashboard login. |
| `kasm` (dormant) | replace `dependsOn: [infrastructure]` with the four concrete deps it actually needs (`external-secrets-config`, `cert-manager-config`, `envoy-gateway-config`, `rook-ceph`). | Aggregate name disappears; this is the only edge that referenced it. |

Edges already declared at the component level (e.g.
`envoy-gateway-config → {envoy-gateway, cert-manager-config}`,
`external-secrets-config → {external-secrets, onepassword-connect}`,
`volsync → rook-ceph`, `recyclarr → radarr-*`, etc.) are verified but not
modified.

## 8. Validation updates

The repository's validation loop must be updated to build the new
`kubernetes/kustomization.yaml` instead of (or in addition to) the two old
aggregator files.

Files to update:

- `.github/workflows/validate-kubernetes.yml` — replace the three build roots
  with `kubernetes/flux-config`, `kubernetes/` (root kustomization), and
  `kubernetes/infrastructure/<each>` removed.
- `AGENTS.md` — Section "Directory Structure" and "Tree" rewritten to
  describe the flat layout. The "Group → Namespace → Component → Resources"
  sentence becomes "Namespace → Component → Resources".
- `.agents/skills/home-ops-add-new-app/SKILL.md` — paths shortened from
  `kubernetes/apps/<namespace>/<component>/...` to
  `kubernetes/<namespace>/<component>/...`.
- `.agents/skills/home-ops-external-secrets/SKILL.md` and
  `home-ops-create-httproute/SKILL.md` — same path simplification.
- `Justfile` — recipes that reference `apps.yaml` and `infrastructure.yaml`
  are updated to reference `cluster.yaml` and `flux-system.yaml`.
- `kubernetes/bootstrap.sh` (lines 80-97, 101-117) — `kubectl apply` of the
  root Flux manifests updated to apply `cluster.yaml` instead of `apps.yaml`
  and `infrastructure.yaml`. `kubectl wait` updated to wait for the
  `cluster` Kustomization.

No `.gitignore`, `.fluxignore`, or `.dockerignore` rules require changes; the
OCI artifact root (`./kubernetes`) is unchanged.

## 9. Pause gates (summary)

| Gate | Description | Verification artifact |
|---|---|---|
| G0 | Set `prune: false` on every active `ks.yaml` and on both legacy roots; create `cluster` root with `prune: false`. | `flux export ks` for every active root showing `prune: false`. |
| G1a | Move `entertainment`. | `flux tree ks cluster` lists entertainment Kustomizations. |
| G1b | Move `sync`. | Same. |
| G2a-G2c | Move `downloads`, `default`, `agent-sandbox-system`. | Same. |
| G3a-G3d | Move `spegel`, `monitoring`, `system-upgrade`, `inteldeviceplugins-system`. | Same. |
| G4a-G4e | Move `network`, `cert-manager`, `onepassword-connect`, `external-secrets-system`, `kyverno`. | Same. |
| G5a-G5b | Move `storage`, `kopiur-system`. | Same. |
| G6a-G6d | Move `kube-system`, `auth`, `headlamp`, `flux-system`. | Same. |
| G7 | Set `cluster.prune: true` (requires explicit user authorization after a positive `flux tree` proof for every active Kustomization). | `flux tree ks cluster` shows every active Kustomization; `flux export ks cluster` shows `prune: true`. |
| G8 | Delete `apps` and `infrastructure` Flux Kustomizations. | `flux get ks -n flux-system` lists only `flux-system`, `flux-registries`, and `cluster`. |
| G9 | Remove legacy `kubernetes/apps/` and `kubernetes/infrastructure/` directories. | `ls kubernetes/` shows no `apps/` or `infrastructure/`. |

Every gate is preceded by a read-only verification step whose output is shown
to the user before the gate's mutating action runs.

## 10. Anomalies preserved (out of scope)

These pre-existing anomalies are preserved exactly during this migration and
will be addressed in a separate change:

- `kubernetes/apps/entertainment/jellyfin/ns.yaml` (duplicate Namespace
  inside a component).
- `kubernetes/apps/ai/sympozium/app/namespace.yaml` (duplicate Namespace).
- `kubernetes/infrastructure/kopiur-system/namespace.yaml` (uses
  `namespace.yaml` filename, intentional due to the `prune: disabled`
  annotation).
- `kubernetes/infrastructure/cnpg-system/ns.yaml` (creates two Namespaces,
  `cnpg-system` and `databases`).
- `kubernetes/infrastructure/kube-system/snapshot-controller/ns.yaml`
  (Namespace declared inside a component folder; carries the `prune:
  disabled` annotation).
- `kubernetes/apps/default/memos/ks.yaml` (dormant; references a nonexistent
  `default-storage` Kustomization).
- `kubernetes/apps/immich/immich/ks.yaml` (dormant; references nonexistent
  `cloudnative-pg-config` Kustomization).
- `kubernetes/infrastructure/auth/ks.yaml` and
  `kubernetes/infrastructure/kyverno/ks.yaml` (namespace-root multi-resource
  `ks.yaml` files; preserved).
- `kubernetes/apps/ai/sympozium/kustomization.yaml` (extra Kustomize wrapper
  layer).
- `kubernetes/scripts/deploy-infrastructure.sh` (contains stale paths not
  aligned with the current layout; unrelated to the flattening).

## 11. Success criteria

- `kubernetes/apps/` and `kubernetes/infrastructure/` no longer exist.
- A single Flux `Kustomization/cluster` reconciles `./kubernetes/` with
  `prune: true` (per user authorization at G7).
- `flux get ks -A` shows no `apps` or `infrastructure` Kustomizations.
- `flux tree ks cluster -n flux-system` lists every active component
  Kustomization.
- `kubectl get ns -o jsonpath='{range .items[*]}{.metadata.name}
  {range .metadata.annotations.kustomize\.toolkit\.fluxcd\.io/prune}{.}{end}
  {end}'` shows the `disabled` annotation on every Namespace that previously
  carried it (kube-system, kopiur-system) and on the Namespaces that gained
  it during the migration.
- `for d in kubernetes/flux-config kubernetes/; do kustomize build "$d" |
  kubeconform -strict -ignore-missing-schemas -schema-location default
  -schema-location
  'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'; done` exits 0.
