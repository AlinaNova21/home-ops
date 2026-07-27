# Origin CA Issuer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Switch the external Gateway (`*.whoverse.nexus`) to HTTPS-only using Cloudflare Origin CA certs auto-issued by `origin-ca-issuer` and auto-rotated weekly by cert-manager.

**Architecture:** Two-phase rollout. Phase 1 adds `origin-ca-issuer` (controller, OriginIssuer, separate ExternalSecret) and a new `https` listener on the existing external Gateway with cert-manager annotations; the existing `http` listener stays. Phase 2 switches cloudflared origins to `https://envoy-external:443`, flips 9 HTTPRoutes from `sectionName: http` → `https`, then drops the `http` listener.

**Tech Stack:** Flux CD v2 (OCIRepository + HelmRelease + Kustomization), cert-manager with Gateway API integration, External Secrets Operator, cloudflare/origin-ca-issuer (Helm chart), Envoy Gateway (`gateway.networking.k8s.io/v1`), 1Password Connect (`ClusterSecretStore`).

**Reference spec:** `docs/superpowers/specs/2026-07-27-origin-ca-issuer-design.md`

---

## File structure

```
kubernetes/
├── cert-manager/
│   ├── kustomization.yaml                   # EDIT — add origin-ca-issuer/ks.yaml
│   └── origin-ca-issuer/                    # NEW
│       ├── ks.yaml                          # NEW
│       ├── app/
│       │   ├── kustomization.yaml           # NEW
│       │   ├── ocirepository.yaml           # NEW
│       │   └── helmrelease.yaml             # NEW
│       └── config/
│           ├── kustomization.yaml           # NEW
│           ├── externalsecret.yaml          # NEW
│           └── originissuer.yaml            # NEW
└── network/
    └── envoy-gateway/
        ├── ks.yaml                          # EDIT — dependsOn origin-ca-issuer-config
        └── config/
            └── gateway.yaml                 # EDIT Phase 1: +annotations, +https listener
                                             # EDIT Phase 2: −http listener
```

Phase 2 also edits 9 HTTPRoutes (one-line change each: `sectionName: http` → `https`):
- `kubernetes/entertainment/jellyfin/app/httproute.yaml`
- `kubernetes/auth/dex-external/app/httproute.yaml`
- `kubernetes/default/barcodebuddy/app/httproute.yaml`
- `kubernetes/default/error-pages/app-external/httproute.yaml`
- `kubernetes/default/grocy/app/httproute.yaml`
- `kubernetes/default/konflate/app/httproute.yaml`
- `kubernetes/default/yuvomi/app/httproute.yaml`
- `kubernetes/flux-system/webhook/app/webhook-httproute.yaml`
- `kubernetes/downloads/seerr/app/httproute.yaml` (only the external parentRef; keep internal http+https)

---

## Conventions

- **Naming**: `metadata.namespace` on every `Kustomization` matches the parent directory under `kubernetes/`.
- **Flux reconcile**: after every push, force-reconcile the affected Kustomizations so the change is picked up immediately rather than waiting for the poll interval.
- **Validation**: `kustomize build | kubeconform` from AGENTS.md Validation section.
- **Commits**: each task ends with a commit; no mega-commits.

---

## Phase 1 — Deploy origin-ca-issuer and add HTTPS listener

### Task 1: `OCIRepository` for origin-ca-issuer chart

**Files:**
- Create: `kubernetes/cert-manager/origin-ca-issuer/app/ocirepository.yaml`

- [ ] **Step 1: Write the OCIRepository**

```yaml
---
apiVersion: source.toolkit.fluxcd.io/v1
kind: OCIRepository
metadata:
  name: origin-ca-issuer
  namespace: cert-manager
spec:
  interval: 1h
  layerSelector:
    mediaType: application/vnd.cncf.helm.chart.content.v1.tar+gzip
    operation: copy
  ref:
    digest: "sha256:c4d346a0a9126e7c61670907179409eb0ac7655d64a8c62d59832f232986187a"
  url: oci://ghcr.io/cloudflare/origin-ca-issuer-charts/origin-ca-issuer
```

- [ ] **Step 2: Verify YAML parses**

```bash
yq eval '.' kubernetes/cert-manager/origin-ca-issuer/app/ocirepository.yaml
```

Expected: parses without error; `kind: OCIRepository`, `metadata.name: origin-ca-issuer`, `metadata.namespace: cert-manager`.

---

### Task 2: `HelmRelease` for origin-ca-issuer

**Files:**
- Create: `kubernetes/cert-manager/origin-ca-issuer/app/helmrelease.yaml`

- [ ] **Step 1: Write the HelmRelease**

```yaml
---
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: origin-ca-issuer
  namespace: cert-manager
spec:
  interval: 30m
  chartRef:
    kind: OCIRepository
    name: origin-ca-issuer
    namespace: cert-manager
  install:
    createNamespace: false
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
  values:
    replicaCount: 1
    resources:
      requests:
        cpu: 10m
        memory: 64Mi
      limits:
        memory: 128Mi
```

- [ ] **Step 2: Verify the file parses and references the OCIRepository**

```bash
yq eval '.spec.chartRef.name' kubernetes/cert-manager/origin-ca-issuer/app/helmrelease.yaml
```

Expected: `origin-ca-issuer`.

---

### Task 3: `kustomization.yaml` for the app dir

**Files:**
- Create: `kubernetes/cert-manager/origin-ca-issuer/app/kustomization.yaml`

- [ ] **Step 1: Write the kustomization**

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ocirepository.yaml
  - helmrelease.yaml
```

---

### Task 4: `ExternalSecret` for the Origin CA token

**Files:**
- Create: `kubernetes/cert-manager/origin-ca-issuer/config/externalsecret.yaml`

- [ ] **Step 1: Write the ExternalSecret**

```yaml
---
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: cloudflare-origin-ca-token
  namespace: cert-manager
spec:
  refreshInterval: 1h
  secretStoreRef:
    kind: ClusterSecretStore
    name: onepassword-connect
  target:
    name: cloudflare-origin-ca-token
    creationPolicy: Owner
  data:
    - secretKey: api-token
      remoteRef:
        key: cloudflare-api-token
        property: credential
```

- [ ] **Step 2: Verify `secretKey` matches the OriginIssuer `ref.key`**

The OriginIssuer in Task 5 reads `ref.key: api-token`. The `secretKey: api-token` here writes into the Secret under the same key. If they ever diverge, the OriginIssuer will fail to find the token.

---

### Task 5: `OriginIssuer` cluster resource

**Files:**
- Create: `kubernetes/cert-manager/origin-ca-issuer/config/originissuer.yaml`

- [ ] **Step 1: Write the OriginIssuer**

```yaml
---
apiVersion: origin-ca-issuer.io/v1
kind: OriginIssuer
metadata:
  name: cloudflare-origin
spec:
  requestDuration: 0
  ref:
    name: cloudflare-origin-ca-token
    namespace: cert-manager
    key: api-token
```

- [ ] **Step 2: Verify the API group is `origin-ca-issuer.io` and `kind: OriginIssuer`**

```bash
yq eval '.apiVersion, .kind, .metadata.name' kubernetes/cert-manager/origin-ca-issuer/config/originissuer.yaml
```

Expected:
```
origin-ca-issuer.io/v1
OriginIssuer
cloudflare-origin
```

Note: `requestDuration: 0` means "use the requesting Certificate's `spec.duration`". The 7-day duration is set via Gateway annotation in Task 8, not here.

---

### Task 6: `kustomization.yaml` for the config dir

**Files:**
- Create: `kubernetes/cert-manager/origin-ca-issuer/config/kustomization.yaml`

- [ ] **Step 1: Write the kustomization**

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - externalsecret.yaml
  - originissuer.yaml
```

---

### Task 7: `ks.yaml` with both Flux Kustomizations

**Files:**
- Create: `kubernetes/cert-manager/origin-ca-issuer/ks.yaml`

- [ ] **Step 1: Write the Kustomizations**

```yaml
---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: origin-ca-issuer
  namespace: cert-manager
spec:
  interval: 30m
  path: "./cert-manager/origin-ca-issuer/app"
  sourceRef:
    kind: OCIRepository
    name: home-ops
    namespace: flux-system
  healthChecks:
    - apiVersion: apps/v1
      kind: Deployment
      name: origin-ca-issuer
      namespace: cert-manager
  timeout: 10m
  wait: true
  prune: true
---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: origin-ca-issuer-config
  namespace: cert-manager
spec:
  dependsOn:
    - name: cert-manager-config
      namespace: cert-manager
    - name: external-secrets-config
      namespace: external-secrets-system
  interval: 10m
  path: "./cert-manager/origin-ca-issuer/config"
  sourceRef:
    kind: OCIRepository
    name: home-ops
    namespace: flux-system
  timeout: 5m
  wait: true
  prune: true
```

- [ ] **Step 2: Verify `metadata.namespace` matches the parent directory**

`metadata.namespace: cert-manager` matches `kubernetes/cert-manager/origin-ca-issuer/ks.yaml`. The pre-commit hook enforces this.

---

### Task 8: Wire origin-ca-issuer into the cert-manager namespace aggregator

**Files:**
- Modify: `kubernetes/cert-manager/kustomization.yaml`

- [ ] **Step 1: Read the current file**

```bash
cat kubernetes/cert-manager/kustomization.yaml
```

Expected: contains `ns.yaml` and `cert-manager/ks.yaml` as resources.

- [ ] **Step 2: Add the origin-ca-issuer Kustomizations**

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ns.yaml
  - cert-manager/ks.yaml
  - origin-ca-issuer/ks.yaml
```

---

### Task 9: Local validation — kustomize + kubeconform for Phase 1 stack

- [ ] **Step 1: Render the cert-manager namespace subtree**

```bash
kustomize build kubernetes/cert-manager | tee /tmp/kustomize-cert-manager.yaml | wc -l
```

Expected: non-zero line count; YAML parses cleanly.

- [ ] **Step 2: Validate against schemas**

```bash
kustomize build kubernetes/cert-manager | kubeconform \
  -strict \
  -ignore-missing-schemas \
  -schema-location default \
  -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'
```

Expected: `Summary: ... resources found in ... files - Passed` with zero failures. `OriginIssuer` CRD won't be in the CRDs-catalog schema, so `ignore-missing-schemas` will skip it — that's expected.

- [ ] **Step 3: Pre-commit hook on the changed files**

```bash
pre-commit run --files \
  kubernetes/cert-manager/kustomization.yaml \
  kubernetes/cert-manager/origin-ca-issuer/
```

Expected: `gitleaks` and `trufflehog` pass. (Hook also enforces structure rules; `metadata.namespace` mismatches will surface here.)

---

### Task 10: Commit, push, reconcile, verify origin-ca-issuer stack

- [ ] **Step 1: Commit**

```bash
git add kubernetes/cert-manager/kustomization.yaml kubernetes/cert-manager/origin-ca-issuer/
git commit -m "feat(cert-manager): add origin-ca-issuer controller + OriginIssuer"
git push
```

- [ ] **Step 2: Wait for OCI artifact build**

```bash
gh run list --workflow kubernetes-oci.yml --limit 1 --json status,conclusion,headSha --jq '.[0]'
```

Expected: `conclusion: success` for the latest run.

- [ ] **Step 3: Force-reconcile the cluster root**

```bash
flux reconcile kustomization cluster -n flux-system --with-source
```

- [ ] **Step 4: Wait for the two Kustomizations to be Ready**

```bash
flux get kustomizations -A | grep -E 'origin-ca-issuer\b|origin-ca-issuer-config'
```

Expected: both report `Ready: True`. First poll may take ~30s.

- [ ] **Step 5: Verify the controller pod is Running**

```bash
kubectl get pods -n cert-manager -l app.kubernetes.io/name=origin-ca-issuer
```

Expected: `1/1 Running`.

- [ ] **Step 6: Verify the Secret and OriginIssuer exist**

```bash
kubectl get secret -n cert-manager cloudflare-origin-ca-token
kubectl get originissuer
```

Expected:
- Secret exists with 1 data key (`api-token`)
- `NAME             AGE\ncloudflare-origin ...`

---

### Task 11: Add HTTPS listener + cert-manager annotations to external Gateway

**Files:**
- Modify: `kubernetes/network/envoy-gateway/config/gateway.yaml` (lines 12-33)

- [ ] **Step 1: Read the current external Gateway block**

```bash
sed -n '12,33p' kubernetes/network/envoy-gateway/config/gateway.yaml
```

- [ ] **Step 2: Replace the external Gateway block with the annotated, dual-listener version**

```yaml
---
# External Gateway - accessed via Cloudflare Tunnel
# TLS terminated at origin using a Cloudflare Origin CA cert (cloudflared trusts it natively).
# HTTPRoutes remain bound to sectionName: http during Phase 1; both listeners coexist until Phase 2.
# Uses ClusterIP since it's only accessed by cloudflared internally.
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: external
  namespace: network
  annotations:
    external-dns.alpha.kubernetes.io/target: 87927ee2-ef79-4dbc-8a1f-dca865b82b79.cfargotunnel.com
    cert-manager.io/cluster-issuer: cloudflare-origin
    cert-manager.io/duration: 168h
    cert-manager.io/renew-before: 24h
spec:
  gatewayClassName: eg
  infrastructure:
    parametersRef:
      group: gateway.envoyproxy.io
      kind: EnvoyProxy
      name: external-proxy-config
  listeners:
    - name: http
      protocol: HTTP
      port: 80
      hostname: "*.whoverse.nexus"
      allowedRoutes:
        namespaces:
          from: All
    - name: https
      protocol: HTTPS
      port: 443
      hostname: "*.whoverse.nexus"
      tls:
        mode: Terminate
        certificateRefs:
          - name: whoverse-nexus-wildcard-tls
            kind: Secret
      allowedRoutes:
        namespaces:
          from: All
```

- [ ] **Step 3: Verify the internal Gateway block is unchanged**

```bash
sed -n '34,$p' kubernetes/network/envoy-gateway/config/gateway.yaml
```

Expected: internal Gateway block (`metadata.name: internal`) is untouched.

---

### Task 12: Add origin-ca-issuer-config to envoy-gateway-config dependsOn

**Files:**
- Modify: `kubernetes/network/envoy-gateway/ks.yaml` (the `envoy-gateway-config` Kustomization block)

- [ ] **Step 1: Read the current file**

```bash
cat kubernetes/network/envoy-gateway/ks.yaml
```

- [ ] **Step 2: Add the new dependsOn entry**

The `envoy-gateway-config` Kustomization's `spec.dependsOn` currently has two entries (`envoy-gateway`, `cert-manager-config`). Insert a third:

```yaml
spec:
  dependsOn:
    - name: envoy-gateway
    - name: cert-manager-config
      namespace: cert-manager
    - name: origin-ca-issuer-config      # NEW
      namespace: cert-manager
  interval: 10m
  path: "./network/envoy-gateway/config"
  sourceRef:
    kind: OCIRepository
    name: home-ops
    namespace: flux-system
  timeout: 5m
  wait: true
  prune: true
```

- [ ] **Step 3: Verify yaml structure**

```bash
yq eval '. | select(.metadata.name == "envoy-gateway-config") | .spec.dependsOn' kubernetes/network/envoy-gateway/ks.yaml
```

Expected: 3 entries, with `origin-ca-issuer-config` last.

---

### Task 13: Validate, commit, push, verify Certificate issuance

- [ ] **Step 1: Render and validate the envoy-gateway config**

```bash
kustomize build kubernetes/network/envoy-gateway/config | kubeconform \
  -strict \
  -ignore-missing-schemas \
  -schema-location default \
  -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'
```

Expected: passes. The auto-generated Certificate is reconciled by cert-manager, not present in the kustomize output — that's fine.

- [ ] **Step 2: Render and validate the top-level aggregator**

```bash
kustomize build kubernetes | kubeconform \
  -strict \
  -ignore-missing-schemas \
  -schema-location default \
  -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'
```

Expected: passes.

- [ ] **Step 3: Pre-commit on changed files**

```bash
pre-commit run --files \
  kubernetes/network/envoy-gateway/ks.yaml \
  kubernetes/network/envoy-gateway/config/gateway.yaml
```

- [ ] **Step 4: Commit**

```bash
git add kubernetes/network/envoy-gateway/ks.yaml kubernetes/network/envoy-gateway/config/gateway.yaml
git commit -m "feat(gateway): add HTTPS listener on external Gateway with Origin CA cert"
git push
```

- [ ] **Step 5: Wait for OCI artifact**

```bash
gh run list --workflow kubernetes-oci.yml --limit 1 --json status,conclusion --jq '.[0].conclusion'
```

Expected: `success`.

- [ ] **Step 6: Force-reconcile and wait for envoy-gateway-config**

```bash
flux reconcile kustomization envoy-gateway-config -n network --with-source
flux get kustomizations -n network envoy-gateway-config
```

Expected: `Ready: True` within ~30s.

- [ ] **Step 7: Verify Certificate was created and is Ready**

```bash
kubectl get certificate -n network whoverse-nexus-wildcard-tls
```

Expected: `READY True`, `SECRET NAME whoverse-nexus-wildcard-tls`.

- [ ] **Step 8: Verify the issued cert details**

```bash
kubectl get secret -n network whoverse-nexus-wildcard-tls \
  -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -noout -subject -issuer -dates
```

Expected:
- `subject=` contains `*.whoverse.nexus` (in SAN)
- `issuer=` shows `O = Cloudflare, Inc., OU = Origin CA`
- `notAfter=` is approximately 7 days from now

- [ ] **Step 9: Verify the Envoy Service gained port 443**

```bash
kubectl get svc -n network envoy-external -o jsonpath='{.spec.ports[*].port}'
```

Expected: `80 443`.

- [ ] **Step 10: Smoke test HTTPS from inside the cluster**

```bash
kubectl run curl --rm -it --restart=Never --image=curlimages/curl -- \
  curl -sv --resolve jellyfin.whoverse.nexus:443:$(kubectl get svc envoy-external -n network -o jsonpath='{.spec.clusterIP}') \
  https://jellyfin.whoverse.nexus/health 2>&1 | grep -E 'subject|issuer|HTTP/'
```

Expected: TLS handshake succeeds, `issuer: Cloudflare` in cert details, `HTTP/2 200` (or a `302`/`4xx` is fine — just proof of TLS termination).

- [ ] **Step 11: Confirm existing HTTP path is unaffected**

```bash
kubectl run curl --rm -it --restart=Never --image=curlimages/curl -- \
  curl -sI --resolve jellyfin.whoverse.nexus:80:$(kubectl get svc envoy-external -n network -o jsonpath='{.spec.clusterIP}') \
  http://jellyfin.whoverse.nexus/ 2>&1 | head -5
```

Expected: HTTP/1.1 or HTTP/2 response — proves the http listener still serves traffic and no HTTPRoute got broken by the listener add.

**Phase 1 complete.** Stop here. Do not proceed to Phase 2 until the Certificate is `Ready` and the HTTPS smoke test passes.

---

## Phase 2 — Switchover and remove HTTP listener

### Task 14: Switch cloudflared tunnel origins to HTTPS

This task is **out-of-band** — the Cloudflare tunnel config is managed in the Cloudflare dashboard / API, not in this repo.

- [ ] **Step 1: Open the Cloudflare Zero Trust dashboard**

URL: `https://one.dash.cloudflare.com/.../networks/tunnels`

- [ ] **Step 2: Edit the tunnel's public hostnames**

For each `*.whoverse.nexus` public hostname in the tunnel config:
- Service: `https://envoy-external.network.svc.cluster.local:443`
  - (or `https://envoy-external:443` — Cloudflare accepts the short form)

Verify all `*.whoverse.nexus` entries are updated; tunnel config supports per-hostname origins.

- [ ] **Step 3: Save and wait for cloudflared to pick up the new config**

cloudflared polls Cloudflare every ~30s in token mode; no pod restart required.

- [ ] **Step 4: Verify cloudflared is connecting to HTTPS**

```bash
kubectl logs -n network -l app.kubernetes.io/name=cloudflared --tail 50 | grep -iE 'origin|https|h2|connected'
```

Expected: log lines indicating HTTPS/h2 connections to envoy-external:443.

- [ ] **Step 5: Smoke test an external hostname**

```bash
curl -svI https://jellyfin.whoverse.nexus 2>&1 | grep -E 'HTTP|subject|issuer'
```

Expected: `HTTP/2 200` (or app-specific response code). TLS terminates at Envoy.

---

### Task 15: Flip 9 HTTPRoutes' external parentRef sectionName

- [ ] **Step 1: Edit each file**

For each file, change the `parentRefs` block's external entry from `sectionName: http` to `sectionName: https`. **Internal Gateway parentRefs are unchanged.** For `seerr`, only the third parentRef (the external one) changes.

```yaml
# kubernetes/entertainment/jellyfin/app/httproute.yaml (EDIT)
parentRefs:
  - name: external
    namespace: network
    sectionName: https    # was: http
```

```yaml
# kubernetes/auth/dex-external/app/httproute.yaml (EDIT)
parentRefs:
  - name: external
    namespace: network
    sectionName: https    # was: http
```

```yaml
# kubernetes/default/barcodebuddy/app/httproute.yaml (EDIT)
parentRefs:
  - name: external
    namespace: network
    sectionName: https    # was: http
```

```yaml
# kubernetes/default/error-pages/app-external/httproute.yaml (EDIT)
parentRefs:
  - name: external
    namespace: network
    sectionName: https    # was: http
```

```yaml
# kubernetes/default/grocy/app/httproute.yaml (EDIT)
parentRefs:
  - name: external
    namespace: network
    sectionName: https    # was: http
```

```yaml
# kubernetes/default/konflate/app/httproute.yaml (EDIT)
parentRefs:
  - name: external
    namespace: network
    sectionName: https    # was: http
```

```yaml
# kubernetes/default/yuvomi/app/httproute.yaml (EDIT)
parentRefs:
  - name: external
    namespace: network
    sectionName: https    # was: http
```

```yaml
# kubernetes/flux-system/webhook/app/webhook-httproute.yaml (EDIT)
parentRefs:
  - name: external
    namespace: network
    sectionName: https    # was: http
```

```yaml
# kubernetes/downloads/seerr/app/httproute.yaml (EDIT)
parentRefs:
  - name: internal
    namespace: network
    sectionName: http
  - name: internal
    namespace: network
    sectionName: https
  - name: external         # only this parentRef changes
    namespace: network
    sectionName: https    # was: http
```

- [ ] **Step 2: Confirm 9 files contain `sectionName: https` and none of them contain a stale external `sectionName: http`**

```bash
grep -l 'name: external' $(git diff --name-only HEAD) | xargs grep -A 3 'parentRefs:'
```

Expected: every external parentRef shows `sectionName: https`.

---

### Task 16: Validate, commit, push, verify HTTPS works

- [ ] **Step 1: Render and validate the top-level aggregator**

```bash
kustomize build kubernetes | kubeconform \
  -strict \
  -ignore-missing-schemas \
  -schema-location default \
  -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'
```

Expected: passes.

- [ ] **Step 2: Pre-commit on changed files**

```bash
pre-commit run --files $(git diff --name-only HEAD)
```

- [ ] **Step 3: Commit**

```bash
git add kubernetes/entertainment/jellyfin/app/httproute.yaml \
        kubernetes/auth/dex-external/app/httproute.yaml \
        kubernetes/default/barcodebuddy/app/httproute.yaml \
        kubernetes/default/error-pages/app-external/httproute.yaml \
        kubernetes/default/grocy/app/httproute.yaml \
        kubernetes/default/konflate/app/httproute.yaml \
        kubernetes/default/yuvomi/app/httproute.yaml \
        kubernetes/flux-system/webhook/app/webhook-httproute.yaml \
        kubernetes/downloads/seerr/app/httproute.yaml
git commit -m "feat(routes): bind external HTTPRoutes to https listener"
git push
```

- [ ] **Step 4: Wait for OCI artifact**

```bash
gh run list --workflow kubernetes-oci.yml --limit 1 --json conclusion --jq '.[0].conclusion'
```

Expected: `success`.

- [ ] **Step 5: Force-reconcile and wait**

```bash
flux reconcile kustomization envoy-gateway-config -n network --with-source
flux get kustomizations -n network envoy-gateway-config
```

Expected: `Ready: True`.

- [ ] **Step 6: Verify HTTPRoutes bound to https listener**

```bash
kubectl get httproutes -A \
  --selector gateway.networking.k8s.io/gateway-name=external \
  -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name} -> {.spec.parentRefs[*].sectionName}{"\n"}{end}'
```

Expected: every line ends in `https`.

- [ ] **Step 7: Smoke test a few external hostnames**

```bash
for h in jellyfin.whoverse.nexus barcodebuddy.whoverse.nexus grocy.whoverse.nexus seerr.whoverse.nexus; do
  echo "=== $h ==="
  curl -sI -o /dev/null -w "%{http_code}\n" "https://$h"
done
```

Expected: `200` (or `302`/`401`/`403` for apps requiring auth — anything but TLS error or connection refused).

---

### Task 17: Remove the http listener from the external Gateway

**Files:**
- Modify: `kubernetes/network/envoy-gateway/config/gateway.yaml` (drop the `http` listener block under the `external` Gateway)

- [ ] **Step 1: Read the current external Gateway block**

```bash
sed -n '12,50p' kubernetes/network/envoy-gateway/config/gateway.yaml
```

- [ ] **Step 2: Remove the `http` listener and update the comment**

```yaml
---
# External Gateway - accessed via Cloudflare Tunnel
# TLS terminated at origin using a Cloudflare Origin CA cert (cloudflared trusts it natively).
# Uses ClusterIP since it's only accessed by cloudflared internally.
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: external
  namespace: network
  annotations:
    external-dns.alpha.kubernetes.io/target: 87927ee2-ef79-4dbc-8a1f-dca865b82b79.cfargotunnel.com
    cert-manager.io/cluster-issuer: cloudflare-origin
    cert-manager.io/duration: 168h
    cert-manager.io/renew-before: 24h
spec:
  gatewayClassName: eg
  infrastructure:
    parametersRef:
      group: gateway.envoyproxy.io
      kind: EnvoyProxy
      name: external-proxy-config
  listeners:
    - name: https
      protocol: HTTPS
      port: 443
      hostname: "*.whoverse.nexus"
      tls:
        mode: Terminate
        certificateRefs:
          - name: whoverse-nexus-wildcard-tls
            kind: Secret
      allowedRoutes:
        namespaces:
          from: All
```

- [ ] **Step 3: Verify the internal Gateway block is unchanged**

```bash
sed -n '/^# Internal Gateway/,$p' kubernetes/network/envoy-gateway/config/gateway.yaml
```

Expected: internal Gateway has both `http` and `https` listeners as before.

---

### Task 18: Validate, commit, push, verify final state

- [ ] **Step 1: Render and validate**

```bash
kustomize build kubernetes/network/envoy-gateway/config | kubeconform \
  -strict \
  -ignore-missing-schemas \
  -schema-location default \
  -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'
```

Expected: passes.

- [ ] **Step 2: Pre-commit**

```bash
pre-commit run --files kubernetes/network/envoy-gateway/config/gateway.yaml
```

- [ ] **Step 3: Commit**

```bash
git add kubernetes/network/envoy-gateway/config/gateway.yaml
git commit -m "feat(gateway): drop http listener on external Gateway (HTTPS-only)"
git push
```

- [ ] **Step 4: Wait for OCI artifact and force-reconcile**

```bash
gh run list --workflow kubernetes-oci.yml --limit 1 --json conclusion --jq '.[0].conclusion'
flux reconcile kustomization envoy-gateway-config -n network --with-source
flux get kustomizations -n network envoy-gateway-config
```

Expected: OCI `success`, then `Ready: True`.

- [ ] **Step 5: Verify port 80 is gone from envoy-external Service**

```bash
kubectl get svc -n network envoy-external -o jsonpath='{.spec.ports[*].port}'
```

Expected: `443` (only).

- [ ] **Step 6: Verify HTTP to envoy-external:80 now fails**

```bash
kubectl run curl --rm -it --restart=Never --image=curlimages/curl -- \
  curl -sv --resolve jellyfin.whoverse.nexus:80:$(kubectl get svc envoy-external -n network -o jsonpath='{.spec.clusterIP}') \
  http://jellyfin.whoverse.nexus/ 2>&1 | head -10
```

Expected: connection refused (or "no route to host") — port 80 is closed at the Service.

- [ ] **Step 7: Verify external hostnames still work over HTTPS**

```bash
for h in jellyfin.whoverse.nexus barcodebuddy.whoverse.nexus grocy.whoverse.nexus seerr.whoverse.nexus; do
  curl -sI -o /dev/null -w "$h: %{http_code}\n" "https://$h"
done
```

Expected: every hostname returns a non-zero HTTP code (not a TLS error).

---

## Rollback

| Phase | Action |
|---|---|
| Phase 1, partial (origin-ca-issuer broken) | Remove `origin-ca-issuer/ks.yaml` from `kubernetes/cert-manager/kustomization.yaml` and delete the `origin-ca-issuer` directory. OriginIssuer + Secret are pruned by `prune: true`. |
| Phase 1, partial (cert not issuing) | Remove the three cert-manager annotations and the `https` listener from `gateway.yaml`. The `http` listener keeps serving traffic. The Secret (if created) is orphaned — harmless; cleanup later. |
| Phase 2a (cloudflared switchover fails) | Revert the tunnel config in Cloudflare dashboard — point origins back at `http://envoy-external:80`. cloudflared reconnects to HTTP within ~30s. |
| Phase 2b (HTTPRoutes bound to https break things) | Revert the commit changing `sectionName: http` → `https` in the 9 HTTPRoutes. cloudflared still talks HTTP, HTTPRoutes rebind to `http` listener. |
| Phase 2c (after http listener removal) | Re-add the `http` listener block to the external Gateway in `gateway.yaml`. Envoy Gateway re-adds port 80 to the Service. Note: HTTPRoutes still bound to `https` won't get traffic unless cloudflared is also reverted; do Phase 2b first if a full rollback is needed. |

The 7-day cert means a missed rotation has bounded blast radius — the cert will simply expire, surfacing the misconfiguration as a TLS error rather than silently serving a stale trust path.

---

## Self-review checklist (run before declaring plan complete)

- [x] **Spec coverage**: every section of `2026-07-27-origin-ca-issuer-design.md` has a corresponding task:
  - §4 origin-ca-issuer stack → Tasks 1-7
  - §5 Gateway change (Phase 1) → Tasks 11-12
  - §6 cloudflared switchover → Task 14
  - §7 HTTPRoute flip → Tasks 15-16
  - §5 Gateway change (Phase 2 cleanup) → Tasks 17-18
  - §8 reconcile graph update → Task 12
  - §10 verification → Steps within Tasks 10, 13, 14, 16, 18
  - §11 rollback → Rollback table above
- [x] **Placeholder scan**: no "TBD", "TODO", "implement later". Every code block is complete; every file path is absolute from repo root.
- [x] **Type/key consistency**: `api-token` key in ExternalSecret matches `ref.key` in OriginIssuer. `OriginIssuer` kind matches what `cert-manager.io/cluster-issuer: cloudflare-origin` resolves to (cluster-scoped). Gateway `tls.certificateRefs[0].name: whoverse-nexus-wildcard-tls` matches the `Certificate.spec.secretName` auto-set by cert-manager from the annotation.
- [x] **Bite-sized steps**: each task has 1-7 steps; each step is a single action with explicit commands.
- [x] **No "similar to Task N"**: every code block is fully written out.