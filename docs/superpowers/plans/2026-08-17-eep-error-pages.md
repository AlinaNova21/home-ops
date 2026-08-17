# eep Error Pages Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the redirect-based `tarampampam/error-pages` stack with the `ishioni/eep` Proxy-Wasm error-page filter attached directly to both Envoy Gateways (`internal` + `external`), preserving status codes and removing the separate error-pages workloads, HTTPRoutes, and BackendTrafficPolicy redirects.

**Architecture:** One `EnvoyExtensionPolicy` per Gateway attaches the eep WASM module (`oci://ghcr.io/ishioni/eep:0.2.1`, sha256-pinned) to the Envoy instances. Eep rewrites 4xx/5xx response bodies in-place (no redirect, status preserved) and content-negotiates HTML/JSON/XML/plain from the request `Accept` header. A single `ClientTrafficPolicy` raises both gateways' response buffer from Envoy Gateway's 32 KiB default to 1 MiB (several of eep's HTML themes exceed 32 KiB). The old per-status-code redirect entries, error-pages pods, and `errors.whoverse.*` routes are deleted in a second commit after the filter is verified working.

**Tech Stack:** Envoy Gateway v1.9.0 (pinned via `gateway-helm` OCI chart, digest-pinned), `gateway.envoyproxy.io/v1alpha1` `EnvoyExtensionPolicy` + `ClientTrafficPolicy`, Flux CD GitOps (`Kustomization/cluster`), eep v0.2.1 WASM (Go, `GOOS=wasip1`). All three CRDs are already validated by the repo's schema server (`k8s-schemas.home-operations.com`) and the CI kubeconform catalog (verified HTTP 200 for `envoyextensionpolicy_v1alpha1.json`, `clienttrafficpolicy_v1alpha1.json`).

**Context for the executor (read before starting):**

- Live cluster facts (verified 2026-08-17): `EnvoyExtensionPolicy` CRD v1alpha1 schema includes `targetRefs`, `targetSelectors`, `failOpen`, `wasm[].code.image.sha256`, and a free-form `wasm[].config` (`x-kubernetes-preserve-unknown-fields`). `ClientTrafficPolicy` v1alpha1 schema includes `connection.bufferLimit`. Gateway `Envoy` image: `docker.io/envoyproxy/gateway:v1.9.0` (meets eep's minimum Envoy v1.39.0 / EG v1.9.0).
- eep image `0.2.1` digest: `sha256:0d5b4e3f6fb16b82c05e03c5cce88dd6c283221ca4bb8e1f58ba4b47f0fdffeb` (verified via `crane digest`).
- Gateways: `network/external` (Cloudflare Tunnel, ClusterIP, listeners `*.whoverse.nexus` + `*.beee.gay`) and `network/internal` (Tailscale LoadBalancer, listener `*.whoverse.dev`).
- Current error-pages themes: external = `cats`, internal = `noise` (keep via two policies).
- eep equivalents of the old curated code list: old BTPs redirected only 19 codes (400,401,403,404,405,407,408,409,410,411,412,413,416,418,429,500,502,503,504,505). eep's default covers **all** 4xx/5xx — an intentional superset. No `filterCodes` needed.
- **Blast radius / staging:** eep policies attach to the gateway data path. Adding an `EnvoyExtensionPolicy`/`ClientTrafficPolicy` triggers an Envoy deployment rollout on the affected gateway (brief interruption ~10–30 s). Use `failOpen: true` for the initial rollout so a misconfigured/failed WASM load degrades to default error bodies instead of breaking all traffic; flip to `failOpen: false` after burn-in (Task 4). Announce the rollout to the user before applying/reconciling.
- All work happens in a git worktree: `.worktrees/feat/eep-error-pages` (create from `main` with `just worktree-create feat/eep-error-pages`). Run `mise run secrets:env`, `mise run hooks:install`, and `just flate-test` (baseline) on first entry.

---

## File Structure

**Create:**

| File | Purpose |
|---|---|
| `kubernetes/network/envoy-gateway/config/envoy-extension-policies/kustomization.yaml` | Kustomize aggregator for the new dir |
| `kubernetes/network/envoy-gateway/config/envoy-extension-policies/eep-internal.yaml` | `EnvoyExtensionPolicy` → Gateway `internal`, theme `noise` |
| `kubernetes/network/envoy-gateway/config/envoy-extension-policies/eep-external.yaml` | `EnvoyExtensionPolicy` → Gateway `external`, theme `cats` |
| `kubernetes/network/envoy-gateway/config/client-traffic-policies/kustomization.yaml` | Kustomize aggregator for the new dir |
| `kubernetes/network/envoy-gateway/config/client-traffic-policies/eep-buffer.yaml` | `ClientTrafficPolicy` → both gateways, `connection.bufferLimit: 1Mi` |

**Modify:**

| File | Change |
|---|---|
| `kubernetes/network/envoy-gateway/config/kustomization.yaml` | Add `envoy-extension-policies` + `client-traffic-policies`; drop `backend-traffic-policies` (Task 3) |
| `kubernetes/default/kustomization.yaml` | Remove `- error-pages/ks.yaml` (Task 3) |

**Delete:**

| Path | Task |
|---|---|
| `kubernetes/default/error-pages/` (whole dir: `ks.yaml`, `app-internal/`, `app-external/`) | 3 |
| `kubernetes/network/envoy-gateway/config/backend-traffic-policies/` (whole dir: `error-pages-internal.yaml`, `error-pages-external.yaml`, `kustomization.yaml`) | 3 |

Nothing in `kubernetes/kustomization.yaml` (namespace aggregator) changes — `error-pages` lives under the existing `default` namespace entry.

---

### Task 1: Baseline capture and verification

Capture the current behavior so the swap can be proven equivalent-or-better. No repo changes in this task.

**Files:** none.

- [ ] **Step 1: Confirm clean baseline in the worktree**

```bash
cd .worktrees/feat/eep-error-pages
git status --short          # expect: empty (or only untracked .mcp.json)
just flate-test             # expect: "✓ N passed" and exit 0
```

- [ ] **Step 2: Record current error behavior through the internal gateway**

```bash
echo "--- baseline: 404 on random path (no HTTPRoute match) ---"
curl -s -o /dev/null -w 'status=%{http_code} redirect=%{redirect_url}\n' \
  https://kguardian.whoverse.dev/no-such-path-xyz
echo "--- baseline: headers of same request ---"
curl -s -I https://kguardian.whoverse.dev/no-such-path-xyz | head -8
echo "--- baseline: body of same request ---"
curl -s https://kguardian.whoverse.dev/no-such-path-xyz | head -c 300
```

Expected before the swap: `status=302`, a `location: http://errors.whoverse.dev/404` header, and (following the redirect) the `noise`-theme HTML page body. Save this output into the task notes — the Task 3 verification must show `status=404` with a branded in-place body and **no** `location` header.

- [ ] **Step 3: Record current behavior through the external gateway (optional — needs public DNS/tunnel from the workstation)**

```bash
curl -s -o /dev/null -w 'status=%{http_code} redirect=%{redirect_url}\n' \
  https://grocy.whoverse.nexus/no-such-path-xyz
```

Expected before: `status=302`, `location: http://errors.whoverse.nexus/404`. If the tunnel is unreachable from the LAN, mark this step skipped and rely on the internal-gateway checks.

- [ ] **Step 4: Record the currently deployed error-pages state**

```bash
kubectl get pods -n default -l app.kubernetes.io/name=error-pages 2>/dev/null || kubectl get pods -n default | grep error-pages
kubectl get backendtrafficpolicy -n network
kubectl get httproute -n default | grep error
```

Expected: two healthy error-pages pods, two `BackendTrafficPolicy` (error-pages-internal/external), two HTTPRoutes (`errors-whoverse-dev`, `errors-whoverse-nexus`). Keep this output; Task 3 must show them gone.

---

### Task 2: Add eep WASM policies (keep old stack in place)

Add the `EnvoyExtensionPolicy` resources and the buffer `ClientTrafficPolicy`. The old redirect stack stays active during this task — the 19 BTP-redirected codes are unchanged (302 → error-pages), so this is a low-risk staging phase. eep already handles every **other** 4xx/5xx code in-place (superset), and once Task 3 removes the redirects, all codes are in-place.

**Files:**
- Create: `kubernetes/network/envoy-gateway/config/envoy-extension-policies/kustomization.yaml`
- Create: `kubernetes/network/envoy-gateway/config/envoy-extension-policies/eep-internal.yaml`
- Create: `kubernetes/network/envoy-gateway/config/envoy-extension-policies/eep-external.yaml`
- Create: `kubernetes/network/envoy-gateway/config/client-traffic-policies/kustomization.yaml`
- Create: `kubernetes/network/envoy-gateway/config/client-traffic-policies/eep-buffer.yaml`
- Modify: `kubernetes/network/envoy-gateway/config/kustomization.yaml`

- [ ] **Step 1: Create the two EnvoyExtensionPolicy manifests**

`kubernetes/network/envoy-gateway/config/envoy-extension-policies/eep-internal.yaml`:

```yaml
---
# yaml-language-server: $schema=https://k8s-schemas.home-operations.com/gateway.envoyproxy.io/envoyextensionpolicy_v1alpha1.json
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: EnvoyExtensionPolicy
metadata:
  name: eep-internal
  namespace: network
spec:
  targetRefs:
    - group: gateway.networking.k8s.io
      kind: Gateway
      name: internal
  wasm:
    - name: eep
      # Must be unique among Wasm extensions attached to the same Envoy instance.
      rootID: eep
      code:
        type: Image
        image:
          # Release tag + digest pinned; eep 0.2.1 (verified via `crane digest`).
          url: oci://ghcr.io/ishioni/eep:0.2.1
          sha256: 0d5b4e3f6fb16b82c05e03c5cce88dd6c283221ca4bb8e1f58ba4b47f0fdffeb
      # Envoy Gateway serializes this object as JSON for the Wasm plugin.
      config:
        theme: noise
        showDetails: false
        locale: auto
        logLevel: warn
        # Omitted filterCodes => replace every 4xx/5xx response.
      # fail-open during rollout: if the Wasm module fails to load, traffic passes
      # through with default error bodies instead of breaking the gateway.
      failOpen: true
```

`kubernetes/network/envoy-gateway/config/envoy-extension-policies/eep-external.yaml`:

```yaml
---
# yaml-language-server: $schema=https://k8s-schemas.home-operations.com/gateway.envoyproxy.io/envoyextensionpolicy_v1alpha1.json
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: EnvoyExtensionPolicy
metadata:
  name: eep-external
  namespace: network
spec:
  targetRefs:
    - group: gateway.networking.k8s.io
      kind: Gateway
      name: external
  wasm:
    - name: eep
      # Must be unique among Wasm extensions attached to the same Envoy instance.
      rootID: eep
      code:
        type: Image
        image:
          # Release tag + digest pinned; eep 0.2.1 (verified via `crane digest`).
          url: oci://ghcr.io/ishioni/eep:0.2.1
          sha256: 0d5b4e3f6fb16b82c05e03c5cce88dd6c283221ca4bb8e1f58ba4b47f0fdffeb
      config:
        theme: cats
        showDetails: false
        locale: auto
        logLevel: warn
      failOpen: true
```

- [ ] **Step 2: Create the buffer ClientTrafficPolicy**

`kubernetes/network/envoy-gateway/config/client-traffic-policies/eep-buffer.yaml`:

```yaml
---
# yaml-language-server: $schema=https://k8s-schemas.home-operations.com/gateway.envoyproxy.io/clienttrafficpolicy_v1alpha1.json
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: ClientTrafficPolicy
metadata:
  name: eep-buffer
  namespace: network
spec:
  targetRefs:
    - group: gateway.networking.k8s.io
      kind: Gateway
      name: internal
    - group: gateway.networking.k8s.io
      kind: Gateway
      name: external
  connection:
    # Envoy Gateway's default is 32KiB. Use at least 1Mi for eep's HTML responses.
    bufferLimit: 1Mi
```

- [ ] **Step 3: Create the kustomization aggregators**

`kubernetes/network/envoy-gateway/config/envoy-extension-policies/kustomization.yaml`:

```yaml
---
# yaml-language-server: $schema=https://json.schemastore.org/kustomization
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - eep-internal.yaml
  - eep-external.yaml
```

`kubernetes/network/envoy-gateway/config/client-traffic-policies/kustomization.yaml`:

```yaml
---
# yaml-language-server: $schema=https://json.schemastore.org/kustomization
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - eep-buffer.yaml
```

- [ ] **Step 4: Wire the new dirs into the network config kustomization**

Modify `kubernetes/network/envoy-gateway/config/kustomization.yaml` `resources:` to:

```yaml
resources:
  - gateway.yaml
  - envoy-proxy-config.yaml
  - httproutes
  - envoy-extension-policies
  - client-traffic-policies
  - backend-traffic-policies
```

(`backend-traffic-policies` is removed in Task 3; keep it listed here until then.)

- [ ] **Step 5: Validate locally**

```bash
just flate-test                       # expect: "✓ 189 passed", exit 0 (no count change --
                                      #   EEP/CTP are non-Flux CRs; flate only counts Flux objects)
pre-commit run --all-files            # expect: all hooks pass (gitleaks, trufflehog, flate-test)
kubectl apply --dry-run=client -k kubernetes/network/envoy-gateway/config/
```

Expected: dry-run succeeds (schema validation of both new CRDs against the live cluster), no errors.

- [ ] **Step 6: Commit (staging phase lands without the removal)**

```bash
git add kubernetes/network/envoy-gateway/config/
git commit -m "feat(network): add eep wasm error pages policies to gateways"
```

- [ ] **Step 7: Deploy and verify the staging state**

Announce first (gateway rollouts): then

```bash
git push origin feat/eep-error-pages
flux reconcile kustomization envoy-gateway-config -n network
kubectl get envoyextensionpolicy,clienttrafficpolicy -n network
```

Expected: `envoyextensionpolicy.gateway.envoyproxy.io/eep-internal` and `/eep-external` and `clienttrafficpolicy.gateway.envoyproxy.io/eep-buffer` exist. Watch the gateway rollouts complete with (Envoy deployments are hash-named, e.g. `envoy-network-internal-f0b82637` — always select by label, never by hardcoded name):

```bash
kubectl rollout status deployment -n network -l gateway.envoyproxy.io/owning-gateway-name=internal --timeout=5m
kubectl rollout status deployment -n network -l gateway.envoyproxy.io/owning-gateway-name=external --timeout=5m
kubectl get gateway -n network   # expect Status Programmed=True for both
```

Check the WASM module actually loaded in Envoy logs (best-effort — a clean startup shows no `wasm`/`eep` startup errors):

```bash
kubectl logs -n network -l gateway.envoyproxy.io/owning-gateway-name=internal --tail=200 --prefix=false 2>/dev/null | grep -i "wasm\|eep" | head
```

Expected: no fatal WASM/extension errors; the eep init line may appear (`[eep] ... ` startup log at `warn` or the logLevel). If the Wasm fails to load, `failOpen: true` keeps traffic flowing — debug from the logs before proceeding, and consider reverting Task 2's commit.

- [ ] **Step 8: Confirm the 19 BTP-redirected codes are unchanged (regression check)**

```bash
curl -s -o /dev/null -w 'status=%{http_code} redirect=%{redirect_url}\n' \
  https://kguardian.whoverse.dev/no-such-path-xyz
```

Expected: **still `status=302`** redirecting to `errors.whoverse.dev/404` (old stack still owns these codes). This proves the staging change didn't break existing behavior.

---

### Task 3: Remove the old error-pages stack

Delete the error-pages app, its routes, and the BackendTrafficPolicy redirects. eep now owns all 4xx/5xx responses in-place.

**Files:**
- Delete: `kubernetes/default/error-pages/` (entire directory)
- Delete: `kubernetes/network/envoy-gateway/config/backend-traffic-policies/` (entire directory)
- Modify: `kubernetes/default/kustomization.yaml` (remove `- error-pages/ks.yaml`)
- Modify: `kubernetes/network/envoy-gateway/config/kustomization.yaml` (remove `backend-traffic-policies` line)

- [ ] **Step 1: Delete the error-pages app tree**

```bash
git rm -r kubernetes/default/error-pages
```

- [ ] **Step 2: Delete the BackendTrafficPolicy redirects**

```bash
git rm -r kubernetes/network/envoy-gateway/config/backend-traffic-policies
```

- [ ] **Step 3: Remove the aggregator references**

`kubernetes/default/kustomization.yaml` — delete the line `  - error-pages/ks.yaml` (resources list should then read: `ns.yaml`, `barcodebuddy`, `grocy`, `konflate`, `linkstack`, `mailpit`, `speedtest-tracker`, `yuvomi`).

`kubernetes/network/envoy-gateway/config/kustomization.yaml` — the `resources:` list now ends with `- client-traffic-policies` (no `backend-traffic-policies` line).

- [ ] **Step 4: Validate locally**

```bash
just flate-test
pre-commit run --all-files
kubectl apply --dry-run=client -k kubernetes/network/envoy-gateway/config/
kubectl apply --dry-run=client -k kubernetes/default/
```

Expected: all pass. `rg -n "error-pages|errors-whoverse" kubernetes/ --glob '*.yaml'` returns nothing.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "refactor(network): replace error-pages redirect stack with eep wasm filter"
```

- [ ] **Step 6: Deploy**

Announce first (this removes error-pages pods and triggers gateway config reloads):

```bash
git push origin feat/eep-error-pages
flux reconcile kustomization cluster -n flux-system
```

- [ ] **Step 7: Verify old stack is gone**

```bash
kubectl get pods -n default | grep error-pages        # expect: no output
kubectl get backendtrafficpolicy -n network           # expect: No resources found
kubectl get httproute -n default | grep error         # expect: no output
kubectl get envoyextensionpolicy,clienttrafficpolicy -n network
# expect: eep-internal, eep-external, eep-buffer listed
```

- [ ] **Step 8: Verify in-place behavior (the core acceptance test) — internal gateway**

```bash
echo "--- 404 in place, status preserved, no redirect ---"
curl -s -o /dev/null -w 'status=%{http_code} redirect=%{redirect_url}\n' \
  https://kguardian.whoverse.dev/no-such-path-xyz
# expect: status=404 redirect= (empty)  -- vs baseline Task 1 which was status=302

echo "--- HTML body is the noise theme ---"
curl -s https://kguardian.whoverse.dev/no-such-path-xyz | grep -io "noise\|error-pages\|eep" | head -3

echo "--- JSON negotiation for API clients ---"
curl -s -H 'Accept: application/json' https://kguardian.whoverse.dev/no-such-path-xyz \
  -w '\nstatus=%{http_code} type=%{content_type}\n'
# expect: status=404, content-type: application/json, JSON body

echo "--- plain-text negotiation ---"
curl -s -H 'Accept: text/plain' https://kguardian.whoverse.dev/no-such-path-xyz
# expect: plain-text body, still status 404
```

If any content type comes back as HTML instead of the negotiated format, check the `content_type` header (`curl -sI`) and that the request `Accept` header really reached Envoy (no client-side proxy rewriting it).

- [ ] **Step 9: Verify external gateway (optional — needs reachable public DNS/tunnel)**

```bash
curl -s -o /dev/null -w 'status=%{http_code} redirect=%{redirect_url}\n' \
  https://grocy.whoverse.nexus/no-such-path-xyz
# expect: status=404 redirect= (empty)
curl -s https://grocy.whoverse.nexus/no-such-path-xyz | grep -io "cats" | head -1
# expect: the cats theme HTML is served
```

- [ ] **Step 10: Verify a 5xx code (optional, deterministic method)**

`503` needs an upstream that's actually failing. Easiest deterministic test (temporary direct apply — do **not** commit):

```bash
kubectl create ns scratch-test-error
kubectl -n scratch-test-error create deploy test-503 --image=nginx:alpine --replicas=2
kubectl -n scratch-test-error scale deploy test-503 --replicas=0   # no ready pods -> 503
cat <<'EOF' | kubectl -n scratch-test-error apply -f -
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: test-503
spec:
  parentRefs:
    - name: internal
      namespace: network
  hostnames:
    - test503.whoverse.dev
  rules:
    - backendRefs:
        - name: test-503
          port: 80
EOF
curl -s -o /dev/null -w 'status=%{http_code} redirect=%{redirect_url}\n' \
  https://test503.whoverse.dev/
# expect: status=503, empty redirect, eep body (check with -s | head)
kubectl delete ns scratch-test-error
```

Expected: `status=503` with the noise-theme in-place body. If `test503.whoverse.dev` doesn't resolve, run the same curl with `--resolve test503.whoverse.dev:443:$(kubectl get svc envoy-internal -n network -o jsonpath='{.status.loadBalancer.ingress[0].ip}')`.

- [ ] **Step 11: Confirm DNS cleanup of the dead error-pages hosts (best-effort, TTL-dependent)**

```bash
dig +short errors.whoverse.dev           # expect: eventually empty (NXDOMAIN) after TTL
dig +short errors.whoverse.nexus         # expect: eventually empty after TTL
```

If records linger, external-dns picks them up on its next sync once the HTTPRoutes are gone; no manual action.

---

### Task 4: Final validation, hardening, and cleanup

**Files:** none by default (optional `failOpen` flip below).

- [ ] **Step 1: Run the repo validation gates in the worktree**

```bash
just flate-test
pre-commit run --all-files
just flate-diff          # expect: shows only the eep additions + error-pages removals
```

- [ ] **Step 2: CI-equivalent kubeconform check (matches `.github/workflows/validate-kubernetes.yml`)**

```bash
for dir in kubernetes/flux-config kubernetes; do
  kustomize build "$dir" | kubeconform -strict -ignore-missing-schemas \
    -schema-location default \
    -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'
done
```

Expected: no errors for the new `EnvoyExtensionPolicy`/`ClientTrafficPolicy` (catalog entries verified present).

- [ ] **Step 3: Push and confirm CI passes, then merge via PR**

```bash
git push origin feat/eep-error-pages
gh pr create --fill
# after CI is green: gh pr merge --squash --delete-branch   (requires explicit user approval)
```

- [ ] **Step 4 (optional hardening, after a burn-in period): flip `failOpen` to false**

eep stuck a few days without issues → set `failOpen: false` in both `EnvoyExtensionPolicy` manifests so a failed WASM load surfaces loudly (gateway returns 5xx) instead of silently serving default error bodies. Follow the same commit → reconcile → verify loop from Tasks 2/3.

- [ ] **Step 5: Clean up the worktree**

```bash
cd /home/alina/projects/home-ops
just worktree-clean feat/eep-error-pages
```

---

## Rollback

The swap is two independent commits, so rollback is cheap either way:

**Instant partial rollback (30 s, no git):** delete the eep policies and the CTP — error pages revert to Envoy's built-in default bodies immediately, traffic is otherwise unaffected:

```bash
kubectl -n network delete envoyextensionpolicy eep-internal eep-external
kubectl -n network delete clienttrafficpolicy eep-buffer
```

**Full GitOps rollback:** revert the Task 3 commit (restores error-pages app + BTP redirects), and if needed the Task 2 commit (removes eep policies). Then reconcile:

```bash
git revert --no-edit <task3-commit> <task2-commit>   # order: 3 first
git push origin feat/eep-error-pages
flux reconcile kustomization cluster -n flux-system
```

Follow with the Task 1 baseline curls — expect the original `302 → errors.whoverse.*/<code>` behavior to return. Note: DNS records for `errors.whoverse.*` recreate once the HTTPRoutes return.

## Known Risks & Mitigations

| Risk | Mitigation |
|---|---|
| eep v0.2.1 is a ~1-day-old project (first release 2026-08-16, no LICENSE file despite README claiming Apache-2.0; 4 stars) | Tag+digest pinned; evaluate before any upgrade; monitor CHANGELOG; ask upstream about licensing if reuse concerns arise |
| WASM in the gateway data path; failure could break all gateway traffic | `failOpen: true` during rollout (Task 2), flip to false only after burn-in; digest pinning prevents supply-chain drift |
| Envoy WASI hostcall coupling (needs Envoy ≥ v1.39 / EG ≥ v1.9) — an EG upgrade could regress eep | Keep EG pinned at 1.9.0 until explicitly testing eep on a newer EG; upgrade eep (not EG) to track fixes |
| 1 MiB response buffer on both gateways (global buffering change) | Accepted cost (per-response memory only while buffered); revisit if memory pressure appears |
| eep fetches the wasm image from ghcr directly (bypasses spegel/zot caching) | ghcr is reachable from cluster today; digest pin + `failOpen` covers pull failures |
| kubeconform/flate must not reject the new CRDs | Both verified in Task 4 Step 1–2; schema server + datreeio catalog confirmed 200s |