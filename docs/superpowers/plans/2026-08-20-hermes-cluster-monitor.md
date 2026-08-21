# Hermes Cluster Monitor Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

> **Read these skills first (canonical shapes for this repo):**
> - `.agents/skills/home-ops-add-new-app/SKILL.md` — 6-step recipe for a new app (ks.yaml, app/, kustomization)
> - `.agents/skills/home-ops-app-pattern/SKILL.md` — bjw-s app-template HelmRelease shape
> - `.agents/skills/home-ops-create-httproute/SKILL.md` — HTTPRoute authoring (internal/external)
> - `.agents/skills/home-ops-external-secrets/SKILL.md` — 1Password `ExternalSecret` convention
> - `.agents/skills/home-ops-flate/SKILL.md` — `just flate-test` validation gate
> - Also follow `.agents/skills/home-ops-worktree-workflow/SKILL.md` (work in `.worktrees/<branch>`, run `just flate-test` baseline before starting).

**Goal:** Deploy an in-cluster Hermes Agent that monitors the cluster (watchdog-led), with cluster authority mediated solely through a scoped flux-operator-mcp ServiceAccount, on a derived image, isolated by gVisor, reachable via an internal dashboard, and backed by a shared memini memory on moltbot.

**Architecture:** A `hermes` namespace hosts the Hermes agent Deployment (derived `ghcr.io/alinanova21/hermes-agent` image) and a separate flux-operator-mcp Deployment (its own scoped SA/RBAC, `--mask-secrets`). The agent has no cluster RBAC; all cluster reads/ops go through the flux-operator-mcp + konflate MCP servers. A Tailscale egress Service in `network/` reaches moltbot (SearXNG :8080 + memini :8081). Dashboard exposed internally via `hermes.whoverse.dev` with Kanidm OIDC auth.

**Tech Stack:** Hermes Agent (Docker image derived via uv), Flux CD (bjm-s app-template HelmRelease via OCIRepository), External Secrets Operator (1Password Connect), Gateway API HTTPRoute (internal Envoy gateway), Tailscale operator (egress ProxyGroup), gVisor RuntimeClass, Renovate.

**File structure (new/modified):**
```
images/hermes-agent/                         (NEW top-level dir)
├── Dockerfile
├── plugins/web/local-extract/{__init__.py, provider.py, plugin.yaml}
└── VERSION
.github/workflows/images.yml                (NEW — generic arrayed image builder; mirror helm-oci conventions)
.renovate/  (or renovate.json — see Task 3)
kubernetes/hermes/ns.yaml                    (NEW)
kubernetes/hermes/kustomization.yaml         (NEW)
kubernetes/hermes/app/kustomization.yaml     (NEW)
kubernetes/hermes/app/ks.yaml                (NEW)
kubernetes/hermes/app/helmrelease.yaml       (NEW)
kubernetes/hermes/app/ocirepository.yaml     (NEW)
kubernetes/hermes/app/externalsecret.yaml    (NEW)
kubernetes/hermes/app/serviceaccount.yaml    (NEW)
kubernetes/hermes/app/clusterrole*.yaml      (NEW — flux-operator-mcp RBAC)
kubernetes/hermes/app/config.yaml            (NEW — Hermes config.yaml seeded to PVC)
kubernetes/hermes/app/pvc.yaml               (NEW)
kubernetes/hermes/app/httproutes.yaml        (NEW)
kubernetes/network/moltbot-egress/           (NEW — egress components)
└── (egress-service.yaml, kustomization.yaml, ks.yaml)
kubernetes/kustomization.yaml                (MODIFY — add hermes + network/moltbot-egress)
kubernetes/holmes/                           (DELETE)
kubernetes/chaski/app/config.d/10-holmes.yaml (DELETE)
```

**Baseline (do once, first):**
```bash
cd .worktrees/<branch> && mise install
just flate-test          # must pass (pre-existing baseline)
```

---

### Task 1: Derived image — Dockerfile, bundled plugin, VERSION

**Files:**
- Create: `images/hermes-agent/Dockerfile`
- Create: `images/hermes-agent/VERSION`
- Create: `images/hermes-agent/plugins/web/local-extract/__init__.py`
- Create: `images/hermes-agent/plugins/web/local-extract/provider.py`
- Create: `images/hermes-agent/plugins/web/local-extract/plugin.yaml`

- [ ] **Step 1: Source the bundled plugin files**

Copy the local-extract plugin (exactly as it runs on moltbot) into the repo:
```bash
PLUGIN_SRC=/home/alina/.hermes/plugins/web/local-extract
DST=images/hermes-agent/plugins/web/local-extract
mkdir -p "$DST"
cp "$PLUGIN_SRC/__init__.py" "$PLUGIN_SRC/provider.py" "$PLUGIN_SRC/plugin.yaml" "$DST/"
```
Verify they are byte-identical: `diff -r "$PLUGIN_SRC" "$DST"` (only `__init__.py`, `provider.py`, `plugin.yaml` — no `__pycache__`).

- [ ] **Step 2: Add `VERSION`**

`images/hermes-agent/VERSION`:
```
0.20.4
```
(Use the current latest published `nousresearch/hermes-agent` tag at implementation time; Renovate owns this file afterward.)

- [ ] **Step 3: Write the Dockerfile**

`images/hermes-agent/Dockerfile`:
```dockerfile
# syntax=docker/dockerfile:1
# Derived Hermes Agent image: adds trafilatura to the uv-managed venv
# (absent from the published image, which has no pip) and bundles the
# web/local-extract plugin into the immutable install tree.
ARG HERMES_VERSION
FROM nousresearch/hermes-agent:${HERMES_VERSION}

USER root
COPY plugins/ /opt/hermes/plugins/
RUN /usr/local/bin/uv pip install --python /opt/hermes/.venv/bin/python --no-cache --disable-pip-version-check trafilatura
USER hermes

# Verify the bake: fail loudly at build time if trafilatura isn't importable.
RUN /opt/hermes/.venv/bin/python -c "import trafilatura; print('trafilatura', trafilatura.__version__)"
```
NOTE: later we pin the base by digest (Task 3/Renovate). For the first build use `:${HERMES_VERSION}`.

- [ ] **Step 4: Validate locally (build + import check) before CI**

```bash
docker build \
  --build-arg HERMES_VERSION=$(cat images/hermes-agent/VERSION) \
  -t ghcr.io/alinanova21/hermes-agent:dev images/hermes-agent
docker run --rm --entrypoint sh ghcr.io/alinanova21/hermes-agent:dev -c \
  '/opt/hermes/.venv/bin/python -c "import trafilatura,httpx; print(trafilatura.__version__, httpx.__version__)"'
```
Expected: builds, then prints e.g. `2.2.0 0.28.1`. Also confirm the bundled plugin registers:
```bash
docker run --rm --entrypoint sh ghcr.io/alinanova21/hermes-agent:dev -c \
  'HERMES_HOME=/tmp/h /opt/hermes/.venv/bin/hermes plugins list' | grep -i local-extract
```
Expected: `web/local-extract` appears (bundled).

- [ ] **Step 5: Commit**

```bash
git add images/hermes-agent
git commit -m "feat(images): hermes-agent derived image with trafilatura + bundled local-extract"
```

---

### Task 2: Generic arrayed image build workflow

Design a **single generic workflow** that builds any image under `images/<name>/` —
new images are drop-in (add a directory with a Dockerfile; optionally a `VERSION`
file). It is triggered on `images/**` and computes the matrix of changed image
dirs, building only those (or all on manual dispatch).

Image naming convention:
- context = `images/<name>`
- image = `ghcr.io/alinanova21/<name>`
- version = contents of `images/<name>/VERSION` if present, else `latest`
- tag = `${{ version }}-${{ github.run_number }}` (numeric monotonic prerelease,
  valid semver, sortable by Renovate) + `latest` convenience tag

**Files:**
- Create: `.github/workflows/images.yml` (generic orchestrator — the only file)

- [ ] **Step 1: Write the generic workflow**

`.github/workflows/images.yml`:
```yaml
name: Build Images

on:
  push:
    paths:
      - "images/**"
      - ".github/workflows/images.yml"
  workflow_dispatch:

env:
  REGISTRY: ghcr.io
  REGISTRY_OWNER: alinanova21

permissions:
  contents: read
  packages: write

jobs:
  changed-images:
    runs-on: ubuntu-latest
    outputs:
      matrix: ${{ steps.matrix.outputs.matrix }}
    steps:
      - uses: actions/checkout@v7
        with:
          fetch-depth: 0
      - name: Compute changed image matrix
        id: matrix
        run: |
          if [ "${{ github.event_name }}" = "workflow_dispatch" ]; then
            dirs=$(ls -d images/*/ 2>/dev/null | sed 's|images/||; s|/||')
          else
            dirs=$(git diff --name-only "${{ github.event.before }}" "${{ github.sha }}" -- images/ \
              | cut -d/ -f2 | sort -u)
          fi
          json='[]'
          for d in $dirs; do
            [ -f "images/$d/Dockerfile" ] || continue
            ver=$(cat "images/$d/VERSION" 2>/dev/null || echo latest)
            json=$(echo "$json" | jq --arg n "$d" --arg v "$ver" \
              '. + [{name:$n, version:$v}]')
          done
          echo "matrix=$json" >> "$GITHUB_OUTPUT"

  build:
    needs: changed-images
    if: ${{ fromJSON(needs.changed-images.outputs.matrix) != '[]' }}
    runs-on: ubuntu-latest
    strategy:
      matrix:
        include: ${{ fromJSON(needs.changed-images.outputs.matrix) }}
    steps:
      - uses: actions/checkout@v7
      - name: Build args
        id: args
        run: |
          # Optional images/<name>/build-args.env (KEY=VALUE per line) → comma-joined.
          # Plus auto-inject HERMES_VERSION from VERSION (single source for images
          # whose Dockerfile is FROM <upstream>:${HERMES_VERSION}, incl. hermes-agent).
          list=""
          f="images/${{ matrix.name }}/build-args.env"
          [ -f "$f" ] && list="$(paste -sd, "$f")"
          if [ -f "images/${{ matrix.name }}/VERSION" ]; then
            [ -n "$list" ] && list="$list,"
            list="${list}HERMES_VERSION=${{ matrix.version }}"
          fi
          [ -n "$list" ] && echo "list=$list" >> "$GITHUB_OUTPUT"
      - name: Docker metadata
        id: meta
        uses: docker/metadata-action@v5
        with:
          images: ${{ env.REGISTRY }}/${{ env.REGISTRY_OWNER }}/${{ matrix.name }}
          tags: |
            type=raw,value=${{ matrix.version }}-${{ github.run_number }}
            type=raw,value=latest
      - name: Log in to Container Registry
        uses: docker/login-action@v4
        with:
          registry: ${{ env.REGISTRY }}
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}
      - name: Build and push
        uses: docker/build-push-action@v5
        with:
          context: images/${{ matrix.name }}
          push: true
          tags: ${{ steps.meta.outputs.tags }}
          build-args: ${{ steps.args.outputs.list }}
```
This is generic and arrayed: every image dir with a Dockerfile builds itself; the
matrix only includes dirs whose files changed. `images/hermes-agent/` is the
first consumer.

Per-image conventions:
- `images/<name>/Dockerfile` — required.
- `images/<name>/VERSION` — optional; single source for both the
  `${version}-${run.number}` tag AND the auto-injected `HERMES_VERSION` build arg
  (default `latest` if absent).
- `images/<name>/build-args.env` — optional `KEY=VALUE` lines passed as
  additional `--build-arg`s.

- [ ] **Step 2: Commit**

```bash
git add .github/workflows/images.yml
git commit -m "ci: generic arrayed image build workflow (images/<name>)"
```

---

### Task 3: Renovate — base version + derived image tag + digest pin

**Files:**
- Modify: `.github/renovate.json5` (or `renovate.json`) — check repo's actual Renovate config location first: `ls .github/renovate* renovate* .renovate* 2>/dev/null`
- Modify: `images/hermes-agent/Dockerfile` (pin base digest)

- [ ] **Step 1: Pin the base image by digest**

Read the current digest and update the Dockerfile base to a digest-pin:
```bash
DIGEST=$(docker inspect --format='{{index .RepoDigests 0}}' nousresearch/hermes-agent:$(cat images/hermes-agent/VERSION) | cut -d@ -f2)
# set FROM nousresearch/hermes-agent:${HERMES_VERSION}@sha256:<digest>
```
Keep `ARG HERMES_VERSION` + `@sha256:` pin. Renovate will bump both the tag and digest.

- [ ] **Step 2: Add Renovate rules**

Add/extend the repo's Renovate config with two managers:
1. **Base version + digest** in `images/hermes-agent/Dockerfile` + `VERSION` — a `dockerfile`/`regex` manager so the `0.20.4` and its digest update on upstream releases. Follow the repo's existing Renovate presets (`.renovate-presets` / `renovate-presets-migration` design doc).
2. **Derived image tag** in the cluster HelmRelease — a package rule for `ghcr.io/alinanova21/hermes-agent` (image-tag manager) so the cluster ref bumps to the newest `${VERSION}-${run.number}`.

Provide concrete config once you confirm the repo's Renovate file/format (json5 vs json) in the first step; wire both managers and note them in the commit.

- [ ] **Step 3: Commit**

```bash
git commit -m "chore(renovate): manage hermes base version/digest + derived tag"
```

---

### Task 4: flux-operator-mcp RBAC (scoped ServiceAccount)

**Files:**
- Create: `kubernetes/hermes/app/serviceaccount.yaml`
- Create: `kubernetes/hermes/app/clusterrole.yaml`
- Create: `kubernetes/hermes/app/clusterrolebinding.yaml`

- [ ] **Step 1: Write the ServiceAccount**

`kubernetes/hermes/app/serviceaccount.yaml`:
```yaml
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: flux-mcp
  namespace: hermes
automountServiceAccountToken: true
```

- [ ] **Step 2: Write the ClusterRole (hard T2 limits)**

`kubernetes/hermes/app/clusterrole.yaml` — read-only cluster-wide (NO secrets), delete pods only, patch known Flux CRs only (for reconcile):
```yaml
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: hermes-flux-mcp
rules:
  # Read (cluster-wide) — explicitly EXCLUDE secrets.
  - apiGroups: [""]
    resources: [pods, pods/log, pods/status, services, endpoints, configmaps, nodes, nodes/status, namespaces, events, persistentvolumes, persistentvolumeclaims, resourcequotas, limitranges]
    verbs: [get, list, watch]
  - apiGroups: ["apps"]
    resources: [deployments, deployments/status, statefulsets, statefulsets/status, daemonsets, daemonsets/status, replicasets, replicasets/status]
    verbs: [get, list, watch]
  - apiGroups: ["batch"]
    resources: [jobs, cronjobs]
    verbs: [get, list, watch]
  - apiGroups: ["networking.k8s.io"]
    resources: [networkpolicies, ingresses]
    verbs: [get, list, watch]
  - apiGroups: ["storage.k8s.io"]
    resources: [storageclasses]
    verbs: [get, list, watch]
  - apiGroups: ["api.fluxcd.io"]
    resources: [flxinstances]
    verbs: [get, list, watch]
  - apiGroups: ["kustomize.toolkit.fluxcd.io"]
    resources: [kustomizations]
    verbs: [get, list, watch, update, patch]   # update/patch ONLY for flux reconcile annotation
  - apiGroups: ["helm.toolkit.fluxcd.io"]
    resources: [helmreleases]
    verbs: [get, list, watch, update, patch]
  - apiGroups: ["source.toolkit.fluxcd.io"]
    resources: [gitrepositories, ocirepositories, helmrepositories, helmcharts, buckets]
    verbs: [get, list, watch, update, patch]
  - apiGroups: ["notification.toolkit.fluxcd.io"]
    resources: [providers, alerts, receivers]
    verbs: [get, list, watch]
  # Write: DELETE on pods only. No create/update on pods.
  - apiGroups: [""]
    resources: [pods]
    verbs: [delete]
```
`flxinstances` — confirm the exact FluxInstance group from `kubectl api-resources | grep -i fluxinstance` (operator uses `api.fluxcd.io`).

- [ ] **Step 3: Write the ClusterRoleBinding**

`kubernetes/hermes/app/clusterrolebinding.yaml`:
```yaml
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: hermes-flux-mcp
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: hermes-flux-mcp
subjects:
  - kind: ServiceAccount
    name: flux-mcp
    namespace: hermes
```

- [ ] **Step 4: Validate + commit**

```bash
pre-commit run --files kubernetes/hermes/app/*.yaml
git commit -m "feat(hermes): scoped flux-operator-mcp RBAC (read, delete-pods, flux-CR patch)"
```

---

### Task 5: flux-operator-mcp Deployment + Service

**Files:**
- Create: `kubernetes/hermes/app/flux-mcp.yaml` (Deployment + Service)

- [ ] **Step 1: Write Deployment + Service**

`kubernetes/hermes/app/flux-mcp.yaml`:
```yaml
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: flux-operator-mcp
  namespace: hermes
spec:
  replicas: 1
  selector:
    matchLabels:
      app: flux-operator-mcp
  template:
    metadata:
      labels:
        app: flux-operator-mcp
    spec:
      serviceAccountName: flux-mcp
      runtimeClassName: gvisor
      securityContext:
        runAsNonRoot: true
        runAsUser: 65534          # consistent non-root; flux-operator-mcp does not need the s6/root path
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: flux-operator-mcp
          image: flux-operator-mcp:latest        # FROM mise pin via `mise x -- flux-operator-mcp`; or a published image
          args: ["serve", "--mask-secrets=true", "--kubeconfig", "/var/run/secrets/kubernetes.io/serviceaccount/kubeconfig"]
          ports:
            - name: http
              containerPort: 8080
          livenessProbe:
            httpGet: { path: /health, port: http }
          securityContext:
            allowPrivilegeEscalation: false
            capabilities: { drop: [ALL] }
          resources:
            requests: { cpu: 100m, memory: 128Mi }
            limits:   { memory: 256Mi }
---
apiVersion: v1
kind: Service
metadata:
  name: flux-operator-mcp
  namespace: hermes
spec:
  selector:
    app: flux-operator-mcp
  ports:
    - name: http
      port: 8080
      targetPort: http
```
NOTE: resolve the flux-operator-mcp container image/serve signature at implementation time (`mise x -- flux-operator-mcp serve --help`; it defaults to stdio transport and uses `--port` for SSE). The agent connects over SSE to `http://flux-operator-mcp.hermes.svc.cluster.local:8080/mcp` (or the transport the `serve` command exposes). Adjust args/path/port accordingly — complete in step.

- [ ] **Step 2: Validate + commit**

```bash
pre-commit run --files kubernetes/hermes/app/flux-mcp.yaml
just flate-test
git commit -m "feat(hermes): flux-operator-mcp deployment + service"
```

---

### Task 6: hermes namespace scaffolding (ns, ks, kustomization)

**Files:**
- Create: `kubernetes/hermes/ns.yaml`
- Create: `kubernetes/hermes/kustomization.yaml`
- Create: `kubernetes/hermes/app/kustomization.yaml`
- Create: `kubernetes/hermes/app/ks.yaml`
- Modify: `kubernetes/kustomization.yaml`

Follow `.agents/skills/home-ops-add-new-app/SKILL.md` exactly.

- [ ] **Step 1: Namespace + aggregator**

`kubernetes/hermes/ns.yaml`:
```yaml
---
apiVersion: v1
kind: Namespace
metadata:
  name: hermes
```

`kubernetes/hermes/kustomization.yaml`:
```yaml
---
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ns.yaml
  - app/ks.yaml
```

`kubernetes/hermes/app/ks.yaml` (metadata.namespace must = hermes, path `./kubernetes/hermes/app`):
```yaml
---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: hermes
  namespace: hermes
spec:
  interval: 15m
  path: "./kubernetes/hermes/app"
  sourceRef:
    kind: GitRepository
    name: home-ops
    namespace: flux-system
  timeout: 10m
  wait: true
  prune: true
```

`kubernetes/hermes/app/kustomization.yaml` (list every app manifest added in Tasks 5,7,8,10):
```yaml
---
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ks.yaml            # NOT needed here (only at namespace level) — see add-new-app skill
  - flux-mcp.yaml
  - serviceaccount.yaml
  - clusterrole.yaml
  - clusterrolebinding.yaml
  - helmrelease.yaml
  - ocirepository.yaml
  - externalsecret.yaml
  - config.yaml
  - pvc.yaml
  - httproutes.yaml
```

- [ ] **Step 2: Add to top-level aggregator**

Add `hermes` (and `network/moltbot-egress` from Task 7) to `kubernetes/kustomization.yaml` resources, and add `network/moltbot-egress/ks.yaml`'s `ks.yaml` to `kubernetes/network/kustomization.yaml`.

- [ ] **Step 3: Validate + commit**

```bash
pre-commit run --files kubernetes/hermes/**/*.yaml kubernetes/kustomization.yaml
just flate-test
git commit -m "feat(hermes): namespace scaffolding"
```

---

### Task 7: network/moltbot-egress Tailscale egress

**Files:**
- Create: `kubernetes/network/moltbot-egress/ks.yaml`
- Create: `kubernetes/network/moltbot-egress/app/egress-service.yaml`
- Create: `kubernetes/network/moltbot-egress/app/kustomization.yaml`

Modeled on `kubernetes/network/pve-egress/app/egress-services.yaml` (see the `tailscale` ProxyGroup already at `kubernetes/network/tailscale/config/proxygroup.yaml` — add or reuse the `pve-egress`-style egress ProxyGroup).

- [ ] **Step 1: Egress Service (two ports → moltbot)**

`kubernetes/network/moltbot-egress/app/egress-service.yaml`:
```yaml
---
apiVersion: v1
kind: Service
metadata:
  name: moltbot-egress
  namespace: network
  annotations:
    tailscale.com/tailnet-fqdn: "moltbot.tailnet-f088.ts.net."
    tailscale.com/proxy-group: pve-egress   # or a dedicated moltbot-egress ProxyGroup
spec:
  type: ExternalName
  externalName: placeholder
  ports:
    - name: searxng
      port: 8080
      protocol: TCP
    - name: memini
      port: 8081
      protocol: TCP
```
Confirm the tailnet FQDN (`moltbot.tailnet-f088.ts.net.` — verify via `tailscale status`/`moltbot` DNS) and the correct ProxyGroup to attach (add a `type: egress` ProxyGroup for moltbot if you don't want to reuse pve-egress).

- [ ] **Step 2: kustomization + ks**

`kubernetes/network/moltbot-egress/app/kustomization.yaml`:
```yaml
---
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - egress-service.yaml
```
`kubernetes/network/moltbot-egress/ks.yaml`: Flux Kustomization, metadata.namespace=network, path `./kubernetes/network/moltbot-egress/app`.

- [ ] **Step 3: Register + validate + commit**

Add `moltbot-egress/ks.yaml` to `kubernetes/network/kustomization.yaml`. Then:
```bash
just flate-test
git commit -m "feat(network): moltbot tailscale egress (searxng :8080, memini :8081)"
```
Runtime verify (after reconcile):
```bash
kubectl -n hermes exec deploy/hermes -- curl -s http://moltbot-egress.network.svc.cluster.local:8081/ | head
kubectl -n hermes exec deploy/hermes -- curl -s http://moltbot-egress.network.svc.cluster.local:8080/ | head
```
Expected: memini returns 200; SearXNG returns its page.

---

### Task 8: hermes HelmRelease, OCIRepository, PVC, ServiceAccount

**Files:**
- Create: `kubernetes/hermes/app/ocirepository.yaml` (bjw-s app-template chart) — see `home-ops-app-pattern`/`add-new-app`
- Create: `kubernetes/hermes/app/helmrelease.yaml`
- Create: `kubernetes/hermes/app/pvc.yaml`
- Create: `kubernetes/hermes/app/serviceaccount.yaml` (hermes — NO RBAC)

- [ ] **Step 1: OCIRepository (app-template chart)**

Standard bjw-s app-template `oci://ghcr.io/bjw-s-labs/helm/app-template` OCIRepository. Follow `home-ops-app-pattern` exactly (cosign verification, chartRef in HelmRelease).

- [ ] **Step 2: PVC**

`kubernetes/hermes/app/pvc.yaml`: storageClass `miroir-replicated` (default per AGENTS.md), capacity e.g. 10Gi, ReadWriteOnce + ReadWriteMany if the operator reuse warrants — start RWO. Mount `/opt/data` as `HERMES_HOME`; do NOT mount a node-local ephemeral home.

- [ ] **Step 3: hermes ServiceAccount (no RBAC)**

`kubernetes/hermes/app/serviceaccount.yaml`:
```yaml
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: hermes
  namespace: hermes
automountServiceAccountToken: false   # agent has no cluster authority by design
```

- [ ] **Step 4: HelmRelease (values)**

Use the app-template. Critical values:
- image: `ghcr.io/alinanova21/hermes-agent` (imagePullPolicy Always), command `gateway run`
- `runtimeClassName: gvisor` (top-level pod template via the chart's `podSecurityContext`/`securityContext` where supported — set via `securityContext` + any `initContainers` for seeding)
- PVC mount `/opt/data`; env from `.op.env`/ExternalSecret
- resources: requests 500m/1Gi, limits 2Gi
- env and volumes per the config details in the Env/Config tasks below (this task wires the container shape; Task 9 supplies the full env/config content).

- [ ] **Step 5: Validate + commit**

```bash
pre-commit run --files kubernetes/hermes/app/helmrelease.yaml kubernetes/hermes/app/ocirepository.yaml kubernetes/hermes/app/pvc.yaml kubernetes/hermes/app/serviceaccount.yaml
just flate-test
git commit -m "feat(hermes): hermes deployment, pvc, no-rbac serviceaccount"
```

---

### Task 9: Hermes config.yaml + env (security + memory + web + model + MCP)

**Files:**
- Create: `kubernetes/hermes/app/config.yaml` (ConfigMap → seeded to `/opt/data/config.yaml`)
- Modify: `kubernetes/hermes/app/helmrelease.yaml` (env refs to ExternalSecret; MCP server defs)

Reference: full config keys from `~/.hermes/profiles/glados/config.yaml` on moltbot + Hermes security docs.

- [ ] **Step 1: Write the Hermes config.yaml (ConfigMap)**

`kubernetes/hermes/app/config.yaml` — a ConfigMap keyed `config.yaml` with:
```yaml
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: hermes-config
  namespace: hermes
data:
  config.yaml: |
    model:
      provider: openrouter
      model: deepseek/deepseek-v4-flash-0731
      api_key_env: OPENROUTER_API_KEY
    memory:
      provider: memini
    approvals:
      mode: smart
      cron_mode: deny
      single_query_mode: deny
      deny:
        - "*kubectl*"
        - "*flux *"
        - "*talosctl*"
        - "*config.yaml*"
        - "*chmod* /opt/hermes*"
        - "*chown* /opt/hermes*"
        - "*>*/hermes/plugins/*"
        - "*>*/opt/hermes/*"
    security:
      allow_private_urls: false
      allow_lazy_installs: false
      tirith_enabled: true
      website_blocklist:
        enabled: true
        domains:
          - "*.nexus"      # allowed explicitly elsewhere; see policy note
          # restrict .dev (internal/admin): add concrete internal hosts to deny
          - "capsule.whoverse.dev"
          - "*intel*.whoverse.dev"
    terminal:
      backend: local
      cwd: /tmp
    web:
      search_backend: searxng
      extract_backend: local-extract
    plugins:
      enabled:
        - web
        - web/local-extract
        - memini
```
NOTE: `.nexus` is allowed, `.dev` restricted — express via `website_blocklist.domains` listing the specific internal hosts you want denied (default SSRF already blocks private IPs; the blocklist is belt-and-suspenders for the public `.dev` hostnames). Adjust the domains list to the actual internal set.

Environment (ExternalSecret-backed): `OPENROUTER_API_KEY`, `NTFY_TOKEN`, `MEMINI_BASE_URL=http://moltbot-egress.network.svc.cluster.local:8081`, `MEMINI_HOME=personal/hermes`, `MEMINI_NAMESPACE=home-ops/hermes`, `HERMES_WRITE_SAFE_ROOT=/opt/data:/tmp`, `API_SERVER_ENABLED=false` (defer Open WebUI), `HERMES_DASHBOARD=1`, `HERMES_DASHBOARD_HOST=0.0.0.0`, `HERMES_DASHBOARD_OIDC_ISSUER=…`, `HERMES_DASHBOARD_OIDC_CLIENT_ID=…`. Set these in the HelmRelease `env` / from ExternalSecret and an MCP config block.

Also define `mcp_servers` in config.yaml for flux-operator-mcp (SSE `http://flux-operator-mcp.hermes.svc.cluster.local:8080`) and konflate (`http://konflate.default.svc.cluster.local:8080/mcp`), with the tool allowlist (see below). Follow the in-tree `hermes mcp` config schema (`hermes_cli/config.py` key `mcp_servers`; supply concrete shape at implementation).

- [ ] **Step 2: MCP tool whitelist**

Via `hermes mcp configure` (run once inside the pod) disable: `apply_kubernetes_manifest`, `install_flux_instance`, `delete_kubernetes_resource`, `get_kubeconfig_context`, `set_kubeconfig_context`. Persist as config so it survives restart.

- [ ] **Step 3: Seed config + install memini on first boot**

Add an initContainer (or postStart) that writes the ConfigMap's `config.yaml` to `/opt/data/config.yaml` and runs `hermes plugins install --enable eleboucher/memini-hermes $(cat /opt/data/.hermes-initialized 2>/dev/null || echo --force)` guarded by a sentinel file, so it seeds once on empty PVC. Document exact command in the HelmRelease `initContainers`.

- [ ] **Step 4: Validate + commit**

```bash
pre-commit run --files kubernetes/hermes/app/config.yaml kubernetes/hermes/app/helmrelease.yaml
just flate-test
git commit -m "feat(hermes): config.yaml (security/memory/web/model/mcp) + env wiring"
```

---

### Task 10: ExternalSecret (1Password)

**Files:**
- Create: `kubernetes/hermes/app/externalsecret.yaml`

Follow `.agents/skills/home-ops-external-secrets/SKILL.md` (ClusterSecretStore `onepassword-connect`). Create/refresh the 1Password item(s) for: `OPENROUTER_API_KEY`, `NTFY_TOKEN`, `HERMES_DASHBOARD_OIDC_CLIENT_SECRET` (if the client is confidential; for a public PKCE client this is omitted). Add the secret refs to the HelmRelease env and the apps public Credential `ExternalSecret`. Add `.op.env` stanza per AGENTS.md (`mise run secrets:env`).

- [ ] **Step 1: Write ExternalSecret**

`kubernetes/hermes/app/externalsecret.yaml`:
```yaml
---
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: hermes-secrets
  namespace: hermes
spec:
  refreshInterval: 1h
  secretStoreRef:
    kind: ClusterSecretStore
    name: onepassword-connect
  target:
    name: hermes-secrets
  data:
    - secretKey: OPENROUTER_API_KEY
      remoteRef:
        key: <1password-item>
        property: credential
    - secretKey: NTFY_TOKEN
      remoteRef:
        key: <ntfy-item>
        property: credential
    # OIDC client secret only if using a confidential client
```

- [ ] **Step 2: Add `.op.env` stanza + commit**

Append a `# ─── hermes ───` section to `.op.env` with the `op://…` URIs, then:
```bash
mise run secrets:env
pre-commit run --files kubernetes/hermes/app/externalsecret.yaml
git commit -m "feat(hermes): externalsecret for openrouter/ntfy/oidc"
```

---

### Task 11: Dashboard HTTPRoute (internal) + Kanidm OIDC client

**Files:**
- Create: `kubernetes/hermes/app/httproutes.yaml`
- External (operator) step: register Kanidm OIDC client

- [ ] **Step 1: HTTPRoute (internal only)**

Follow `home-ops-create-httproute`. Route `hermes.whoverse.dev` on the **internal** gateway (Tailscale) to the hermes dashboard (Service port 9119). Do NOT add an external (Cloudflare) route. `kubernetes/hermes/app/httproutes.yaml` targets the hermes Service's dashboard port.

- [ ] **Step 2: Kanidm OIDC client**

Register a public OIDC client in Kanidm (PKCE) with redirect URI `https://hermes.whoverse.dev/oauth2/callback` (mirroring headlamp/capacitor). Record `HERMES_DASHBOARD_OIDC_ISSUER` and `HERMES_DASHBOARD_OIDC_CLIENT_ID` (and secret if confidential) and wire into Task 9 env.

- [ ] **Step 3: Validate + commit**

```bash
pre-commit run --files kubernetes/hermes/app/httproutes.yaml
just flate-test
git commit -m "feat(hermes): internal dashboard httproutes + kanidm oidc client"
```

---

### Task 12: Watchdog cron/kanban setup (post-deploy, runtime)

After the agent is running and reachable, configure the proactive watchdog schedule inside Hermes (via the running agent or a seeded profile):

- [ ] **Step 1: Define watchdog cron jobs**

Use `hermes cron` (inside the pod) to add periodic health checks, e.g. every 15m: check HelmRelease/GitRepository readiness via the flux MCP; every 6h: cert expiry + storage headroom; report findings to ntfy. Provide the exact `hermes cron add` invocations and the prompt text for each (concrete, no placeholders), with `cron_mode: deny` honored (the watchdog must not run dangerous commands).

- [ ] **Step 2: Verify end-to-end**

```bash
kubectl -n hermes rollout status deployment/hermes
kubectl -n hermes logs deploy/hermes --tail=50
flux get kustomization hermes -n hermes
# dashboard reachable
curl -sI https://hermes.whoverse.dev | head
```
Expected: deploy ready, dashboard 200 (after OIDC), a watchdog ntfy push fires on first tick.

- [ ] **Step 3: Commit any runtime-generated config**

Bring runtime-created config (MCP tool whitelist, cron defs) back into tracked files (config.yaml / seed) so state is git-source-of-truth.

---

### Task 13: Cleanup — remove Holmes + dead chaski target

**Files:**
- Delete: `kubernetes/holmes/` (whole dir)
- Delete: `kubernetes/chaski/app/config.d/10-holmes.yaml`
- Modify: `kubernetes/chaski/app/kustomization.yaml` (drop 10-holmes)
- Modify: `kubernetes/kustomization.yaml` (holmes not listed — confirm it's already absent)

- [ ] **Step 1: Remove holmes dir + chaski target**

```bash
git rm -r kubernetes/holmes
git rm kubernetes/chaski/app/config.d/10-holmes.yaml
```
Also remove the `holmes:` target + `flux-alert` route lines from any merged chaski config (ensure no dangling reference to `holmes-holmes.holmes.svc.cluster.local`).

- [ ] **Step 2: Validate + commit**

```bash
just flate-test
pre-commit run --all-files
git commit -m "chore: remove disabled holmes + dead chaski holmes target"
```

---

### Task 14: Final validation & rollout

- [ ] **Step 1: Full pre-commit + flate**

```bash
pre-commit run --all-files
just flate-test
```
Expected: all pass.

- [ ] **Step 2: Push branch, open PR, reconcile**

```bash
git push -u origin <branch>
gh pr create --fill
flux reconcile source git home-ops -n flux-system
flux reconcile kustomization cluster -n flux-system
```

- [ ] **Step 3: Post-rollout verification**

Run the checks from Task 12 Step 2 plus:
```bash
kubectl -n hermes get pods -o wide           # both deployments ready, gVisor running
kubectl -n hermes auth can-i --list 2>/dev/null | grep -iE "secrets|pods|deployments"  # UI sanity
```
Confirm: no `secrets` read, pod-delete allowed, deployments read-only — matching the RBAC in Task 4.
