# HTTPS on external Gateway via Cloudflare Origin CA

- **Date:** 2026-07-27
- **Status:** Approved — Phase 1 deploy + add HTTPS listener, Phase 2 switchover + remove HTTP listener.
- **Owner:** home-ops maintainers

## 1. Problem

The external Gateway `gateway.networking.k8s.io/v1/Gateway/external` in `network/` listens HTTP-only on `:80`. Cloudflare terminates TLS at the edge and forwards HTTP/2 plaintext to cloudflared → Envoy. We want origin-side TLS termination so:

- No plaintext hops between cloudflared and Envoy inside the cluster
- A future move (e.g. dropping Cloudflare, dual-stack, on-prem) doesn't require re-architecting trust
- Origin certs are scoped to Cloudflare's CA — useless to attackers if they ever reach the origin IP

We don't use Let's Encrypt for the external Gateway because:

- Public CA certs leak the cluster's hostnames to the public CA logs
- LE's rate limits don't matter, but the 90-day rotation churn adds operational noise we don't need for an internal origin

Cloudflare Origin CA is purpose-built for this: a cert signed by Cloudflare's private Origin CA root, which **cloudflared already trusts natively** (no CA bundle injection needed). Token scope (`Origin CA: Edit`) gives 1-15 day certs with auto-renewal.

## 2. Approach

Adopt [cloudflare/origin-ca-issuer](https://github.com/cloudflare/origin-ca-issuer) as a cert-manager plugin. The cert-manager controller auto-creates a `Certificate` from annotations on the Gateway — exactly the pattern the internal Gateway already uses for the Let's Encrypt wildcard. We add the same three annotations to the external Gateway and let cert-manager drive issuance.

Phased rollout to avoid breaking live traffic:

- **Phase 1** — additive: deploy `origin-ca-issuer` + `OriginIssuer` + `ExternalSecret`; add an `https` listener on `:443` to the existing external Gateway (keep `http` on `:80`); leave HTTPRoutes bound to `http`. Zero traffic impact; cert auto-issues in the background.
- **Phase 2** — switchover: change Cloudflare tunnel origins from `http://envoy-external:80` to `https://envoy-external:443`; flip 9 HTTPRoutes from `sectionName: http` → `https` on the external Gateway; remove the `http` listener on `:80`.

## 3. Target layout

```
kubernetes/
├── cert-manager/
│   ├── kustomization.yaml              (EDIT — add origin-ca-issuer/ks.yaml)
│   └── origin-ca-issuer/               (NEW)
│       ├── ks.yaml
│       ├── app/
│       │   ├── helmrelease.yaml
│       │   ├── ocirepository.yaml
│       │   └── kustomization.yaml
│       └── config/
│           ├── originissuer.yaml
│           ├── externalsecret.yaml
│           └── kustomization.yaml
└── network/
    └── envoy-gateway/
        └── config/
            ├── gateway.yaml            (EDIT — annotations + https listener, Phase 2: remove http)
            └── kustomization.yaml      (unchanged)
```

The 9 HTTPRoutes that bind to the external Gateway `http` listener live in their own component directories (jellyfin, dex-external, barcodebuddy, error-pages-external, grocy, konflate, yuvomi, flux-webhook, seerr). They are edited in Phase 2.

## 4. origin-ca-issuer stack

### OCIRepository

`kubernetes/cert-manager/origin-ca-issuer/app/ocirepository.yaml`:

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

OCI pin per user. Tag omitted — digest-only references are immutable.

### HelmRelease

`kubernetes/cert-manager/origin-ca-issuer/app/helmrelease.yaml`:

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

The chart ships its own `ClusterRole`/`ClusterRoleBinding` granting cert-manager permission to interact with `OriginIssuer` resources, plus the `OriginIssuer` CRD. No additional RBAC needed.

### ExternalSecret (separate from DNS-01 token)

`kubernetes/cert-manager/origin-ca-issuer/config/externalsecret.yaml`:

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

Same 1Password item (`cloudflare-api-token`), same field (`credential`) as the DNS-01 LE solver, **but rendered into a different Kubernetes Secret** (`cloudflare-origin-ca-token` vs `cloudflare-api-token`). Decoupling the Secrets lets us later swap to a scope-restricted Origin-CA-only token without touching the LE solver's Secret.

### OriginIssuer (cluster-scoped)

`kubernetes/cert-manager/origin-ca-issuer/config/originissuer.yaml`:

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

`requestDuration: 0` means "use the Certificate's duration as the cert lifetime" — the OriginIssuer schema has no `duration` field (confirmed by user). The 7-day duration lives on the Certificate, which cert-manager auto-generates from the Gateway annotation.

### Flux Kustomizations

`kubernetes/cert-manager/origin-ca-issuer/ks.yaml`:

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

The config Kustomization depends on `cert-manager-config` (so cert-manager is ready) and `external-secrets-config` (so the `ExternalSecret` controller is up). It does **not** need to depend on the `origin-ca-issuer` app Kustomization because the controller is referenced only by `OriginIssuer` resources, which cert-manager lazily resolves on first Certificate reconcile — the resulting 1-shot "issuer not registered" retry is harmless.

`kubernetes/cert-manager/kustomization.yaml` adds `origin-ca-issuer/ks.yaml`.

## 5. Gateway change (Phase 1 diff, Phase 2 cleanup)

### Phase 1: add HTTPS listener + annotations

`kubernetes/network/envoy-gateway/config/gateway.yaml` — edit the `external` Gateway only. Internal Gateway unchanged.

```yaml
---
apiVersion: gateway.networking.k8s.io/v1
kind: GatewayClass
metadata:
  name: eg
spec:
  controllerName: gateway.envoyproxy.io/gatewayclass-controller
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
---
# Internal Gateway - accessed via LAN LoadBalancer
# Uses wildcard cert for *.whoverse.dev via DNS-01 challenge
apiVersion: gateway.networking.k8s.io/v1
... (unchanged)
```

Resulting resources:

- `Certificate/whoverse-nexus-wildcard-tls` (auto-created by cert-manager in `network/` ns), `issuerRef.kind: OriginIssuer`, `duration: 168h`, `renewBefore: 24h`
- `Secret/whoverse-nexus-wildcard-tls` (kubernetes.io/tls in `network/` ns, populated by cert-manager)
- `Service/envoy-external` ClusterIP gains port 443 alongside port 80

### Phase 2: remove the `http` listener

After cloudflared is switched to HTTPS origins and HTTPRoutes flipped, edit `gateway.yaml` to drop the `http` listener block. Envoy Gateway removes port 80 from `Service/envoy-external`. Final Gateway has a single `https` listener on `:443`.

## 6. Phase 2: cloudflared tunnel origin switchover

cloudflared runs in `--token` mode and fetches its config from Cloudflare's API. The config maps each public hostname (`*.whoverse.nexus`) to an origin URL. Currently all origins are `http://envoy-external.network.svc:80`.

Phase 2a (out-of-band Cloudflare dashboard / API):

For every `*.whoverse.nexus` public hostname in the tunnel:

- Change origin service URL from `http://envoy-external:80` → `https://envoy-external:443`

cloudflared reloads config without a pod restart. New connections use HTTPS; in-flight HTTP/2 streams fail over gracefully because cloudflared reconnects per request after the config change.

No changes to the cloudflared HelmRelease, image, args, or external-dns annotations.

## 7. Phase 2: HTTPRoute `sectionName` flip

Nine HTTPRoutes currently bind to `external/http`. Flip `sectionName: http` → `sectionName: https` in a single commit:

| File |
|---|
| `kubernetes/entertainment/jellyfin/app/httproute.yaml` |
| `kubernetes/auth/dex-external/app/httproute.yaml` |
| `kubernetes/default/barcodebuddy/app/httproute.yaml` |
| `kubernetes/default/error-pages/app-external/httproute.yaml` |
| `kubernetes/default/grocy/app/httproute.yaml` |
| `kubernetes/default/konflate/app/httproute.yaml` |
| `kubernetes/default/yuvomi/app/httproute.yaml` |
| `kubernetes/flux-system/webhook/app/webhook-httproute.yaml` |
| `kubernetes/downloads/seerr/app/httproute.yaml` (only the external parentRef; keep internal http+https) |

Atomic commit prevents Envoy from ever seeing a window where no external parentRef is bound.

## 8. Reconcile graph updates

Add `origin-ca-issuer-config` to the dependsOn of `envoy-gateway-config` so the `OriginIssuer` CRD is registered before cert-manager tries to use it (avoids a one-shot "issuer not registered" log line on first reconcile):

```yaml
# kubernetes/network/envoy-gateway/ks.yaml (EDIT)
spec:
  dependsOn:
    - name: envoy-gateway
    - name: cert-manager-config
      namespace: cert-manager
    - name: origin-ca-issuer-config      # NEW
      namespace: cert-manager
```

## 9. What does not change

- 1Password item `cloudflare-api-token` (same item, same field, same vault)
- cloudflared HelmRelease / image / args / Service
- external-dns annotation on the Gateway
- `EnvoyProxy/external-proxy-config` (ClusterIP service; ports derived from Gateway listeners)
- Internal Gateway (LE wildcard cert, unchanged)
- Existing `Secret/cloudflare-api-token` in `cert-manager/` ns (still used by LE DNS-01)
- HTTPRoute `hostnames` and `backendRefs`

## 10. Verification

### Phase 1

```
kubectl get pods -n cert-manager -l app.kubernetes.io/name=origin-ca-issuer
# 1/1 Running

kubectl get originissuer -A
# NAME               AGE
# cloudflare-origin  ...

kubectl get certificate -n network
# NAME                          READY   SECRET                        AGE
# whoverse-nexus-wildcard-tls   True    whoverse-nexus-wildcard-tls   ...

kubectl get secret -n network whoverse-nexus-wildcard-tls \
  -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -noout -subject -issuer -dates
# subject: CN (SAN) = *.whoverse.nexus
# issuer: O = Cloudflare, Inc., OU = Origin CA
# notAfter: ~7 days from now

kubectl get svc -n network envoy-external -o jsonpath='{.spec.ports[*].port}'
# 80 443
```

### Phase 2

```
# After cloudflared config switch
curl -vI https://jellyfin.whoverse.nexus 2>&1 | grep -E 'HTTP|SSL|issuer'
# HTTP/2 200
# issuer: Cloudflare Origin CA (via Envoy)

# After HTTP listener removal
kubectl get svc -n network envoy-external -o jsonpath='{.spec.ports[*].port}'
# 443
```

## 11. Rollback

Phase 1 rollback = remove the `https` listener block and the three annotations from `gateway.yaml`. The HTTP listener keeps serving traffic. Delete the `origin-ca-issuer` component to remove the controller (OriginIssuer resources are pruned by `kubectl` or by removing the component Kustomization entry).

Phase 2a rollback = revert Cloudflare tunnel origins to `http://envoy-external:80`.

Phase 2b/c rollback = revert HTTPRoute `sectionName` to `http`, re-add the `http` listener. Two atomic commits.

The 7-day cert lifetime means even a missed rotation window has bounded blast radius — the cert will simply expire, surfacing the misconfiguration as a clear TLS error rather than silently serving a stale trust path.

## 12. Open questions

- 1Password field name confirmation: `property: credential` on `cloudflare-api-token` — confirmed by the existing DNS-01 ExternalSecret using the same property as a raw string token. Same property used here.