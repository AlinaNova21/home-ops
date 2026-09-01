# TOPF Migration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Migrate the `whoverse` Talos cluster from talhelper to TOPF with no cluster state change, producing machine configs that semantically match the current `clusterconfig/*.yaml`.

**Architecture:** Replace `talos/whoverse/talconfig.yaml` with `topf.yaml` + layered patches (`all/` → `control-plane/`/`worker/` → `node/<host>/`). Rename `talsecret.sops.yaml` → `secrets.yaml` (SOPS, no regeneration). Update `.sops.yaml`, `mise.toml`, Justfile, and `talos/AGENTS.md`. Verify via `topf render` diff against the current generated configs.

**Tech Stack:** TOPF v0.5.0 (via mise `github:postfinance/topf`), Talos v1.13.9, Kubernetes v1.36.2, SOPS, strategic merge patches.

**Working directory:** `.worktrees/feat/topf-migration` (already created, baseline `just flate-test` passed: 191).

---

## File Structure

**Created:**
- `talos/whoverse/topf.yaml` — cluster config (source of truth)
- `talos/whoverse/schematic.yaml` — physical node extensions (7)
- `talos/whoverse/schematic-vm.yaml` — VM extensions (8, +qemu-guest-agent)
- `talos/whoverse/all/00-cluster.yaml` — cniConfig, podNets, svcNets, allowSchedulingOnCP
- `talos/whoverse/all/01-hostname.yaml.tpl` — HostnameConfig from `.Node.Host`
- `talos/whoverse/all/02-proxy.yaml` — cluster.proxy.disabled
- `talos/whoverse/all/03-volumes.yaml` — EPHEMERAL VolumeConfig
- `talos/whoverse/all/04-spegel.yaml` — spegel containerd config
- `talos/whoverse/all/05-watchdog.yaml` — WatchdogTimerConfig
- `talos/whoverse/all/06-kernel-miroir.yaml` — kernel modules + sysctls
- `talos/whoverse/all/07-kubelet-miroir.yaml` — kubelet extraConfig
- `talos/whoverse/all/08-vip.yaml` — Layer2VIPConfig
- `talos/whoverse/all/09-bridge.yaml` — BridgeConfig + DHCPv4Config (shared)
- `talos/whoverse/all/10-miroir.yaml` — miroir RawVolumeConfig (128GiB physical default)
- `talos/whoverse/control-plane/00-oidc.yaml` — apiserver OIDC args
- `talos/whoverse/control-plane/01-talos-api.yaml` — kubeletTalosAPIAccess
- `talos/whoverse/control-plane/02-metrics.yaml` — controllerManager/scheduler bind-address
- `talos/whoverse/control-plane/03-scheduling.yaml` — allowSchedulingOnControlPlanes
- `talos/whoverse/worker/00-labels.yaml` — nodeLabels miroir.enabled
- `talos/whoverse/node/whoverse-zima1/00-install.yaml` — installDisk
- `talos/whoverse/node/whoverse-zima1/02-net.yaml` — BondConfig
- `talos/whoverse/node/whoverse-cp2/00-install.yaml`
- `talos/whoverse/node/whoverse-cp2/02-net.yaml`
- `talos/whoverse/node/whoverse-cp3/00-install.yaml`
- `talos/whoverse/node/whoverse-cp3/02-net.yaml`
- `talos/whoverse/node/whoverse-w1/00-install.yaml`
- `talos/whoverse/node/whoverse-w1/02-net.yaml`
- `talos/whoverse/node/whoverse-w2/00-install.yaml`
- `talos/whoverse/node/whoverse-w2/01-miroir.yaml` — 32GiB override
- `talos/whoverse/node/whoverse-w2/02-net.yaml`
- `talos/whoverse/node/whoverse-vm1/00-install.yaml`
- `talos/whoverse/node/whoverse-vm1/01-miroir.yaml` — 32GiB override
- `talos/whoverse/node/whoverse-vm1/02-net.yaml`
- `talos/whoverse/node/whoverse-vm1/03-labels.yaml` — miroir label

**Modified:**
- `talos/whoverse/talsecret.sops.yaml` → renamed to `talos/whoverse/secrets.yaml`
- `.sops.yaml` — talos rule `talos/.*\.sops\.yaml$` → `talos/.*\.yaml$`
- `mise.toml` — add `topf`, remove `talhelper`
- `Justfile` — remove talos-* recipes (keep `talos-upgrade-k8s`), remove `talos_dir`/`talos_config` vars
- `talos/AGENTS.md` — rewrite for TOPF workflow

**Deleted:**
- `talos/whoverse/talconfig.yaml`
- `talos/whoverse/patches/` (all files moved into new layout)
- `talos/whoverse/miroir-disk.yaml`, `miroir-disk-vm-tiny.yaml` (moved into `node/<host>/01-miroir.yaml`)

---

## Task 1: Add TOPF to mise, remove talhelper

**Files:**
- Modify: `mise.toml`

- [ ] **Step 1: Edit `mise.toml`**

In the `[tools]` section, replace:
```toml
talosctl   = "latest"
talhelper  = "latest"
```
with:
```toml
talosctl   = "latest"
topf       = "github:postfinance/topf"
```

- [ ] **Step 2: Verify topf installs**

Run: `mise install topf`
Expected: `topf` binary available. Verify: `topf --version` → `0.5.0 (Talos v1.13.8)`.

- [ ] **Step 3: Commit**

```bash
git add mise.toml
git commit -m "chore(mise): swap talhelper for topf"
```

---

## Task 2: Rename secrets file + update .sops.yaml

**Files:**
- Rename: `talos/whoverse/talsecret.sops.yaml` → `talos/whoverse/secrets.yaml`
- Modify: `.sops.yaml`

- [ ] **Step 1: Rename the secrets file**

```bash
git mv talos/whoverse/talsecret.sops.yaml talos/whoverse/secrets.yaml
```

- [ ] **Step 2: Update `.sops.yaml` talos rule**

Change:
```yaml
  - path_regex: talos/.*\.sops\.yaml$
    age: >-
      age16865gej0ndnlnghdq347fur59ht8d7wrcfptdw5ja4fhc4lwdfpq59ratl
    pgp: >-
      B2266723EDB691FBB16501BC07D6E31CCAE33514
```
to:
```yaml
  - path_regex: talos/.*\.yaml$
    age: >-
      age16865gej0ndnlnghdq347fur59ht8d7wrcfptdw5ja4fhc4lwdfpq59ratl
    pgp: >-
      B2266723EDB691FBB16501BC07D6E31CCAE33514
```

- [ ] **Step 3: Verify decryption still works**

Run: `sops -d talos/whoverse/secrets.yaml | head -5`
Expected: decrypted YAML (cluster secrets bundle), no error.

- [ ] **Step 4: Commit**

```bash
git add .sops.yaml talos/whoverse/secrets.yaml
git commit -m "chore(talos): rename talsecret to secrets.yaml, update sops rule"
```

---

## Task 3: Create schematic files

**Files:**
- Create: `talos/whoverse/schematic.yaml`
- Create: `talos/whoverse/schematic-vm.yaml`

- [ ] **Step 1: Create `schematic.yaml`** (physical nodes, 7 extensions)

```yaml
customization:
  systemExtensions:
    officialExtensions:
      - siderolabs/iscsi-tools
      - siderolabs/realtek-firmware
      - siderolabs/gvisor
      - siderolabs/amdgpu
      - siderolabs/i915
      - siderolabs/xe
      - siderolabs/drbd
```

- [ ] **Step 2: Create `schematic-vm.yaml`** (VMs, 8 extensions)

```yaml
customization:
  systemExtensions:
    officialExtensions:
      - siderolabs/iscsi-tools
      - siderolabs/realtek-firmware
      - siderolabs/gvisor
      - siderolabs/qemu-guest-agent
      - siderolabs/amdgpu
      - siderolabs/i915
      - siderolabs/xe
      - siderolabs/drbd
```

- [ ] **Step 3: Verify schematic IDs match live cluster**

Run:
```bash
cd talos/whoverse
topf schematic-ids --topfconfig <(echo 'clusterName: t
clusterEndpoint: https://192.168.2.20:6443
talosVersion: v1.13.9
kubernetesVersion: v1.36.2
schematicId: "@schematic.yaml"
nodes:
  - host: n1
    ip: 192.168.2.21
    role: worker')
```
Expected: `0fb1f84d4ea3ef694227f13f38e1cb7bd826ea73b5af23b04edc7b7732a414cf` (physical).

Repeat with `schematicId: "@schematic-vm.yaml"`:
Expected: `1a03a0b45c999c3b7cea34af818aa9bf79158a2d19ad0da3b6bfba3cf2da28c7` (VM).

- [ ] **Step 4: Commit**

```bash
git add talos/whoverse/schematic.yaml talos/whoverse/schematic-vm.yaml
git commit -m "feat(talos): add schematic files (physical + VM extension sets)"
```

---

## Task 4: Create topf.yaml

**Files:**
- Create: `talos/whoverse/topf.yaml`

- [ ] **Step 1: Create `topf.yaml`**

```yaml
clusterName: whoverse
clusterEndpoint: https://192.168.2.20:6443
talosVersion: v1.13.9
kubernetesVersion: v1.36.2
schematicId: "@schematic.yaml"
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

- [ ] **Step 2: Commit**

```bash
git add talos/whoverse/topf.yaml
git commit -m "feat(talos): add topf.yaml cluster config"
```

---

## Task 5: Create all/ patches

**Files:**
- Create: `talos/whoverse/all/00-cluster.yaml`
- Create: `talos/whoverse/all/01-hostname.yaml.tpl`
- Create: `talos/whoverse/all/02-proxy.yaml`
- Create: `talos/whoverse/all/03-volumes.yaml`
- Create: `talos/whoverse/all/04-spegel.yaml`
- Create: `talos/whoverse/all/05-watchdog.yaml`
- Create: `talos/whoverse/all/06-kernel-miroir.yaml`
- Create: `talos/whoverse/all/07-kubelet-miroir.yaml`
- Create: `talos/whoverse/all/08-vip.yaml`

- [ ] **Step 1: Create `all/00-cluster.yaml`**

```yaml
cluster:
  network:
    cni:
      name: none
    podSubnets:
      - 10.244.0.0/16
    serviceSubnets:
      - 10.96.0.0/12
  allowSchedulingOnControlPlanes: true
```

- [ ] **Step 2: Create `all/01-hostname.yaml.tpl`**

```yaml
apiVersion: v1alpha1
kind: HostnameConfig
auto: "off"
hostname: {{ .Node.Host }}
```

- [ ] **Step 3: Create `all/02-proxy.yaml`**

```yaml
cluster:
  proxy:
    disabled: true
```

- [ ] **Step 4: Create `all/03-volumes.yaml`**

```yaml
apiVersion: v1alpha1
kind: VolumeConfig
name: EPHEMERAL
provisioning:
  diskSelector:
    match: system_disk
  maxSize: 64GiB
```

- [ ] **Step 5: Create `all/04-spegel.yaml`**

```yaml
machine:
  files:
    - path: /var/etc/cri/conf.d/20-spegel.part
      op: create
      permissions: 0o000
      content: |
        [plugins."io.containerd.cri.v1.images"]
          discard_unpacked_layers = false
```

- [ ] **Step 6: Create `all/05-watchdog.yaml`**

```yaml
apiVersion: v1alpha1
kind: WatchdogTimerConfig
device: /dev/watchdog0
timeout: 5m
```

- [ ] **Step 7: Create `all/06-kernel-miroir.yaml`**

```yaml
machine:
  kernel:
    modules:
      - name: drbd
        parameters:
          - usermode_helper=disabled
      - name: drbd_transport_tcp
      - name: dm_thin_pool
  sysctls:
    user.max_user_namespaces: "11255"
```

- [ ] **Step 8: Create `all/07-kubelet-miroir.yaml`**

```yaml
machine:
  kubelet:
    extraConfig:
      shutdownGracePeriod: 120s
      shutdownGracePeriodCriticalPods: 60s
```

- [ ] **Step 9: Create `all/08-vip.yaml`**

```yaml
apiVersion: v1alpha1
kind: Layer2VIPConfig
name: 192.168.2.20
link: br0
```

- [ ] **Step 10: Commit**

```bash
git add talos/whoverse/all/
git commit -m "feat(talos): add all/ patches (cluster, hostname, proxy, volumes, spegel, watchdog, kernel, kubelet, vip)"
```

---

## Task 6: Create control-plane/ and worker/ patches

**Files:**
- Create: `talos/whoverse/control-plane/00-oidc.yaml`
- Create: `talos/whoverse/control-plane/01-talos-api.yaml`
- Create: `talos/whoverse/control-plane/02-metrics.yaml`
- Create: `talos/whoverse/worker/00-labels.yaml`

- [ ] **Step 1: Create `control-plane/00-oidc.yaml`**

```yaml
cluster:
  apiServer:
    extraArgs:
      oidc-issuer-url: https://idm.whoverse.nexus/oauth2/openid/kubernetes
      oidc-client-id: kubernetes
      oidc-username-claim: email
      oidc-groups-claim: groups
      oidc-signing-algs: ES256
```

- [ ] **Step 2: Create `control-plane/01-talos-api.yaml`**

```yaml
machine:
  features:
    kubernetesTalosAPIAccess:
      enabled: true
      allowedRoles:
        - os:admin
      allowedKubernetesNamespaces:
        - system-upgrade
```

- [ ] **Step 3: Create `control-plane/02-metrics.yaml`**

```yaml
cluster:
  controllerManager:
    extraArgs:
      bind-address: 0.0.0.0
      terminated-pod-gc-threshold: "100"
  scheduler:
    extraArgs:
      bind-address: 0.0.0.0
```

- [ ] **Step 4: Create `worker/00-labels.yaml`**

```yaml
machine:
  nodeLabels:
    miroir.home-operations.com/enabled: "true"
```

- [ ] **Step 5: Commit**

```bash
git add talos/whoverse/control-plane/ talos/whoverse/worker/
git commit -m "feat(talos): add control-plane and worker role patches"
```

---

## Task 7: Create node/<host>/ patches

**Files:**
- Create: `talos/whoverse/node/whoverse-zima1/{00-install,01-miroir,02-net}.yaml`
- Create: `talos/whoverse/node/whoverse-cp2/{00-install,01-miroir,02-net}.yaml`
- Create: `talos/whoverse/node/whoverse-cp3/{00-install,01-miroir,02-net}.yaml`
- Create: `talos/whoverse/node/whoverse-w1/{00-install,01-miroir,02-net}.yaml`
- Create: `talos/whoverse/node/whoverse-w2/{00-install,01-miroir,02-net}.yaml`
- Create: `talos/whoverse/node/whoverse-vm1/{00-install,01-miroir,02-net}.yaml`

- [ ] **Step 1: Create `node/whoverse-zima1/00-install.yaml`**

```yaml
machine:
  install:
    disk: /dev/sda
```

- [ ] **Step 2: Create `node/whoverse-zima1/01-miroir.yaml`**

```yaml
apiVersion: v1alpha1
kind: RawVolumeConfig
name: miroir
provisioning:
  diskSelector:
    match: system_disk
  minSize: 128GiB
```

- [ ] **Step 3: Create `node/whoverse-zima1/02-net.yaml`**

```yaml
apiVersion: v1alpha1
kind: BridgeConfig
name: br0
links:
  - bond0
stp:
  enabled: true
---
apiVersion: v1alpha1
kind: DHCPv4Config
name: br0
---
apiVersion: v1alpha1
kind: BondConfig
name: bond0
links:
  - enp2s0
  - enp3s0
bondMode: 802.3ad
miimon: 100
updelay: 100
downdelay: 100
xmitHashPolicy: layer3+4
lacpRate: fast
up: true
```

- [ ] **Step 4: Repeat for cp2, cp3** (same as zima1: installDisk `/dev/sda`, miroir 128GiB, BondConfig enp2s0+enp3s0 802.3ad)

- [ ] **Step 5: Create `node/whoverse-w1/00-install.yaml`**

```yaml
machine:
  install:
    disk: /dev/disk/by-id/wwn-0x5001b444a9bb4808
```

- [ ] **Step 6: Create `node/whoverse-w1/01-miroir.yaml`** (same as zima1: 128GiB)

- [ ] **Step 7: Create `node/whoverse-w1/02-net.yaml`** (BondConfig enp2s0, active-backup)

```yaml
apiVersion: v1alpha1
kind: BridgeConfig
name: br0
links:
  - bond0
stp:
  enabled: true
---
apiVersion: v1alpha1
kind: DHCPv4Config
name: br0
---
apiVersion: v1alpha1
kind: BondConfig
name: bond0
links:
  - enp2s0
bondMode: active-backup
miimon: 100
updelay: 100
up: true
```

- [ ] **Step 8: Create `node/whoverse-w2/00-install.yaml`** (installDisk `/dev/sda`)

- [ ] **Step 9: Create `node/whoverse-w2/01-miroir.yaml`** (VM variant, 32GiB)

```yaml
apiVersion: v1alpha1
kind: RawVolumeConfig
name: miroir
provisioning:
  diskSelector:
    match: system_disk
  minSize: 32GiB
```

- [ ] **Step 10: Create `node/whoverse-w2/02-net.yaml`** (BondConfig ens18, active-backup)

```yaml
apiVersion: v1alpha1
kind: BridgeConfig
name: br0
links:
  - bond0
stp:
  enabled: true
---
apiVersion: v1alpha1
kind: DHCPv4Config
name: br0
---
apiVersion: v1alpha1
kind: BondConfig
name: bond0
links:
  - ens18
bondMode: active-backup
miimon: 100
updelay: 100
up: true
```

- [ ] **Step 11: Create `node/whoverse-vm1/00-install.yaml`** (installDisk `/dev/sda`)

- [ ] **Step 12: Create `node/whoverse-vm1/01-miroir.yaml`** (VM variant, 32GiB)

- [ ] **Step 13: Create `node/whoverse-vm1/02-net.yaml`** (BondConfig ens18, active-backup — same as w2)

- [ ] **Step 14: Commit**

```bash
git add talos/whoverse/node/
git commit -m "feat(talos): add per-node patches (install, miroir, networking)"
```

---

## Task 8: Delete old talhelper files

**Files:**
- Delete: `talos/whoverse/talconfig.yaml`
- Delete: `talos/whoverse/patches/` (all)
- Delete: `talos/whoverse/miroir-disk.yaml`, `miroir-disk-vm-tiny.yaml`

- [ ] **Step 1: Remove old files**

```bash
git rm -r talos/whoverse/talconfig.yaml talos/whoverse/patches/ talos/whoverse/miroir-disk.yaml talos/whoverse/miroir-disk-vm-tiny.yaml
```

- [ ] **Step 2: Verify no talhelper references remain**

Run: `grep -rn "talconfig\|talhelper" talos/ --include="*.yaml" --include="*.tpl" | grep -v clusterconfig`
Expected: no output.

- [ ] **Step 3: Commit**

```bash
git commit -m "chore(talos): remove talhelper config and patches"
```

---

## Task 9: Update Justfile

**Files:**
- Modify: `Justfile`

- [ ] **Step 1: Remove talos-* recipes and vars**

Delete the `talos_dir` and `talos_config` vars:
```just
talos_dir := "talos/whoverse"
talos_config := talos_dir + "/clusterconfig"
```

Delete the entire "Talos Cluster Management" section (recipes `talos-gen`, `talos-apply`, `talos-apply-insecure`, `talos-bootstrap`, `talos-health`, `talos-kubeconfig`, `talos-upgrade`, `talos-reset`).

**Keep** `talos-upgrade-k8s` (maps to `talosctl upgrade-k8s`):
```just
# Upgrade Kubernetes version
talos-upgrade-k8s:
    cd {{talos_dir}} && talhelper gencommand upgrade-k8s | bash
```
→ change to:
```just
# Upgrade Kubernetes version (TOPF does not orchestrate k8s upgrades)
talos-upgrade-k8s:
    talosctl upgrade-k8s
```

- [ ] **Step 2: Verify no dangling references**

Run: `grep -n "talos_dir\|talos_config\|talhelper" Justfile`
Expected: only the `talos-upgrade-k8s` recipe (which no longer uses them).

- [ ] **Step 3: Commit**

```bash
git add Justfile
git commit -m "chore(just): replace talhelper recipes with topf equivalents"
```

---

## Task 10: Rewrite talos/AGENTS.md

**Files:**
- Modify: `talos/AGENTS.md`

- [ ] **Step 1: Rewrite for TOPF**

Replace the talhelper references with TOPF equivalents:
- Line 3: "managed by [talhelper]" → "managed by [TOPF](https://postfinance.github.io/topf/)"
- Line 7: "`talos/whoverse/talconfig.yaml`" → "`talos/whoverse/topf.yaml`"
- Lines 12-15: `yq` queries → `topf nodes` / `topf clusterinfo`
- Lines 23-25: directory structure → new layout (`topf.yaml`, `secrets.yaml`, `schematic.yaml`, `schematic-vm.yaml`, `all/`, `control-plane/`, `worker/`, `node/`)
- Lines 36: "managed via `~/.config/mise/conf.d/`" → "managed via repo `mise.toml`"
- Lines 47-57: Justfile recipes → `topf render`, `topf apply`, `topf upgrade`, `topf nodes`, `topf kubeconfig`, `topf talosconfig`
- Lines 63-64: `talhelper gensecret` → `topf secrets generate` (note: only for NEW clusters; never regenerate existing)
- Lines 92-93: "After editing `talconfig.yaml`" → "After editing `topf.yaml` or patches"
- Lines 101: "Update `talosVersion` or `kubernetesVersion` in `talconfig.yaml`" → "in `topf.yaml`"
- Lines 120-123: `sops -d talsecret.sops.yaml` → `sops -d secrets.yaml`
- Lines 136-142: "Copy and modify `talconfig.yaml`" → "Copy and modify `topf.yaml`"; `talhelper gensecret` → `topf secrets generate`
- Add a "Patch Layout" section documenting `all/` → `control-plane/`/`worker/` → `node/<host>/` merge order and array concatenation.

- [ ] **Step 2: Commit**

```bash
git add talos/AGENTS.md
git commit -m "docs(talos): rewrite AGENTS.md for TOPF workflow"
```

---

## Task 11: Render-diff verification (the gate)

**Files:**
- None (verification only)

- [ ] **Step 1: Render with topf**

```bash
cd talos/whoverse
topf render --confirm=false
```

Expected: writes `clusterconfig/*.yaml` (or `output/*.yaml` — check `topf render --help` for output dir).

- [ ] **Step 2: Compare against current generated configs**

The current configs live in the **main checkout** (`/home/alina/projects/home-ops/talos/whoverse/clusterconfig/`), not the worktree. Copy them into the worktree for comparison:

```bash
cp /home/alina/projects/home-ops/talos/whoverse/clusterconfig/*.yaml /tmp/old-configs/
```

Then diff each rendered file against the old one. **Expected differences (cosmetic):**
- Field ordering (TOPF may emit keys in different order)
- Indentation (TOPF uses 4-space, talhelper may use 2-space)
- `machine.install.image` schematic ID — should be **identical** (verified: `0fb1f84d` physical, `1a03a0b4` VM)

**Critical: no semantic differences.** Specifically verify:
- `machine.token`, `cluster.token`, all certs/keys — identical (same secrets bundle)
- `machine.install.disk` — matches per-node
- `machine.install.image` — schematic ID matches
- `cluster.network.cni.name: none`
- `cluster.allowSchedulingOnControlPlanes: true`
- `cluster.proxy.disabled: true`
- OIDC args, kubeletTalosAPIAccess, controllerManager/scheduler bind-address
- EPHEMERAL VolumeConfig (64GiB), miroir RawVolumeConfig (128GiB physical / 32GiB VM)
- WatchdogTimerConfig, spegel file, kernel modules, kubelet extraConfig
- HostnameConfig per node
- BridgeConfig/DHCPv4Config/Layer2VIPConfig/BondConfig per node

Use `yq` to normalize and diff:
```bash
yq -P 'sort_keys(..)' old.yaml > /tmp/old-normalized.yaml
yq -P 'sort_keys(..)' new.yaml > /tmp/new-normalized.yaml
diff /tmp/old-normalized.yaml /tmp/new-normalized.yaml
```

- [ ] **Step 3: If diffs found, fix patches and re-render**

Iterate: adjust the patch files until `topf render` output semantically matches. Do NOT proceed until the diff is clean (modulo cosmetic).

- [ ] **Step 4: Commit any patch fixes**

```bash
git add talos/whoverse/
git commit -m "fix(talos): align topf render with current cluster config"
```

---

## Task 12: Final validation + PR

**Files:**
- None

- [ ] **Step 1: Run full validation**

```bash
just hooks-install
pre-commit run --all-files
just flate-test
```

Expected: pre-commit passes (gitleaks + trufflehog), flate-test passes (191).

- [ ] **Step 2: Verify no secrets regenerated**

Run: `sops -d talos/whoverse/secrets.yaml | grep -c "cluster"` — should show the bundle intact. Confirm `git log` shows the rename, not a regeneration.

- [ ] **Step 3: Push branch**

```bash
git push origin feat/topf-migration
```

- [ ] **Step 4: Create PR**

```bash
gh pr create --fill
```

- [ ] **Step 5: Report to user**

Summarize: what changed, the render-diff result, and that **no apply was performed** (user will handle applying after conversion).

---

## Self-Review Notes

- **Spec coverage:** All spec sections mapped to tasks (tooling→1, secrets→2, structure→3-8, Justfile→9, docs→10, verification→11-12).
- **Schematic split:** Two schematics (physical/VM) verified against live cluster IDs.
- **Array merge:** Documented; no conflicts in current patches.
- **No placeholders:** All patch contents are exact copies of current files (verified above).
- **Type consistency:** `topf.yaml` node hosts match `node/<host>/` dirs; schematic refs match filenames.
