# Flux-Managed SOPS Decryption — Design

**Date:** 2026-07-24
**Status:** Approved
**Owner:** home-ops

---

## 1. Context

Today, `kubernetes/bootstrap/op.sops.yaml` is the only Kubernetes-resident SOPS file. It contains the 1Password Connect credentials Secret and is decrypted and applied once at bootstrap via `sops -d | kubectl apply -f -`. Every other `ExternalSecret` in the cluster (21 across 9 namespaces) depends on that Secret existing.

This breaks in two ways:
1. The Secret isn't GitOps-managed — it can drift out of the cluster (today's incident).
2. Anyone touching the bootstrap Secret has to remember the manual ritual.

Goal: move the bootstrap Secret into a Flux-managed path with Flux-side SOPS decryption, backed by a dedicated age key that lives in the cluster as a Kubernetes Secret.

## 2. Goals

- Flux reconciles the 1Password Connect credentials Secret via a normal `Kustomization`.
- The Secret is SOPS-encrypted in git with two recipients: the existing personal age key (operator fallback) and a new Flux-specific age key (cluster-resident).
- A manual one-shot bootstrap step installs the Flux age private key as `Secret/flux-system/sops-age`. After that, Flux owns the rest.
- Talos SOPS files are unaffected (different recipients, workstation-only).
- The current 21 ExternalSecrets continue working without modification.

## 3. Non-goals

- Eliminating the 1Password Connect dependency.
- Encrypting `talsecret.sops.yaml` with the new Flux key (it stays personal age + GPG for workstation `talhelper` use).
- Replacing the personal age key with the new Flux key on the operator's `~/.config/sops/age/keys.txt` (keyrings stay separate).
- Migrating Talos secrets to Flux-managed SOPS.

## 4. Architecture

### 4.1 Key layout

| Path | Type | Decryptable by |
|---|---|---|
| `~/.config/sops/age/keys.txt` | personal age private key (existing) | operator workstation only |
| `~/.config/sops/age/flux-home-ops.txt` | **new** Flux-specific age private key | operator workstation only |
| `Secret/flux-system/sops-age` (key `sops.agekey`) | Flux age private key as k8s Secret | cluster-resident (Flux) |

The personal and Flux keys are **separate keypairs** — losing one does not compromise the other.

### 4.2 SOPS rules (`.sops.yaml`)

```yaml
creation_rules:
  # Bootstrap: the Flux-age-key Secret (manual one-shot)
  - path_regex: kubernetes/bootstrap/.*\.sops\.yaml$
    age: <personal-pubkey>
    pgp: <personal-gpg-fpr>

  # Flux-managed k8s secrets: dual recipients
  - path_regex: kubernetes/flux-config/sops/.*\.sops\.yaml$
    age: <personal-pubkey>, <flux-pubkey>

  # Talos: unchanged
  - path_regex: talos/.*\.sops\.yaml$
    age: <personal-pubkey>
    pgp: <personal-gpg-fpr>
```

`kubernetes/flux-config/sops/.*\.sops\.yaml$` is decryptable by either key — operator convenience + Flux self-sufficiency.

### 4.3 File moves and additions

| Old | New | Reason |
|---|---|---|
| `kubernetes/bootstrap/op.sops.yaml` (decrypts to `Secret/onepassword-connect/onepassword-connect`) | `kubernetes/flux-config/sops/onepassword-connect-secret.sops.yaml` | Flux-reconciled path |
| — | `kubernetes/flux-config/sops/kustomization.yaml` | lists the above resource |
| — | `kubernetes/flux-config/sops/ks.yaml` | new Flux `Kustomization` reconciling `./flux-config/sops` with `spec.decryption.provider: sops` and `spec.decryption.secretRef.name: sops-age` |
| — | `kubernetes/bootstrap/flux-age-key.sops.yaml` | decrypts to `Secret/flux-system/sops-age` (key `sops.agekey`) — manual one-shot bootstrap |

### 4.4 Flux `Kustomization` shape

```yaml
# kubernetes/flux-config/sops/ks.yaml
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: flux-sops
  namespace: flux-system
spec:
  interval: 30m
  path: "./flux-config/sops"
  sourceRef:
    kind: OCIRepository
    name: home-ops
    namespace: flux-system
  prune: true
  decryption:
    provider: sops
    secretRef:
      name: sops-age
  healthChecks:
    - apiVersion: v1
      kind: Secret
      name: onepassword-connect
      namespace: onepassword-connect
  timeout: 5m
  wait: true
```

The `decryption.secretRef.name` references the bootstrap-installed `Secret/flux-system/sops-age`. Once that Secret exists, Flux decrypts everything under `./flux-config/sops` on every reconcile.

### 4.5 The `Secret/sops-age` payload

```yaml
# decrypted form of kubernetes/bootstrap/flux-age-key.sops.yaml
apiVersion: v1
kind: Secret
metadata:
  name: sops-age
  namespace: flux-system
type: Opaque
stringData:
  sops.agekey: |
    # public key: age1xxx...
    AGE-SECRET-KEY-1XXX...
```

Flux expects the age private key under the key `sops.agekey` in the named Secret. This is the documented SOPS provider format for `kustomize-controller`.

### 4.6 Bootstrap ritual (one-shot, per cluster rebuild)

```bash
just bootstrap-sops-key
```

`Justfile` recipe:

```just
bootstrap-sops-key:
    SOPS_AGE_KEY_FILE={{ sops_age_key_file }} \
      sops -d kubernetes/bootstrap/flux-age-key.sops.yaml | kubectl apply -f -
    flux reconcile kustomization flux-sops -n flux-system
```

After this single command:
1. `Secret/flux-system/sops-age` exists in cluster.
2. Flux `Kustomization/flux-sops` reconciles `./flux-config/sops`, decrypts the 1Password Connect Secret, and applies it.
3. `Kustomization/cluster` sees `Secret/onepassword-connect` already exists, no drift.

Future cluster rebuilds only need this one command. The bootstrap is idempotent (kubectl apply is safe to re-run).

### 4.7 Recovery model

- **Personal key compromise** (loses operator laptop): rotate the Flux keypair, re-encrypt the k8s sops files, re-apply bootstrap Secret. Personal key still needed to decrypt `flux-age-key.sops.yaml` (until that file is also re-encrypted — could use only GPG).
- **Flux key compromise** (cluster breach): re-encrypt all `kubernetes/flux-config/sops/*.sops.yaml` files with a new Flux keypair, manually rotate `Secret/flux-system/sops-age`. Personal-key fallback means the operator can decrypt locally during incident response.
- **Both keys lost**: lose ability to decrypt `kubernetes/flux-config/sops/*.sops.yaml`. Mitigation: rotate 1Password Connect credentials, regenerate new keys, start fresh.

## 5. File-by-file changes

### 5.1 `~/.config/sops/age/flux-home-ops.txt` (operator workstation, NOT in git)

```
# created: <date>
# public key: age1<new-pubkey>
AGE-SECRET-KEY-1<...>
```

### 5.2 `.sops.yaml` (modified)

Add `path_regex: kubernetes/flux-config/sops/.*\.sops\.yaml$` rule with dual recipients.

### 5.3 `kubernetes/flux-config/sops/kustomization.yaml` (new)

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - onepassword-connect-secret.sops.yaml
```

### 5.4 `kubernetes/flux-config/sops/onepassword-connect-secret.sops.yaml` (new)

Same content as the existing `op.sops.yaml` (the 1Password Connect Secret), re-encrypted with `[personal-age, flux-age]` recipients per the new rule.

### 5.5 `kubernetes/flux-config/sops/ks.yaml` (new)

The Flux `Kustomization` shown in §4.4.

### 5.6 `kubernetes/bootstrap/flux-age-key.sops.yaml` (new)

Contains `Secret/flux-system/sops-age`. Encrypted with `[personal-age, personal-gpg]` per the existing bootstrap rule.

### 5.7 `kubernetes/bootstrap/op.sops.yaml` (deleted)

Superseded by `kubernetes/flux-config/sops/onepassword-connect-secret.sops.yaml`.

### 5.8 `Justfile` (modified)

Add recipe shown in §4.6.

### 5.9 `AGENTS.md` (modified)

Add a section under "Workstation Secrets" or new "SOPS" section documenting:
- Personal vs Flux key separation
- Bootstrap ritual (`just bootstrap-sops-key`)
- How to add a new k8s SOPS file (`sops -e -i kubernetes/flux-config/sops/foo.sops.yaml`)

## 6. Migration steps (after files are committed)

1. **Generate Flux age keypair** on workstation: `age-keygen -o ~/.config/sops/age/flux-home-ops.txt`. Capture the public key.
2. **Update `.sops.yaml`** with the new rule and the Flux public key.
3. **Encrypt the bootstrap Secret** (private key as stringData) with personal age + GPG → `kubernetes/bootstrap/flux-age-key.sops.yaml`.
4. **Move `op.sops.yaml` content** to `kubernetes/flux-config/sops/onepassword-connect-secret.sops.yaml`, re-encrypt with personal age + Flux age.
5. **Commit + push.** The OCI artifact rebuilds.
6. **Run `just bootstrap-sops-key`** on workstation to install the age key Secret.
7. **Verify**: Flux reconciles `Kustomization/flux-sops`, applies the 1Password Connect Secret, ClusterSecretStore becomes Ready, all ExternalSecrets sync.

## 7. Validation

```bash
# Local build (CI equivalent)
kustomize build kubernetes/flux-config | kubeconform -strict -ignore-missing-schemas \
  -schema-location default \
  -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'

# Decryption roundtrip (per file, per key)
for f in kubernetes/bootstrap/*.sops.yaml kubernetes/flux-config/sops/*.sops.yaml; do
  SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt sops -d "$f" > /dev/null
  SOPS_AGE_KEY_FILE=~/.config/sops/age/flux-home-ops.txt sops -d "$f" > /dev/null
done

# Cluster verification (post-migration)
kubectl get secret -n flux-system sops-age
kubectl get kustomization flux-sops -n flux-system
kubectl get secret -n onepassword-connect onepassword-connect
kubectl get clustersecretstore onepassword-connect -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}'
```

## 8. Risks

| Risk | Mitigation |
|---|---|
| Personal age key compromised | Rotate Flux keypair only; operator retains personal-key access to the bootstrap Secret to re-encrypt |
| Flux age key compromised | Re-encrypt `kubernetes/flux-config/sops/*.sops.yaml` with new Flux key; rotate `Secret/flux-system/sops-age` |
| Both keys lost | Regenerate 1Password Connect credentials and restart (acceptable disaster recovery) |
| Operator forgets which keyring to use for decrypt | `just bootstrap-sops-key` and `just decrypt-sops FILE=...` recipes abstract this |
| `Secret/sops-age` accidentally deleted in cluster | Same recovery as today's `Secret/onepassword-connect` — run `just bootstrap-sops-key` again |
| CI doesn't validate SOPS decryptability | Future improvement: pre-commit hook that runs `sops -d` roundtrip against each key |

## 9. Open questions

None — all four design choices resolved.

## 10. Implementation plan

Implementation plan: `docs/superpowers/plans/2026-07-24-flux-sops-decryption.md`.
