# Konflate Deployment Design

> **Status:** Approved — 2026-07-25
> **Scope:** Add Konflate 0.4.3 to `home-ops` cluster as a public-internet-facing
> GitOps PR rendered-diff UI for `AlinaNova21/home-ops`.

## Goals

- Surface Flux-rendered PR diffs (blast radius, image bumps, cautions,
  render failures) for every open PR on `AlinaNova21/home-ops`.
- Post a Konflate commit status check + PR summary comment per render
  (full read + write path).
- Reachable on the external Gateway at `konflate.whoverse.nexus` (Cloudflare
  Tunnel, public).

## Non-Goals

- OIDC at the edge. Konflate's HTTP surface is read-only by design; the GitHub
  App credentials are held server-side and never read from incoming requests.
  No `SecurityPolicy` is added.
- Private repository reads. The repo is public; `config.repo` is the only
  authentication boundary.
- Custom PR filter. `KONFLATE_PR_FILTER_EXPR` left at the default `true`.
- MCP endpoint. Off by default (`KONFLATE_MCP=false`).
- Per-render image verification. Off by default (`KONFLATE_VERIFY_IMAGES=false`).

## Architecture

Single Konflate instance installed via the upstream `home-operations` OCI
Helm chart (`oci://ghcr.io/home-operations/charts/konflate`, version `0.4.3`).
Flux reconciles the component through a `Kustomization/konflate` rooted at
`./default/konflate/app`. The release name is `konflate`; the resulting
Service is `konflate` on port `8080` (chart default).

Forge identity is a GitHub App whose client id + PEM private key are stored
in 1Password Connect under item `konflate-github-app`, fields `appClientId`
and `appSecretKey`, synced into the cluster by External Secrets Operator
into `Secret/default/konflate-github-app` (data keys `appClientId` and
`appSecretKey`). The HelmRelease injects both via two `valuesFrom` entries:
`appClientId` → `secret.appClientId`, and `appSecretKey` → `secret.appPrivateKey`
(the chart's expected key name; the ExternalSecret data key keeps the operator's
`appSecretKey` label). The App installation on `AlinaNova21/home-ops` is
auto-discovered from `config.repo`; no installation id is configured.

## File map

| Path | Purpose |
|---|---|
| `kubernetes/default/konflate/ks.yaml` | Flux `Kustomization/konflate` (`namespace: default`) |
| `kubernetes/default/konflate/app/helmrelease.yaml` | `HelmRelease/konflate` (chart `konflate` 0.4.3) |
| `kubernetes/default/konflate/app/externalsecret.yaml` | 1Password → `Secret/konflate-github-app` |
| `kubernetes/default/konflate/app/httproute.yaml` | `HTTPRoute/konflate` on external Gateway |
| `kubernetes/default/konflate/app/kustomization.yaml` | Aggregator for the four files above |
| `kubernetes/default/kustomization.yaml` | Append `konflate/ks.yaml` |

No changes to `kubernetes/flux-config/registry/helm/*` (existing
`home-operations` HelmRepository already serves the chart).

## Component shape

```yaml
# kubernetes/default/konflate/ks.yaml
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

```yaml
# kubernetes/default/konflate/app/helmrelease.yaml
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
      valuesKey: appSecretKey
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

```yaml
# kubernetes/default/konflate/app/externalsecret.yaml
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
    - secretKey: appSecretKey
      remoteRef:
        key: konflate-github-app
        property: appSecretKey
```

```yaml
# kubernetes/default/konflate/app/httproute.yaml
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

## Identity / Forge authentication

GitHub App credentials live in 1Password Connect under item `konflate-github-app`
with two text fields:

- `appClientId` — the GitHub App's **client id** (the JWT issuer; `Iv23li…`
  shape). No numeric app id needed.
- `appSecretKey` — the PEM private key, with original line breaks preserved.

The App must be installed on `AlinaNova21/home-ops` with these repository
permissions:

| Permission | Access | Required for |
|---|---|---|
| Checks | Read and write | Konflate check run on PR head (falls back to commit status if absent) |
| Pull requests | Read and write | PR summary comment, edited in place |
| Metadata | Read-only | Repository lookup (auto-install detection) |

No organization-level permissions are required. No webhook is needed
(Konflate polls on `KONFLATE_REFRESH_INTERVAL`).

## Networking

- `Service/konflate` is `ClusterIP`, port `http` on `8080` (chart default).
- `HTTPRoute/konflate` attaches to the `external` Gateway's `http` listener
  (Cloudflare Tunnel, TLS terminated at Cloudflare). No TLS on Envoy.
- No `NetworkPolicy` is added; Cilium default policies do not block Konflate's
  egress (forge + git on `:443`), and Konflate does not need cluster API
  access (chart defaults `serviceAccount.automount: false`).

## Resource lifecycle

- `prune: false` on the component `Kustomization` (matches the repo's
  defensive pattern; `default/database` and `default/mailpit` both use it).
- Helm chart default `strategy.type: Recreate` — single replica with
  `ReadWriteOnce` PVC and in-memory state; a `RollingUpdate` would wedge
  on Multi-Attach.
- `PodDisruptionBudget.maxUnavailable: 1` keeps node drains unblocked
  (single-replica chart cannot honor `minAvailable: 1`).

## Security posture

- Pod runs as non-root uid/gid `65532`, `runAsNonRoot: true`,
  `seccompProfile: RuntimeDefault`, `readOnlyRootFilesystem: true`,
  `allowPrivilegeEscalation: false`, `capabilities.drop: [ALL]`
  (chart defaults; verified in `values.yaml`).
- ServiceAccount token not automounted (Konflate doesn't talk to the cluster
  API).
- No OIDC at the edge. Konflate's HTTP surface is read-only; the GitHub App
  credentials live in the process and are not exposed via any inbound
  endpoint. Status checks + comments are posted only by Konflate's own
  render loop, never from a request.

## Validation

```bash
# Local (matches CI)
for dir in kubernetes/flux-config kubernetes; do
  echo "=== $dir ==="
  kustomize build "$dir" | kubeconform -strict -ignore-missing-schemas \
    -schema-location default \
    -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'
done

# After commit + push + OCI artifact builds + Flux reconciles
flux reconcile kustomization cluster -n flux-system
flux get hr -n default konflate
kubectl get externalsecret -n default konflate-github-app
kubectl get secret -n default konflate-github-app -o jsonpath='{.data.appClientId}' | base64 -d
kubectl get pods -n default -l app.kubernetes.io/name=konflate

# Public smoke test
curl -fsS https://konflate.whoverse.nexus/api/meta | jq '.features'
kubectl logs -n default -l app.kubernetes.io/name=konflate | grep -i 'github app'
```

Expected: `HelmRelease Ready: True`, pod `Running`, `/api/meta` returns the
enabled write-back feature flags, the App installation is auto-detected from
the configured repo, the first PR re-render posts a `Konflate` commit status
and an in-place-updated summary comment on `AlinaNova21/home-ops`.

## Risks (operational, not data-leak)

- Anonymous external traffic fans out to GitHub App reads at the raised limit
  (5,000 req/h vs 60 anonymous). Mitigated by per-PR coalescing +
  `KONFLATE_REFRESH_INTERVAL=30m` + `KONFLATE_MAX_DIFF_CONC` auto-bound by
  CPU limit.
- If the Konflate process is compromised, the attacker can post status checks
  + comments on `AlinaNova21/home-ops` (App's narrow scope). The same is
  true on internal vs external exposure.
- Persistent PVC is disposable; no protected data, no backup.

## Out of scope

- OIDC SecurityPolicy at the edge.
- Prometheus ServiceMonitor (monitoring stack can opt in later if useful).
- Backup of the persistent cache volume.
- MCP server (`KONFLATE_MCP=false`).
- Custom `prFilterExpr` or fork rendering.
