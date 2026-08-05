# KubeVirt deployment on whoverse (Phase 1: testing VMs)

- **Date:** 2026-08-05
- **Status:** Draft, pending user review
- **Owner:** home-ops maintainers

## 1. Problem

We want to run virtual machines on the whoverse cluster. Short term this is
for quick testing VMs; long term it may replace workloads currently hosted on
a Proxmox (PVE) server (pve1/pve4, reachable today via the tailnet egress
services in `kubernetes/network/pve-egress/`). The deployment must follow the
existing GitOps patterns (namespace → component → `ks.yaml` + `app/`) and
must not require cluster-node changes.

## 2. Verified environment facts

Node compatibility was checked against the live cluster (2026-08-05):

| Node | Role | HW | `/dev/kvm` | `/dev/vhost-net` | Verdict |
|---|---|---|---|---|---|
| whoverse-cp1 | control-plane | ZimaBoard | present | present | VM-capable |
| whoverse-cp2 | control-plane | ZimaBoard | (same model, VMX label present) | — | VM-capable |
| whoverse-cp3 | control-plane | ZimaBoard | (same model, VMX label present) | — | VM-capable |
| whoverse-w1 | worker | ZimaBoard 2 | present | present | VM-capable |
| whoverse-w2 | worker | libvirt VM on PVE | **absent** (no nested virt) | present | **not VM-capable** |

- `/dev/kvm` confirmed via `talosctl -n <node> ls /dev/` on cp1 + w1; cp2/cp3
  carry the same NFD label `feature.node.kubernetes.io/cpu-cpuid.VMX=true`
  (re-verify at implementation).
- **No Talos changes required**: the Talos amd64 kernel has
  `CONFIG_KVM_INTEL=y`, `CONFIG_KVM_AMD=y`, `CONFIG_VHOST_NET=y` (built-in).
  The former `siderolabs/kubevirt` system extension has been retired from the
  siderolabs extensions registry (`ghcr.io/siderolabs/kubevirt` → unknown) and
  is not needed. No schematic edits, no node reboots.
- No node taints anywhere (`allowSchedulingOnControlPlanes: true`), so
  KubeVirt components schedule on all nodes unless we say otherwise.
- Storage: `miroir-local` (RWO, replicas=1, fast, `WaitForFirstConsumer`) and
  `miroir-replicated` (RWO, replicas=2). `miroir-snap` VolumeSnapshotClass
  exists (KubeVirt snapshot/restore works). Media RWX PVCs are external NAS
  NFS static PVs — not used for VMs.
- Cilium CNI in place; no Multus, no NetworkAttachmentDefinitions installed.

## 3. Design decisions (agreed with user)

1. **Networking: masquerade binding (default pod network). No Multus, no
   VLAN bridge in this phase.** VMs get pod-network IPs and outbound NAT;
   direct access is via `tailscaled` running inside the guests (the user's
   established pattern with their PVE VMs). This removes all VLAN-3 bridge
   plumbing (NAD, `br0` master, vlan tagging) from the critical path.
   - Outbound (VM → LAN/internet) works through double NAT (virt-launcher
     masquerade → Cilium BPF masquerade).
   - Inbound (LAN → VM directly) does not exist; access is tailnet-only.
   - Phase 2 (future, not in this spec): Multus + `bridge` CNI NAD
     (`master: br0`, `vlan: 3`) for LAN-native `172.16.3.0/24` addressing when
     PVE migration requires non-tailnet reachability.
2. **Storage: `miroir-local` RWO for VM disks.** CDI scratch space also on
   `miroir-local`. Fast, snapshots via `miroir-snap`, kopiur for backup.
   - **Live migration is explicitly out of scope.** KubeVirt requires RWX
     filesystem PVCs for live migration; miroir's only RWX path is its NFS
     gateway (single point of failure), and the external NAS NFS has the same
     SPOF. Node loss = VM restart (recovery = boot time). If a future VM needs
     zero-downtime node maintenance, re-platform that VM to
     `miroir-replicated` RWX or revisit storage — not worth it for test VMs.
3. **Management: virtctl CLI on the workstation** (krew plugin or mise
   `ubi:kubevirt/kubevirt`, verify at implementation). kubevirt-manager web UI
   is a possible Phase 2 addition.
4. **Platform in git, VMs ad-hoc.** Commit the operator, CR, and CDI. Test VMs
   are created/removed with `virtctl`/YAML outside git. A reference VM
   manifest lives in this spec (section 8) only.
5. **gvisor-kvm: not enabled** (YAGNI). RuntimeClasses `gvisor`/`gvisor-kvm`
   already exist but nothing uses them. Once KVM works, runsc-kvm's
   prerequisite is met for free if a future workload needs it.

## 4. Architecture

```
kubectl/virtctl (workstation)
        │  virt API (kube-apiserver)
        ▼
┌────────────────────────── kubevirt namespace ──────────────────────────┐
│  kubevirt-operator (deployment)  ── owns ──►  KubeVirt CR (kubevirt)  │
│                                                 │                     │
│   virt-controller (deployment)  ◄────────────────┘                     │
│   virt-api (deployment)                                                │
│   virt-handler (DaemonSet, VMX nodes only)  ──►  /dev/kvm              │
│   virt-operator (deployment)                                           │
├────────────────────────── kubevirt namespace ──────────────────────────┤
│  cdi-operator (deployment) ── owns ──►  CDI CR (cdi)                   │
│  cdi-deployment / cdi-apiserver / cdi-uploadproxy (deployments)        │
└─────────────────────────────────────────────────────────────────────────┘
        │ dataVolume import (qcow2 → PVC via CDI)
        ▼
  VirtualMachine (ad-hoc, e.g. namespace `vms`)
    └─ masquerade NIC ─► pod network ─► Cilium NAT ─► LAN/internet
    └─ cloudInitNoCloud (cloud-init + tailscale bootstrap)
    └─ rootdisk: PVC on miroir-local
```

- `virt-handler` DaemonSet is constrained via the KubeVirt CR
  `spec.workloads.nodePlacement` nodeSelector
  `feature.node.kubernetes.io/cpu-cpuid.VMX: "true"` — lands only on the four
  physical nodes, self-heals if a new physical node joins, and never touches
  w2.
- No feature gates required: `LiveMigration` is on by default in v1.9 and we
  do not use Multus binding (`NetworkBindingPlugins` not needed).

## 5. In scope

### 5.1 Repo changes (the deployment itself)

```
kubernetes/
├── kustomization.yaml                          # add kubevirt to aggregator
└── kubevirt/
    ├── ns.yaml                                 # Namespace kubevirt
    ├── kustomization.yaml                      # references ns.yaml first
    ├── operator/
    │   ├── ks.yaml                             # Flux Kustomization
    │   └── app/
    │       ├── kustomization.yaml
    │       └── kubevirt-operator-v1.9.0.yaml   # vendored release manifest
    └── core/
        ├── ks.yaml                             # dependsOn: operator
        └── app/
            ├── kustomization.yaml
            ├── kubevirt-cr-v1.9.0.yaml         # KubeVirt CR + nodePlacement
            ├── cdi-operator-v1.9.1.yaml        # vendored CDI operator (pin latest 1.9.x at implementation)
            └── cdi-cr.yaml                     # CDI CR (scratch on miroir-local)
```

- Vendored manifests are the official release assets:
  `kubevirt-operator.yaml` + `kubevirt-cr.yaml` from
  `github.com/kubevirt/kubevirt/releases/tag/v1.9.0` (the only official
  deployment method — KubeVirt does not publish a Helm chart;
  `ghcr.io/kubevirt/kubevirt-operator` registry does not exist).
- Strip the `Namespace/kubevirt` object from the vendored operator manifest —
  the repo's `ns.yaml` is the source of truth (keeps the pre-commit structure
  rule happy and avoids drift between two namespace definitions).
- CDI (containerized-data-importer) operator from
  `github.com/kubevirt/containerized-data-importer` latest release (pin
  v1.9.x at implementation); CDI CR with
  `spec.config.scratchSpaceStorageClass: miroir-local` and raised
  `podResourceRequirements` (defaults are too small for importers).
- KubeVirt CR:

  ```yaml
  apiVersion: kubevirt.io/v1
  kind: KubeVirt
  metadata:
    name: kubevirt
    namespace: kubevirt
  spec:
    configuration:
      developerConfiguration:
        featureGates: []
    workloads:
      nodePlacement:
        nodeSelector:
          feature.node.kubernetes.io/cpu-cpuid.VMX: "true"
  ```

### 5.2 Ordering

Flux `Kustomization/core` has `spec.dependsOn: [{name: operator}]` so the CRs
(the `KubeVirt` CR and `CDI` CR) are only reconciled after their CRDs exist
(operator manifest carries the CRDs). The operator manifest also contains its
own namespace/structure, applied idempotently.

### 5.3 Workstation

- Install `virtctl` (v1.9.0 to match). Default: `kubectl krew install virt`
  (the path shown in the official Talos guide, keeps `kubectl virt` in one
  command). Alternative if the mise ubi asset pattern resolves:
  `mise use -g ubi:kubevirt/kubevirt` — verify the binary asset extraction
  works before adopting; otherwise stay on krew.

## 6. Out of scope (Phase 2 candidates)

- Multus + VLAN-3 bridge NAD (LAN-native `172.16.3.0/24` addressing) — needed
  for PVE migration when VMs must serve non-tailnet LAN devices.
- Live migration / HA (requires RWX shared storage — see decision 2).
- kubevirt-manager (web UI).
- PVE → KubeVirt VM migration tooling (qemu-img convert / virt-v2v, network
  re-addressing).
- gvisor-kvm enablement.

## 7. Validation

- `just flate-test` before/after changes; pre-commit (gitleaks/trufflehog)
  before commit — vendored manifests are clean upstream, but scan anyway.
- Post-deploy smoke test:
  1. `kubectl -n kubevirt get pods` — operator, controller, api, handler all
     Running; virt-handler present only on cp1-3 + w1.
  2. `kubectl get kv kubevirt -n kubevirt -o jsonpath='{.status.phase}'` —
     `Deployed`.
  3. `kubectl -n kubevirt get cdi cdi` — `Deployed`.
  4. Create the reference test VM (section 8) in an ad-hoc `vms` namespace;
     `virtctl start`; `virtctl console`; confirm outbound connectivity
     (`curl`), tailscale up, SSH via tailnet hostname.
  5. Confirm no VM schedules on w2 (`kubectl get vmi -o wide`).

## 8. Reference test VM (ad-hoc, not committed)

```yaml
apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata:
  name: debian-test
  namespace: vms
spec:
  running: true
  template:
    spec:
      domain:
        cpu:
          cores: 2
        resources:
          requests:
            memory: 2Gi
        machine:
          type: q35
        devices:
          disks:
            - name: rootdisk
              disk: {bus: virtio}
            - name: cloudinit
              disk: {bus: virtio}
          interfaces:
            - name: podnet
              masquerade: {}
      networks:
        - name: podnet
          pod: {}
      volumes:
        - name: rootdisk
          dataVolume:
            name: debian-test-dv
        - name: cloudinit
          cloudInitNoCloud:
            userData: |
              #cloud-config
              users:
                - name: alina
                  ssh_authorized_keys:
                    - <your-key>
                  sudo: ['ALL=(ALL) NOPASSWD:ALL']
                  shell: /bin/bash
              runcmd:
                - curl -fsSL https://tailscale.com/install.sh | sh
                - tailscale up
  dataVolumeTemplates:
    - metadata:
        name: debian-test-dv
      spec:
        storage:
          resources:
            requests:
              storage: 10Gi
          storageClassName: miroir-local
        source:
          http:
            url: https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-generic-amd64.qcow2
```

Expected footprint: ~1–2 vCPU / 1–2 Gi per test VM; virt-handler + operator
overhead ≈ 0.5–1 Gi per node. Comfortably fits several concurrent test VMs on
the current 4-node pool (cp1-3 ~7.2 Gi allocatable each, w1 ~15.6 Gi).

## 9. Risks / verification points

- **cp2/cp3 `/dev/kvm`** — confirmed by NFD VMX label + identical hardware;
  verify at implementation before relying on all four nodes.
- **CDI scratch on `miroir-local` (`WaitForFirstConsumer`)** — importer pod
  should bind to the same node; if the importer fails to provision, fall back
  to `miroir-replicated` or a dedicated scratch class.
- **Cilium + masquerade VM egress** — expected to work (virt-launcher
  iptables masquerade inside pod netns, Cilium BPF masquerade at node); the
  smoke test (7.4) is the gate.
- **Vendored manifest size / review** — operator manifest is large
  (operator + CRDs); the diff is a one-time vendored import, pinned by
  version, and should be reviewed for drift on upgrades.
- **KubeVirt version alignment** — virtctl must match the deployed KubeVirt
  version (v1.9.0); CDI latest is expected v1.9.x, pin the exact release at
  implementation.
