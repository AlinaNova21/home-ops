# Konflate Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deploy Konflate 0.4.3 as a public PR-diff UI for `AlinaNova21/home-ops` using GitHub App credentials for forge auth (read + write path).

**Architecture:** Flux `Kustomization/konflate` (namespace `default`) renders a `HelmRelease/konflate` (chart `konflate` 0.4.3 from the shared `home-operations` OCI registry). GitHub App credentials (`appClientId`, `appPrivateKey`) are synced from 1Password Connect into `Secret/konflate-github-app` and injected into the HelmRelease via two `valuesFrom` entries. Konflate is exposed on the external Gateway (Cloudflare Tunnel) at `konflate.whoverse.nexus` via a single `HTTPRoute`.

**Tech Stack:** Flux CD, HelmRelease v2, External Secrets Operator, Envoy Gateway (Gateway API v1), `bjw-s`-style conventions.

---

## File structure

```
kubernetes/default/konflate/
├── ks.yaml
└── app/
    ├── helmrelease.yaml
    ├── externalsecret.yaml
    ├── httproute.yaml
    └── kustomization.yaml

kubernetes/default/kustomization.yaml     # append `konflate/ks.yaml`
```

No changes to `kubernetes/flux-config/registry/helm/*`, `kubernetes/kustomization.yaml` (top-level), `kubernetes/auth/security-policies/*`, Renovate config, or any Talos / bootstrap file.

---

### Task 1: Component `ks.yaml`

**Files:**
- Create: `kubernetes/default/konflate/ks.yaml`

- [ ] **Step 1: Write the Flux Kustomization**

```yaml
---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: konflate
  namespace: default
spec:
  interval: 30m
  path: ./default/konflate/app
  sourceRef:
    kind: OCIRepository
    name: home-ops
    namespace: flux-system
  timeout: 10m
  wait: true
  prune: false
```

- [ ] **Step 2: Verify metadata.namespace matches parent directory**

`metadata.namespace: default` matches `kubernetes/default/konflate/ks.yaml`. Pre-commit hook will enforce.

---

### Task 2: ExternalSecret for GitHub App credentials

**Files:**
- Create: `kubernetes/default/konflate/app/externalsecret.yaml`

- [ ] **Step 1: Write the ExternalSecret**

```yaml
---
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: konflate-github-app
  namespace: default
spec:
  refreshInterval: 1h
  secretStoreRef:
    kind: ClusterSecretStore
    name: onepassword-connect
  target:
    name: konflate-github-app
    creationPolicy: Owner
  data:
    - secretKey: appClientId
      remoteRef:
        key: konflate-github-app
        property: appClientId
    - secretKey: appPrivateKey
      remoteRef:
        key: konflate-github-app
        property: appPrivateKey
```

---

### Task 3: HelmRelease

**Files:**
- Create: `kubernetes/default/konflate/app/helmrelease.yaml`

- [ ] **Step 1: Write the HelmRelease**

```yaml
---
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: konflate
  namespace: default
spec:
  interval: 30m
  chart:
    spec:
      chart: konflate
      version: "0.4.3"
      sourceRef:
        kind: HelmRepository
        name: home-operations
        namespace: flux-system
      interval: 12h
  install:
    remediation:
      retries: 3
    strategy:
      name: RetryOnFailure
      retryInterval: 5m
  upgrade:
    remediation:
      retries: 3
    strategy:
      name: RetryOnFailure
      retryInterval: 5m
  valuesFrom:
    - kind: Secret
      name: konflate-github-app
      valuesKey: appClientId
      targetPath: secret.appClientId
    - kind: Secret
      name: konflate-github-app
      valuesKey: appPrivateKey
      targetPath: secret.appPrivateKey
  values:
    replicaCount: 1
    serviceAccount:
      automount: false
    persistence:
      enabled: true
      size: 5Gi
      storageClass: ceph-rbd
      accessModes:
        - ReadWriteOnce
    podDisruptionBudget:
      enabled: true
      maxUnavailable: 1
    config:
      repo: github://AlinaNova21/home-ops
      statusChecks: true
      prComments: true
      publicUrl: https://konflate.whoverse.nexus
```

---

### Task 4: HTTPRoute (external Gateway)

**Files:**
- Create: `kubernetes/default/konflate/app/httproute.yaml`

- [ ] **Step 1: Write the HTTPRoute**

```yaml
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: konflate
  namespace: default
spec:
  parentRefs:
    - name: external
      namespace: network
      sectionName: http
  hostnames:
    - konflate.whoverse.nexus
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /
      backendRefs:
        - name: konflate
          port: 8080
```

---

### Task 5: App-level kustomization

**Files:**
- Create: `kubernetes/default/konflate/app/kustomization.yaml`

- [ ] **Step 1: Write the kustomization**

```yaml
---
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - helmrelease.yaml
  - externalsecret.yaml
  - httproute.yaml
```

---

### Task 6: Wire into namespace kustomization

**Files:**
- Modify: `kubernetes/default/kustomization.yaml`

- [ ] **Step 1: Append `konflate/ks.yaml`**

Add a new line after the last existing component entry (after `mailpit/ks.yaml`):

```yaml
  - konflate/ks.yaml
```

Final file:

```yaml
---
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ns.yaml
  - barcodebuddy/ks.yaml
  - database/ks.yaml
  - error-pages/ks.yaml
  - grocy/ks.yaml
  - konflate/ks.yaml
  - mailpit/ks.yaml
  #- memos/ks.yaml
  - speedtest-tracker/ks.yaml
```

(Alphabetical ordering; `konflate` between `grocy` and `mailpit`.)

---

### Task 7: Local validation

- [ ] **Step 1: Run kustomize + kubeconform**

```bash
kustomize build kubernetes/default/konflate | kubeconform -strict -ignore-missing-schemas \
  -schema-location default \
  -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'

kustomize build kubernetes | kubeconform -strict -ignore-missing-schemas \
  -schema-location default \
  -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'
```

Expected: no schema violations, all resources listed.

- [ ] **Step 2: Run pre-commit**

```bash
pre-commit run --files kubernetes/default/konflate kubernetes/default/kustomization.yaml
```

Expected: gitleaks + trufflehog pass; structure hook (ns.yaml ordering, ks.yaml metadata.namespace) passes.

---

### Task 8: Commit + push

- [ ] **Step 1: Stage and commit**

```bash
git add kubernetes/default/konflate kubernetes/default/kustomization.yaml \
        docs/superpowers/specs/2026-07-25-konflate-deployment-design.md \
        docs/superpowers/plans/2026-07-25-konflate-deployment.md
git commit -m "feat(konflate): deploy konflate 0.4.3 to render PR diffs"
git push -u origin feat/konflate
```

The OCI artifact auto-builds on push to a branch (`kubernetes-oci.yml` workflow
runs on all branches) and Flux reconciles the cluster.

---

### Task 9: One-time 1Password item creation (operator, manual)

These are not in the repo.

- [ ] **Step 1: Create the 1Password item**

Create item `konflate-github-app` in the operator's vault with two text fields:

| Field | Value |
|---|---|
| `appClientId` | The GitHub App's client id (e.g. `Iv23li...`) |
| `appPrivateKey` | The PEM private key, paste with original line breaks |

- [ ] **Step 2: Confirm the App installation**

GitHub → Settings → Developer settings → GitHub Apps → the App → Install App →
`AlinaNova21/home-ops` is in the installed list.

---

### Task 10: Post-deploy verification

- [ ] **Step 1: Force reconcile + observe**

```bash
flux reconcile kustomization cluster -n flux-system
flux get hr -n default konflate
kubectl get externalsecret -n default konflate-github-app
kubectl get secret -n default konflate-github-app
kubectl get pods -n default -l app.kubernetes.io/name=konflate
```

Expected: `HelmRelease Ready: True`, `ExternalSecret Ready: True`,
`Secret/konflate-github-app` present, pod `Running`.

- [ ] **Step 2: Public smoke test**

```bash
curl -fsS https://konflate.whoverse.nexus/api/meta | jq '.features'
```

Expected: response includes `statusChecks` and `prComments` enabled.

- [ ] **Step 3: Confirm the App installation was auto-detected**

```bash
kubectl logs -n default -l app.kubernetes.io/name=konflate | grep -i 'github app'
```

Expected: log line stating the App installation id for
`AlinaNova21/home-ops`.

- [ ] **Step 4: Open or refresh a test PR; observe**

Open (or push to) an open PR on `AlinaNova21/home-ops`. Within
`KONFLATE_REFRESH_INTERVAL` (30m default) or on webhook / push:
- A commit status `Konflate` appears on the PR head.
- A summary comment appears on the PR (Konflate edits it in place on
  subsequent renders).

---

## Self-review

**1. Spec coverage:**
- Goals (read + write, public) → Tasks 3, 9.
- GitHub App credentials synced from 1Password → Tasks 2, 3, 9.
- External Gateway exposure → Task 4.
- Validation hooks (kustomize, kubeconform, pre-commit, Flux) → Task 7.
- Post-deploy smoke tests → Task 10.

**2. Placeholder scan:** no TBD/TODO; every step has concrete code.

**3. Type / naming consistency:**
- HelmRelease `metadata.name: konflate`, Flux `Kustomization` `metadata.name: konflate`, ExternalSecret `metadata.name: konflate-github-app`, HTTPRoute `metadata.name: konflate`, Service target `name: konflate` (chart default from release name) — consistent.
- `valuesFrom.valuesKey` matches `ExternalSecret.data.secretKey` (`appClientId`, `appPrivateKey`) — consistent.
- `valuesFrom.targetPath: secret.appPrivateKey` matches the chart's expected values key (`secret.appPrivateKey`); all four layers (1Password field, ExternalSecret property, Secret data key, HelmRelease valuesKey) share the same `appPrivateKey` label.
- 1Password item key matches `ExternalSecret.remoteRef.key` (`konflate-github-app`) — consistent.
