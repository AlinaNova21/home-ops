# KubeVirt Deployment (Phase 1: Testing VMs) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deploy KubeVirt v1.9.0 + CDI v1.66.0 onto the whoverse cluster (namespace `kubevirt`, VM-capable nodes cp1-3 + w1) via the existing Flux GitOps structure, with zero Talos/node changes.

**Architecture:** Two Flux Kustomizations under `kubernetes/kubevirt/`: `operator` (vendored `kubevirt-operator.yaml` release manifest — CRDs + operator deployment) and `core` (`dependsOn: operator` — the `KubeVirt` CR restricted to VMX nodes, plus the CDI operator + CDI CR). VM disks use `miroir-local`; VMs are created ad-hoc (not committed).

**Tech Stack:** KubeVirt v1.9.0 (release manifests, no Helm chart), CDI v1.66.0 (containerized-data-importer), Flux Kustomizations, kustomize, kubeconform/flate validation.

**Reference:** Spec at `docs/superpowers/specs/2026-08-05-kubevirt-deployment-design.md` (approved).

---

### Task 1: Namespace scaffolding for `kubevirt`

**Files:**
- Create: `kubernetes/kubevirt/ns.yaml`
- Create: `kubernetes/kubevirt/kustomization.yaml`
- Modify: `kubernetes/kustomization.yaml` (add `kubevirt` to the resources list)

- [ ] **Step 1: Create the namespace manifest**

Create `kubernetes/kubevirt/ns.yaml`:

```yaml
---
apiVersion: v1
kind: Namespace
metadata:
  name: kubevirt
  annotations:
    kustomize.toolkit.fluxcd.io/prune: disabled
  labels:
    homelab.whoverse.dev/component: infrastructure
    pod-security.kubernetes.io/enforce: privileged
    pod-security.kubernetes.io/audit: privileged
    pod-security.kubernetes.io/warn: privileged
    kubevirt.io: ""
```

The PSA `privileged` labels mirror what the upstream operator manifest sets on its own namespace (virt-launcher/virt-handler need privileged); `kubevirt.io: ""` preserves the upstream label; the component label follows house style (`kubernetes/storage/ns.yaml`).

- [ ] **Step 2: Create the namespace kustomization**

Create `kubernetes/kubevirt/kustomization.yaml`:

```yaml
---
# yaml-language-server: $schema=https://json.schemastore.org/kustomization
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ns.yaml
  - operator/ks.yaml
  - core/ks.yaml
```

- [ ] **Step 3: Register the namespace in the top-level aggregator**

In `kubernetes/kustomization.yaml`, add `- kubevirt` to `resources` (alphabetical position: after `kopiur-system`, before `kro-system`).

- [ ] **Step 4: Validate**

Run: `just flate-test`
Expected: `✓ <count> passed` (no new failures).

- [ ] **Step 5: Commit**

```bash
git add kubernetes/kubevirt/ns.yaml kubernetes/kubevirt/kustomization.yaml kubernetes/kustomization.yaml
git commit -m "feat(kubevirt): scaffold kubevirt namespace"
```

---

### Task 2: Vendor the KubeVirt operator manifest (component `operator`)

**Files:**
- Create: `kubernetes/kubevirt/operator/app/kubevirt-operator-v1.9.0.yaml` (vendored, Namespace stripped)
- Create: `kubernetes/kubevirt/operator/app/kustomization.yaml`
- Create: `kubernetes/kubevirt/operator/ks.yaml`

- [ ] **Step 1: Download the official v1.9.0 operator manifest**

Run:
```bash
cd kubernetes/kubevirt/operator/app
curl -sL --max-time 120 -o kubevirt-operator-v1.9.0.yaml \
  "https://github.com/kubevirt/kubevirt/releases/download/v1.9.0/kubevirt-operator.yaml"
wc -l kubevirt-operator-v1.9.0.yaml
```
Expected: `8758 kubevirt-operator-v1.9.0.yaml`.

- [ ] **Step 2: Strip the `Namespace/kubevirt` document**

The manifest's first document is the namespace (lines 1-9: `---`, `apiVersion: v1`, `kind: Namespace`, labels, `name: kubevirt`, trailing `---`). The repo's `ns.yaml` is the source of truth. Remove it:

```bash
sed -i '1,9d' kubevirt-operator-v1.9.0.yaml
head -3 kubevirt-operator-v1.9.0.yaml   # must start with the CRD, no leading ---
grep -c "^kind: Namespace" kubevirt-operator-v1.9.0.yaml   # must print 0
grep -n "kind: Namespace" kubevirt-operator-v1.9.0.yaml || echo "no Namespace left"
```

- [ ] **Step 3: Create the component kustomization**

Create `kubernetes/kubevirt/operator/app/kustomization.yaml`:

```yaml
---
# yaml-language-server: $schema=https://json.schemastore.org/kustomization
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - kubevirt-operator-v1.9.0.yaml
```

- [ ] **Step 4: Create the Flux Kustomization**

Create `kubernetes/kubevirt/operator/ks.yaml` (mirrors `kubernetes/kube-system/node-feature-discovery/ks.yaml`):

```yaml
---
# yaml-language-server: $schema=https://k8s-schemas.home-operations.com/kustomize.toolkit.fluxcd.io/kustomization_v1.json
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: kubevirt-operator
  namespace: kubevirt
spec:
  interval: 30m
  path: "./kubernetes/kubevirt/operator/app"
  sourceRef:
    kind: GitRepository
    name: home-ops
    namespace: flux-system
  timeout: 10m
  wait: true
  prune: true
```

- [ ] **Step 5: Validate**

Run:
```bash
kustomize build kubernetes/kubevirt/operator/app | kubeconform -strict -ignore-missing-schemas \
  -schema-location default \
  -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'
just flate-test
```
Expected: no schema errors (KubeVirt CRDs are covered by `-ignore-missing-schemas`); `✓ <count> passed` in flate.

- [ ] **Step 6: Commit**

```bash
git add kubernetes/kubevirt/operator/
git commit -m "feat(kubevirt): vendor kubevirt-operator v1.9.0 manifest"
```

---

### Task 3: KubeVirt CR restricted to VMX nodes (component `core`)

**Files:**
- Create: `kubernetes/kubevirt/core/app/kubevirt-cr-v1.9.0.yaml`
- Create: `kubernetes/kubevirt/core/app/kustomization.yaml`
- Create: `kubernetes/kubevirt/core/ks.yaml`

- [ ] **Step 1: Write the KubeVirt CR with node placement**

Create `kubernetes/kubevirt/core/app/kubevirt-cr-v1.9.0.yaml` — the upstream `kubevirt-cr.yaml` v1.9.0 content plus `spec.workloads.nodePlacement` pinning virt-handler to the four physical nodes (nodes carrying the NFD VMX label; w2 has no `/dev/kvm` and is excluded by construction):

```yaml
---
apiVersion: kubevirt.io/v1
kind: KubeVirt
metadata:
  name: kubevirt
  namespace: kubevirt
spec:
  certificateRotateStrategy: {}
  configuration:
    developerConfiguration:
      featureGates: []
    imagePullPolicy: IfNotPresent
  customizeComponents: {}
  imagePullPolicy: IfNotPresent
  workloadUpdateStrategy: {}
  workloads:
    nodePlacement:
      nodeSelector:
        feature.node.kubernetes.io/cpu-cpuid.VMX: "true"
```

- [ ] **Step 2: Create the core kustomization**

Create `kubernetes/kubevirt/core/app/kustomization.yaml`:

```yaml
---
# yaml-language-server: $schema=https://json.schemastore.org/kustomization
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - kubevirt-cr-v1.9.0.yaml
  - cdi-operator-v1.66.0.yaml
  - cdi-cr.yaml
```

- [ ] **Step 3: Create the Flux Kustomization (depends on operator)**

Create `kubernetes/kubevirt/core/ks.yaml`:

```yaml
---
# yaml-language-server: $schema=https://k8s-schemas.home-operations.com/kustomize.toolkit.fluxcd.io/kustomization_v1.json
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: kubevirt-core
  namespace: kubevirt
spec:
  dependsOn:
    - name: kubevirt-operator
  interval: 30m
  path: "./kubernetes/kubevirt/core/app"
  sourceRef:
    kind: GitRepository
    name: home-ops
    namespace: flux-system
  timeout: 10m
  wait: true
  prune: true
```

`dependsOn` guarantees the CRDs from Task 2 exist before the `KubeVirt` CR is reconciled (same pattern as `node-feature-discovery` → `node-feature-discovery-config`).

- [ ] **Step 4: Validate**

Run: `just flate-test`
Expected: `✓ <count> passed` (the `KubeVirt` CR is validated by flate with ignore-missing-schemas).

- [ ] **Step 5: Commit**

```bash
git add kubernetes/kubevirt/core/
git commit -m "feat(kubevirt): add KubeVirt CR pinned to VMX nodes"
```

---

### Task 4: Vendor the CDI operator + CDI CR (component `core`)

**Files:**
- Create: `kubernetes/kubevirt/core/app/cdi-operator-v1.66.0.yaml` (vendored, keeps its own `Namespace/cdi`)
- Create: `kubernetes/kubevirt/core/app/cdi-cr.yaml`

- [ ] **Step 1: Download the CDI v1.66.0 operator manifest**

Run:
```bash
cd kubernetes/kubevirt/core/app
curl -sL --max-time 120 -o cdi-operator-v1.66.0.yaml \
  "https://github.com/kubevirt/containerized-data-importer/releases/download/v1.66.0/cdi-operator.yaml"
wc -l cdi-operator-v1.66.0.yaml
head -8 cdi-operator-v1.66.0.yaml
```
Expected: `5807 cdi-operator-v1.66.0.yaml`; first document is `Namespace/cdi` (kept as-is — the CDI controller expects the `cdi.kubevirt.io: ""` label; the `cdi` namespace is separate from `kubevirt` and not governed by this repo's `kubevirt/` dir).

- [ ] **Step 2: Write the CDI CR**

Create `kubernetes/kubevirt/core/app/cdi-cr.yaml` (scratch space on `miroir-local`; raised pod resources — defaults are too small for importers, per the Talos KubeVirt guide):

```yaml
---
apiVersion: cdi.kubevirt.io/v1beta1
kind: CDI
metadata:
  name: cdi
  namespace: cdi
spec:
  config:
    scratchSpaceStorageClass: miroir-local
    podResourceRequirements:
      requests:
        cpu: 100m
        memory: 60Mi
      limits:
        cpu: 750m
        memory: 2Gi
```

- [ ] **Step 3: Validate**

Run:
```bash
kustomize build kubernetes/kubevirt/core/app | kubeconform -strict -ignore-missing-schemas \
  -schema-location default \
  -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'
pre-commit run --all-files
just flate-test
```
Expected: no schema errors (CDI CRDs covered by ignore-missing-schemas); pre-commit gitleaks/trufflehog pass; flate passes.

- [ ] **Step 4: Commit**

```bash
git add kubernetes/kubevirt/core/
git commit -m "feat(kubevirt): vendor CDI v1.66.0 with miroir-local scratch space"
```

---

### Task 5: Full validation, push, PR

**Files:** none (validation + git operations)

- [ ] **Step 1: Full validation**

Run:
```bash
just flate-test
pre-commit run --all-files
git status --short
```
Expected: flate `✓ <count> passed`; pre-commit all Passed; status shows only the `kubernetes/kubevirt/` additions and the aggregator change.

- [ ] **Step 2: Push + open PR**

```bash
git push origin feat/kubevirt-deployment
gh pr create --fill
```

- [ ] **Step 3: Report**

Expected: PR URL printed. Do **not** merge — merging and deploying requires the user's explicit order (AGENTS.md explicit-orders gates).

---

### Task 6: Deploy + smoke test (post-merge, cluster verification)

Requires: PR merged (user order) and Flux reconciliation. Runs on the live cluster.

- [ ] **Step 1: Trigger reconciliation**

```bash
flux reconcile source git home-ops -n flux-system
flux reconcile kustomization cluster -n flux-system
flux reconcile kustomization kubevirt-operator -n kubevirt
```
Wait ~1-2 min, then:
```bash
flux reconcile kustomization kubevirt-core -n kubevirt   # after operator ready
```

- [ ] **Step 2: Verify KubeVirt is deployed**

Run:
```bash
kubectl -n kubevirt get pods
kubectl -n kubevirt get kv kubevirt -o jsonpath='{.status.phase}{"\n"}'
kubectl -n kubevirt get ds -o custom-columns='NAME:.metadata.name,NODES:.status.desiredNumberScheduled,READY:.status.numberReady'
```
Expected: `virt-operator`, `virt-controller` (2), `virt-api` (2), `virt-handler` pods Running; phase `Deployed`; virt-handler DaemonSet desiredNumberScheduled=4, numberReady=4 (cp1-3 + w1), **not** on w2.

- [ ] **Step 3: Verify CDI is deployed**

Run:
```bash
kubectl -n cdi get pods
kubectl -n cdi get cdi cdi -o jsonpath='{.status.phase}{"\n"}'
```
Expected: `cdi-operator`, `cdi-deployment`, `cdi-apiserver`, `cdi-uploadproxy`, `cdi-cloner` Running; phase `Deployed`.

- [ ] **Step 4: Smoke-test a VM (ad-hoc, not committed)**

Run (adjust the SSH key to one you hold; use a throwaway test namespace):
```bash
kubectl create ns vms
cat <<'EOF' | kubectl apply -f -
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
        cpu: {cores: 2}
        resources: {requests: {memory: 2Gi}}
        machine: {type: q35}
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
          dataVolume: {name: debian-test-dv}
        - name: cloudinit
          cloudInitNoCloud:
            userData: |
              #cloud-config
              users:
                - name: admin
                  ssh_authorized_keys:
                    - <YOUR-PUBLIC-SSH-KEY>
                  sudo: ['ALL=(ALL) NOPASSWD:ALL']
                  shell: /bin/bash
              runcmd:
                - curl -fsSL https://tailscale.com/install.sh | sh
                - tailscale up
  dataVolumeTemplates:
    - metadata: {name: debian-test-dv}
      spec:
        storage:
          resources: {requests: {storage: 10Gi}}
          storageClassName: miroir-local
        source:
          http:
            url: https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-generic-amd64.qcow2
EOF
kubectl -n vms get dv -w          # Wait: Succeeded
kubectl -n vms get vmi -o wide    # Wait: Running; NODE is one of cp1-3/w1 (never w2)
```

- [ ] **Step 5: Verify VM connectivity**

First install virtctl (workstation, krew — default per spec §5.3):

```bash
kubectl krew install virt
kubectl virt version   # client v1.9.0
```

Then:
```bash
kubectl virt console debian-test -n vms     # login as admin
# inside guest:
curl -I https://cloud.debian.org            # outbound NAT works
sudo tailscale status                       # tailnet access works
```
Expected: outbound internet from the VM; tailscale up; SSH to the guest via its tailnet hostname from the workstation.

- [ ] **Step 6: Confirm remaining physical nodes expose /dev/kvm**

Run (spec §9 risk item — cp1/w1 verified pre-spec; confirm cp2/cp3):
```bash
talosctl -n 192.168.2.22 ls /dev/ | grep -E "kvm|vhost"   # cp2
 talosctl -n 192.168.2.23 ls /dev/ | grep -E "kvm|vhost"   # cp3
```
Expected: `kvm` and `vhost-net` present on both (matches the VMX NFD label; if absent, stop and report — the spec assumes VMX label = /dev/kvm).

- [ ] **Step 7: Clean up the test VM**

```bash
kubectl delete vm debian-test -n vms
kubectl delete ns vms
```

- [ ] **Step 8: Report results**

Expected: paste the outputs of Steps 2-3 and the smoke test, then assert success (verification-before-completion).
