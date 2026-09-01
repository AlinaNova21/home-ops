# TOPF Migration Design

**Date:** 2026-09-01
**Status:** Approved (design review)
**Scope:** Migrate the `whoverse` Talos cluster from talhelper to TOPF (Phase 1). 1Password secrets swap is explicitly deferred to Phase 2.

## Background

The `whoverse` Talos cluster is currently managed with [talhelper](https://github.com/budimanjoaro/talhelper): a single `talos/whoverse/talconfig.yaml` drives `talhelper genconfig` → `clusterconfig/*.yaml`, and day-2 operations go through `talhelper gencommand …` wrapped in Justfile recipes.

[TOPF](https://postfinance.github.io/topf/) (Talos Orchestrator by PostFinance) is a newer single-binary alternative that:
- Applies configs directly (`topf apply`) with pre-flight health checks, dry-run diffs, confirmation prompts, and post-apply stabilization — no per-node `talosctl` juggling.
- Builds machine configs from **layered patches** (`all/` → `<role>/` → `node/<host>/`) instead of one monolithic config.
- Handles Talos upgrades with version comparison (only touches nodes that need it).
- Reads secrets through a SOPS → vals two-stage pipeline.

## Goals

1. Migrate `talos/whoverse` from talhelper to TOPF with **no cluster state change** — no secret regeneration, no reset, no apply during the migration itself.
2. Produce machine configs from `topf render` that **semantically match** the currently-generated `clusterconfig/*.yaml`.
3. Replace the talhelper Justfile recipes with TOPF-native equivalents (or remove them where they map 1:1).
4. Update `talos/AGENTS.md` and `.sops.yaml` for the new layout.
5. Keep `talosctl` available (needed for `upgrade-k8s`, trust, emergency dashboards).

## Non-goals (Phase 2, separate change)

- **1Password secrets swap**: importing the Talos secrets bundle into a 1Password item and switching `secrets.yaml` from SOPS to `ref+op://` per-field refs. Deferred until the TOPF migration is verified in production. Phase 1 must not preclude this (see [Secrets](#secrets)).

## Current State (talos/whoverse)

```
talos/whoverse/
├── talconfig.yaml            # Cluster config (source of truth)
├── talsecret.sops.yaml      # Encrypted cluster secrets (SOPS: age + GPG)
├── ceph-osd-volume.yaml     # Per-node machine patch (referenced by talconfig)
├── cilium-bootstrap.yaml    # BGP bootstrap snippet
├── gen-cilium-manifest.sh   # Regenerates Cilium inline manifest
├── hostpath-volume.yaml     # (retired user volume, kept for reference)
├── miroir-disk.yaml         # Per-node miroir RawVolumeConfig patch
├── miroir-disk-vm-tiny.yaml # VM variant
├── patches/
│   ├── spegel-containerd-config.yaml
│   ├── watchdog.yaml
│   ├── kernel-miroir.yaml
│   ├── kubelet-miroir.yaml
│   └── networking/
│       ├── common.yaml      # BridgeConfig br0 + DHCPv4Config + Layer2VIPConfig
│       ├── zimaboard.yaml   # BondConfig (enp2s0+enp3s0)
│       ├── zimaboard2.yaml
│       └── vm.yaml
└── clusterconfig/           # Generated configs (gitignored)
```

### talconfig.yaml key content

- `clusterName: whoverse`, `talosVersion: v1.13.9`, `kubernetesVersion: v1.36.2`
- `endpoint: https://192.168.2.20:6443`
- `allowSchedulingOnControlPlanes: true`
- `clusterPodNets: [10.244.0.0/16]`, `clusterSvcNets: [10.96.0.0/12]`
- `cniConfig: { name: none }` (Cilium owns CNI)
- 6 nodes: `whoverse-zima1` (worker), `whoverse-cp2`/`cp3` (CP), `whoverse-w1` (worker), `whoverse-w2` (worker VM), `whoverse-vm1` (CP VM)
- Per-node: `installDisk`, `patches` (miroir-disk + networking), `schematic` (w2/vm1), `nodeLabels` (vm1)
- `controlPlane:` schematic + patches (proxy disabled, OIDC apiserver, kubeletTalosAPIAccess, spegel, watchdog, kernel/kubelet-miroir, controllerManager/scheduler bind-address, EPHEMERAL volumes)
- `worker:` schematic + patches (proxy disabled, spegel, watchdog, kernel/kubelet-miroir, EPHEMERAL volumes, nodeLabels)

## Target State (talos/whoverse)

```
talos/whoverse/
├── topf.yaml                # Cluster config (source of truth)
├── secrets.yaml             # Encrypted cluster secrets (renamed from talsecret.sops.yaml)
├── schematic.yaml           # System extensions (physical nodes: 7 ext)
├── schematic-vm.yaml        # System extensions (VMs: 8 ext, +qemu-guest-agent)
├── all/                     # Applied to all nodes
│   ├── 00-cluster.yaml      # cniConfig, podNets, svcNets, allowSchedulingOnCP
│   ├── 01-proxy.yaml        # cluster.proxy.disabled
│   ├── 02-volumes.yaml      # EPHEMERAL volume
│   ├── 03-spegel.yaml       # spegel containerd config
│   ├── 04-watchdog.yaml     # WatchdogTimerConfig
│   ├── 05-kernel-miroir.yaml
│   ├── 06-kubelet-miroir.yaml
│   └── 07-vip.yaml          # Layer2VIPConfig 192.168.2.20
├── control-plane/           # Applied to control-plane nodes
│   ├── 00-oidc.yaml         # apiserver OIDC args
│   ├── 01-talos-api.yaml    # kubeletTalosAPIAccess
│   └── 02-metrics.yaml      # controllerManager/scheduler bind-address
├── worker/                  # Applied to worker nodes
│   └── 00-labels.yaml       # nodeLabels miroir.enabled
├── node/                    # Per-host patches
│   ├── whoverse-zima1/
│   │   ├── 00-install.yaml  # installDisk /dev/sda
│   │   ├── 01-miroir.yaml   # miroir-disk
│   │   └── 02-net.yaml     # BridgeConfig + DHCP + BondConfig
│   ├── whoverse-cp2/        # (same shape)
│   ├── whoverse-cp3/
│   ├── whoverse-w1/
│   ├── whoverse-w2/         # + schematic override (VM extensions)
│   └── whoverse-vm1/        # + nodeLabels
├── ceph-osd-volume.yaml     # kept (referenced by patches)
├── cilium-bootstrap.yaml    # kept
├── gen-cilium-manifest.sh   # kept
└── clusterconfig/           # gitignored (topf render output)
```

### topf.yaml shape

```yaml
clusterName: whoverse
clusterEndpoint: https://192.168.2.20:6443
talosVersion: v1.13.9
kubernetesVersion: v1.36.2
schematicId: "@schematic.yaml"
patchesDir: .          # default (dir of topf.yaml)
secretsPath: secrets.yaml
nodes:
  - host: whoverse-zima1
    ip: 192.168.2.21
    role: worker
  - host: whoverse-cp2
    ip: 192.168.2.22
    role: control-plane
  - host: whoverse-cp3
    ip: 192.168.2.23
    role: control-plane
  - host: whoverse-w1
    ip: 192.168.2.24
    role: worker
  - host: whoverse-w2
    ip: 192.168.2.225
    role: worker
    schematicId: "@schematic-vm.yaml"
  - host: whoverse-vm1
    ip: 192.168.2.26
    role: control-plane
    schematicId: "@schematic-vm.yaml"
```

### Patch split mapping

| Current | Target |
|---|---|
| `talconfig.yaml` node defs | `topf.yaml` `nodes:` |
| `installDisk` per node | `node/<host>/00-install.yaml` |
| `patches/networking/common.yaml` (BridgeConfig + DHCP) | `node/<host>/02-net.yaml` (per-host, since bond config differs) |
| `patches/networking/zimaboard.yaml` etc. (BondConfig) | merged into `node/<host>/02-net.yaml` |
| Layer2VIPConfig (in common.yaml) | `all/07-vip.yaml` (cluster-wide) |
| `cniConfig`, podNets, svcNets, allowSchedulingOnCP | `all/00-cluster.yaml` |
| `cluster.proxy.disabled` (CP + worker inline) | `all/01-proxy.yaml` |
| EPHEMERAL volumes (CP + worker) | `all/02-volumes.yaml` |
| spegel, watchdog, kernel/kubelet-miroir | `all/03-06-*.yaml` |
| CP OIDC apiserver args | `control-plane/00-oidc.yaml` |
| CP kubeletTalosAPIAccess | `control-plane/01-talos-api.yaml` |
| CP controllerManager/scheduler bind-address | `control-plane/02-metrics.yaml` |
| worker nodeLabels | `worker/00-labels.yaml` |
| schematics (system extensions) | `schematic.yaml` (physical) + `schematic-vm.yaml` (VMs); cluster `schematicId: @schematic.yaml`, per-node override on w2/vm1 |

**Note on schematics:** there are **two** extension sets:
- **Physical nodes** (zima1, cp2, cp3, w1): iscsi-tools, realtek-firmware, gvisor, amdgpu, i915, xe, drbd → schematic ID `0fb1f84d…`
- **VMs** (w2, vm1): same + `qemu-guest-agent` → schematic ID `1a03a0b4…`

Cluster-level `schematicId: "@schematic.yaml"` (physical set) + per-node `schematicId: "@schematic-vm.yaml"` override on w2 and vm1. Both IDs verified to match the live cluster's installer images.

## Patch Merge Semantics

TOPF uses **strategic merge** for patches (same as `talosctl --config-patch`). Verified empirically:

- **Arrays concatenate** (they do NOT replace). Two patches setting `machine.kernel.modules` merge into one list.
- **Maps merge** (later patches override same-key values).
- `$patch: delete` is supported for removing array elements.

Implication for the split: array fields must appear in **at most one patch per node** unless concatenation is intended. Current patches have no conflicts (`kernel.modules`, `machine.files`, `links` each appear once per node).

## Secrets

### Phase 1: keep SOPS, rename only

- `talsecret.sops.yaml` → `secrets.yaml` (rename; encrypted bytes unchanged, keys unchanged — **never regenerate**).
- **`.sops.yaml` update required**: the current talos rule is `talos/.*\.sops\.yaml$`, which will **not** match the new `secrets.yaml` filename. Change the talos rule to `talos/.*\.yaml$` (whole-file encryption, no `encrypted_regex`).
  - This is needed both for future `sops -e`/`sops` edits AND for TOPF's own `secrets` command, which re-encrypts via `sops encrypt --filename-override <secretsPath>`.
- TOPF reads `secrets.yaml` through its SOPS pass natively — no conversion needed.

### Phase 2 (deferred): 1Password swap

- Import the bundle's leaf values (each is a scalar — the only shape vals can substitute) into a single 1Password item as per-field refs like `ref+op://home-ops/talos-secrets/certs-etcd-crt`.
- Switch `secrets.yaml` from SOPS to that item.
- **Verified constraint:** vals does **not** re-parse substituted YAML as documents (a whole-document root ref yields empty output). Per-field refs are the only sound approach.
- Phase 1 must not preclude this: keep `secrets.yaml` as a plain file path (TOPF's `secretsPath` is filesystem-only; the `secretsProvider` binary hook exists but is out of scope).

## Tooling

### mise.toml

- Add: `topf = "github:postfinance/topf"` (verified working via mise, v0.5.0, SLSA-checked).
- Remove: `talhelper`.
- Keep: `talosctl` (needed for `upgrade-k8s`, trust, emergency dashboards).

### Justfile

Remove the talos-* recipes that map 1:1 to TOPF commands (run topf directly):

| Removed recipe | TOPF equivalent |
|---|---|
| `talos-gen` | `topf render` |
| `talos-apply` | `topf apply` |
| `talos-apply-insecure` | `topf apply` (maintenance-mode flow) |
| `talos-bootstrap` | `topf apply --auto-bootstrap` (fresh-cluster path only) |
| `talos-health` | `topf nodes` |
| `talos-kubeconfig` | `topf kubeconfig` |
| `talos-upgrade` | `topf upgrade` |
| `talos-reset` | `topf reset` |

**Keep** `talos-upgrade-k8s` (maps to `talosctl upgrade-k8s`; TOPF explicitly does not orchestrate Kubernetes upgrades).

Remove now-unused `talos_dir` / `talos_config` vars.

### talos/AGENTS.md

Rewrite for the TOPF workflow:
- `topf.yaml` is the source of truth; patch layout (`all/` → `<role>/` → `node/<host>/`).
- Day-2: `topf render` (preview), `topf apply` (with confirmation), `topf upgrade`, `topf nodes`, `topf kubeconfig`, `topf talosconfig`.
- Secrets: `secrets.yaml` (SOPS), `.sops.yaml` rule covers `talos/.*\.yaml$`.
- Keep `talosctl upgrade-k8s` for Kubernetes upgrades.

## Verification

1. **Baseline** `just flate-test` before changes (already run: 191 passed).
2. Work in `.worktrees/feat/topf-migration` (done).
3. **Critical correctness gate:** `topf render` output must **semantically match** the currently-generated `clusterconfig/*.yaml`. Since we import the same secrets bundle, Talos certs/keys are identical. Diff after normalizing for expected cosmetic differences (e.g. field ordering, `talosVersion` pinning).
4. `pre-commit run --all-files` + `just flate-test` before commit.
5. No regeneration, no reset, no cluster writes during this change. Justfile becomes TOPF-native; nothing is applied that changes the live cluster unless the user explicitly runs `topf apply` afterward.

## Risks

| Risk | Mitigation |
|---|---|
| TOPF v0.5.0 built against Talos v1.13.8 vs cluster v1.13.9 | `talosVersion: v1.13.9` pinned in `topf.yaml`; render-diff gate catches any mismatch |
| Patch split introduces config drift | Render-diff gate against current `clusterconfig/*.yaml` |
| `.sops.yaml` rule change breaks decryption | Verify `sops -d secrets.yaml` works after rename; rule covers `talos/.*\.yaml$` |
| TOPF is early-stage (API/CLI may change) | Pin exact version in mise; document upgrade path |
| Secrets bundle accidentally regenerated | Never run `topf secrets generate`; keep `secrets.yaml` as the single source |

## Out of Scope

- 1Password secrets swap (Phase 2)
- Multi-cluster support (TOPF is single-cluster; `whoverse` is the only cluster)
- Kubernetes version upgrades via TOPF (use `talosctl upgrade-k8s`)
- Cilium/Flux bootstrap changes
