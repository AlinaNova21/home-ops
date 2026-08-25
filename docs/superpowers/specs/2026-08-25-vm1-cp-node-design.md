# Add `whoverse-vm1` control-plane node to whoverse

- **Date:** 2026-08-25
- **Status:** Draft, pending user review
- **Owner:** home-ops maintainers

## 1. Problem

Add a new **control-plane** node to the whoverse cluster, provisioned as a
QEMU VM on the existing Proxmox host `root@pve1`. The node is configured
*identical to w2* (the existing PVE VM worker), except that it is a control
plane rather than a worker, and its PVE name + Kubernetes hostname are
`whoverse-vm1` rather than the `wN` scheme. It becomes the fourth control
plane (cp1-cp3 + vm1).

The user creates the VM on pve1 by hand via `qm`; this spec covers the exact
VM definition to mirror, plus the Talos and repo changes.

## 2. Verified environment facts

- PVE host: `root@pve1` (tailnet `pve1.tailnet-f088.ts.net`, reachable; VM
  configs in `/etc/pve/qemu-server/`).
- Source VM for the mirror: **`whoverse-w2` = PVE VM `225`**
  (`/etc/pve/qemu-server/225.conf`). Full recorded config:

  | key | value |
  |---|---|
  | `agent` | `1,fstrim_cloned_disks=1` |
  | `balloon` | `0` |
  | `boot` | `order=scsi0;ide2` |
  | `cores` | `4` |
  | `cpu` | `x86-64-v2-AES` |
  | `hotplug` | `disk,network,usb` |
  | `ide2` | `scale-smb:iso/nocloud-amd64.iso,media=cdrom,size=330060K` |
  | `machine` | `q35` |
  | `memory` | `8192` |
  | `nameserver` | `192.168.2.1` |
  | `net0` | `virtio=BC:24:11:52:60:D3,bridge=vmbr0,tag=1` |
  | `ostype` | `l26` |
  | `scsi0` | `zfs-iscsi:vm-225-disk-0,discard=on,size=128G,ssd=1` |
  | `scsihw` | `virtio-scsi-single` |
  | `searchdomain` | `local` |
  | `sockets` | `1` |

  VM boots from `nocloud-amd64.iso`; IP is static via Talos config (nocloud
  only provides the ISO boot). Disks live on the `zfs-iscsi` PVE storage.

- Talos node `whoverse-w2` in `talos/whoverse/talconfig.yaml` currently uses:
  - `installDisk: /dev/sda`
  - patches: `@./miroir-disk-w2.yaml`, `@./patches/networking/common.yaml`,
    `@./patches/networking/vm.yaml`
  - per-node `schematic` with `siderolabs/qemu-guest-agent` among a set of
    official extensions.
- New node IP octet is **`26`** (so `192.168.2.26`), keeping the LAN sequence
  `.24`/`.25`/`.26` (w1=.24). The "IP octet = PVE VM ID" convention is a
  future target only (w2 is `225` with IP `192.168.2.225` today but will be
  renumbered later); vm1 deliberately uses `.26` now.
- `192.168.2.26` is currently free in `talconfig.yaml` (no node uses it).

## 3. Design decisions (agreed with user)

1. **PVE VM `226`** on `pve1`, mirror of `225`, name `whoverse-vm1`.
2. **New MAC** `BC:24:11:7C:E7:E9` for vm1's NIC (unique to this VM).
3. **VM hostname and Kubernetes node name are both `whoverse-vm1`** (not
   `whoverse-cpN`).
4. **Role: control plane** (`controlPlane: true`), the 4th CP.
5. **Small miroir volume same as w2** (a w2-style `RawVolumeConfig` creating a
   32GiB `mirroir` carve from `system_disk`).
6. **No `ceph-osd-volume`** on vm1. rook-ceph is not active in the cluster
   (disabled pending reset); OSDs stay on physical nodes only. vm1 is not a
   rook OSD host regardless.
7. VM creation is performed **by hand** on `root@pve1` using `qm`; this spec
   provides the exact `qm` reference. No repo-side VM provisioning script.

## 3. Repo / cluster changes

### 3.1 PVE VM 226 (reference, executed by hand on pve1)

Mirror of 225 with the new name, MAC, and disk id `vm-226-disk-0`. Reference
`qm` block (exact commands/tomls finalized at implementation):

- clone `225` → `226`, override name to `whoverse-vm1`, override `net0` MAC
  to `BC:24:11:7C:E7:E9`, attach a new `zfs-iscsi:vm-226-disk-0` (128G)

### 3.2 Talos `talos/whoverse/talconfig.yaml`

Add a node entry:

```yaml
- hostname: whoverse-vm1  # VM (libvirt) — control plane
  ipAddress: 192.168.2.26
  controlPlane: true
  installDisk: /dev/sda
  patches:
    - "@./miroir-disk-vm1.yaml"
    - "@./patches/networking/common.yaml"
    - "@./patches/networking/vm.yaml"
  schematic:
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

- Networking identical to w2: `vm.yaml` (ens18 → bond0) + `common.yaml`
  (br0, DHCP, Layer2VIP).
- Per-node schematic = the CP extension set **plus `qemu-guest-agent`**
  (a VM must have the guest-agent; the plain CP schematic does not include
  it).
- The existing `controlPlane:` block applies automatically (kubelet-miroir,
  kernel-miroir, EPHEMERAL volume, OIDC apiserver args, proxy disabled,
  watchdog, spegel) — no changes there.
- New patch file `miroir-disk-w2.yaml` → rename/copy to a w2-style small
  carve: `minSize: 32GiB` from `system_disk` (see 5).

### 3.3 `README.md`

- Hardware table: change "Five-node" → "Six-node"; add the `vm1` row.
- The `vm1` row mirrors w2 (QEMU virtual, same core/RAM) but role Control
  plane.

## 4. Deployment sequence

1. Create PVE VM 226 on pve1 (`qm`) with the mirror config.
2. `just talos-gen`
3. Boot VM in maintenance mode; Talos installs.
4. `talos-apply-insecure` → `talos-health` confirm 4th CP joined (etcd +
   apiserver + control-plane services).
5. Confirm scheduling/control-plane behavior; update README.

## 5. Storage decision

- vm1 gets a **32GiB `mirroir`** `RawVolumeConfig` from `system_disk`
  (identical carve to w2, `miroir-disk-w2.yaml`).
- vm1 gets **no `ceph-osd`** patch (rook-ceph inactive; OSDs physical-only).

## 6. Out of scope

- Renumbering w2 (future).
- Extending miroir/ceph to this node.
- Automating PVE VM creation in the repo.

## 7. Risks / verification points

- MAC uniqueness on the LAN (`BC:24:11:7C:E7:E9` must not collide).
- Control-plane join: 4th CP means 4 etcd/apiserver members — verify quorum
  and leader election.
- VM sizing: 4 vCPU / 8Gi shared with QEMU; control-plane load on a VM (weak
  host?). Memory facts: CPs are weak (Celeron N3450); vm1 is a QEMU edge VM —
  monitor.