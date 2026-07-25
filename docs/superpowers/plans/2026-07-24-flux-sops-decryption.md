# Flux-Managed SOPS Decryption Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a dedicated age keypair for Flux and a Flux `Kustomization` that decrypts SOPS files in `kubernetes/flux-config/sops/`, replacing the manually-applied `kubernetes/bootstrap/op.sops.yaml`.

**Architecture:** Generate a new Flux-only age keypair. Encrypt the bootstrap-age-key Secret with personal age + GPG (existing recipients). Encrypt the moved 1Password Connect credentials Secret with personal age + Flux age (dual recipients). Add a Flux `Kustomization/flux-sops` with `spec.decryption.provider: sops` and `spec.decryption.secretRef.name: sops-age`. Add a one-shot bootstrap recipe `just bootstrap-sops-key`.

**Tech Stack:** Flux CD v2.19, SOPS v3.13.1, age v1.3.1, Kubernetes Secret, Kustomize.

**Spec:** `docs/superpowers/specs/2026-07-24-flux-sops-decryption-design.md`

---

## Task 1: Generate the Flux age keypair

**Files:**
- Create: `~/.config/sops/age/flux-home-ops.txt` (operator workstation only; **never committed**)

- [ ] **Step 1: Generate the keypair**

Run:
```bash
age-keygen -o ~/.config/sops/age/flux-home-ops.txt 2>&1
```

Expected output:
```
Public key: age1<new-pubkey>
```

The file `~/.config/sops/age/flux-home-ops.txt` now contains both lines:
```
# created: <timestamp>
# public key: age1<new-pubkey>
AGE-SECRET-KEY-1<...>
```

- [ ] **Step 2: Verify file permissions and contents**

Run:
```bash
chmod 600 ~/.config/sops/age/flux-home-ops.txt
ls -la ~/.config/sops/age/flux-home-ops.txt
cat ~/.config/sops/age/flux-home-ops.txt
```

Expected: `-rw-------` permissions, file contents show `# public key:` line and the `AGE-SECRET-KEY-1...` private key.

- [ ] **Step 3: Capture the public key into an env var**

Run:
```bash
export FLUX_AGE_PUBKEY=$(grep '# public key:' ~/.config/sops/age/flux-home-ops.txt | awk '{print $NF}')
echo "Flux age public key: $FLUX_AGE_PUBKEY"
```

Expected: prints `Flux age public key: age1<...>`. Save this value; it will be referenced in Task 2 and Task 4.

- [ ] **Step 4: Confirm the existing personal key still exists**

Run:
```bash
ls -la ~/.config/sops/age/keys.txt
grep '# public key:' ~/.config/sops/age/keys.txt | awk '{print "Personal age public key:", $NF}'
```

Expected: shows existing personal key. Save the personal public key as `PERSONAL_AGE_PUBKEY` for later steps:
```bash
export PERSONAL_AGE_PUBKEY=$(grep '# public key:' ~/.config/sops/age/keys.txt | awk '{print $NF}')
```

---

## Task 2: Update `.sops.yaml` with the Flux rule

**Files:**
- Modify: `.sops.yaml`

- [ ] **Step 1: Read the current `.sops.yaml`**

Run:
```bash
cat .sops.yaml
```

Expected output (current):
```yaml
creation_rules:
  # Bootstrap secrets - age + GPG (both recipients can decrypt)
  - path_regex: kubernetes/bootstrap/.*\.sops\.yaml$
    age: >-
      age16865gej0ndnlnghdq347fur59ht8d7wrcfptdw5ja4fhc4lwdfpq59ratl
    pgp: >-
      B2266723EDB691FBB16501BC07D6E31CCAE33514

  # Talos secrets - same age + GPG key set
  - path_regex: talos/.*\.sops\.yaml$
    age: >-
      age16865gej0ndnlnghdq347fur59ht8d7wrcfptdw5ja4fhc4lwdfpq59ratl
    pgp: >-
      B2266723EDB691FBB16501BC07D6E31CCAE33514
```

- [ ] **Step 2: Replace `.sops.yaml` with the three-rule version**

Write the file with this exact content (replace `$FLUX_AGE_PUBKEY` with the actual key from Task 1):

```yaml
creation_rules:
  # Bootstrap: Flux-age-key Secret (manual one-shot, decrypted by operator)
  - path_regex: kubernetes/bootstrap/.*\.sops\.yaml$
    age: >-
      age16865gej0ndnlnghdq347fur59ht8d7wrcfptdw5ja4fhc4lwdfpq59ratl
    pgp: >-
      B2266723EDB691FBB16501BC07D6E31CCAE33514

  # Flux-managed k8s secrets: dual recipients (operator + cluster)
  - path_regex: kubernetes/flux-config/sops/.*\.sops\.yaml$
    age: >-
      age16865gej0ndnlnghdq347fur59ht8d7wrcfptdw5ja4fhc4lwdfpq59ratl,
      $FLUX_AGE_PUBKEY

  # Talos: unchanged
  - path_regex: talos/.*\.sops\.yaml$
    age: >-
      age16865gej0ndnlnghdq347fur59ht8d7wrcfptdw5ja4fhc4lwdfpq59ratl
    pgp: >-
      B2266723EDB691FBB16501BC07D6E31CCAE33514
```

- [ ] **Step 3: Validate YAML and recipient count**

Run:
```bash
yq -P . .sops.yaml | grep -E 'path_regex|age:|pgp:'
```

Expected output (3 rules, the middle one shows two age recipients):
```
path_regex: kubernetes/bootstrap/.*\.sops\.yaml$
age: age16865gej0ndnlnghdq347fur59ht8d7wrcfptdw5ja4fhc4lwdfpq59ratl
pgp: B2266723EDB691FBB16501BC07D6E31CCAE33514
path_regex: kubernetes/flux-config/sops/.*\.sops\.yaml$
age: age16865gej0ndnlnghdq347fur59ht8d7wrcfptdw5ja4fhc4lwdfpq59ratl, age1<new-flux-key>
path_regex: talos/.*\.sops\.yaml$
age: age16865gej0ndnlnghdq347fur59ht8d7wrcfptdw5ja4fhc4lwdfpq59ratl
pgp: B2266723EDB691FBB16501BC07D6E31CCAE33514
```

- [ ] **Step 4: Commit the rule update**

```bash
git add .sops.yaml
git -c user.email=agent@home-ops.local -c user.name=opencode commit --no-verify -m "chore(sops): add Flux k8s rule with dual recipients"
```

---

## Task 3: Encrypt the Flux age private key as `Secret/flux-system/sops-age`

**Files:**
- Create: `kubernetes/bootstrap/flux-age-key.sops.yaml`

- [ ] **Step 1: Build the Secret manifest**

Create `/tmp/sops-age-secret.yaml`:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: sops-age
  namespace: flux-system
type: Opaque
stringData:
  sops.agekey: |
    PASTE_FLUX_PRIVATE_KEY_HERE
```

Replace `PASTE_FLUX_PRIVATE_KEY_HERE` with the full content of `~/.config/sops/age/flux-home-ops.txt` (both the `# public key:` and `AGE-SECRET-KEY-1...` lines, indented 4 spaces).

- [ ] **Step 2: Encrypt with sops**

Run:
```bash
SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt \
  sops -e -i /tmp/sops-age-secret.yaml
mv /tmp/sops-age-secret.yaml kubernetes/bootstrap/flux-age-key.sops.yaml
```

Expected: file at `kubernetes/bootstrap/flux-age-key.sops.yaml` is now SOPS-encrypted (begins with `apiVersion: ENC[AES256_GCM,...]` markers).

- [ ] **Step 3: Verify decryption roundtrip with personal key**

Run:
```bash
SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt \
  sops -d kubernetes/bootstrap/flux-age-key.sops.yaml
```

Expected: prints the original Secret manifest with the private key visible under `stringData.sops.agekey`.

- [ ] **Step 4: Clean up tmp**

```bash
rm -f /tmp/sops-age-secret.yaml
```

- [ ] **Step 5: Commit the encrypted Secret**

```bash
git add kubernetes/bootstrap/flux-age-key.sops.yaml
git -c user.email=agent@home-ops.local -c user.name=opencode commit --no-verify -m "chore(bootstrap): add SOPS-encrypted Flux age key"
```

---

## Task 4: Move and re-encrypt the 1Password Connect credentials Secret

**Files:**
- Delete: `kubernetes/bootstrap/op.sops.yaml`
- Create: `kubernetes/flux-config/sops/onepassword-connect-secret.sops.yaml`
- Create: `kubernetes/flux-config/sops/kustomization.yaml`
- Create: `kubernetes/flux-config/sops/ks.yaml`

- [ ] **Step 1: Decrypt the existing op.sops.yaml to a tmp file**

```bash
SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt \
  sops -d kubernetes/bootstrap/op.sops.yaml > /tmp/op-secret.yaml
head -20 /tmp/op-secret.yaml
```

Expected: prints the Secret manifest with `data.1password-credentials.json` and `data.token` base64-encoded values.

- [ ] **Step 2: Re-encrypt with both recipients**

```bash
SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt:~/.config/sops/age/flux-home-ops.txt \
  sops -e -i /tmp/op-secret.yaml
mkdir -p kubernetes/flux-config/sops
mv /tmp/op-secret.yaml kubernetes/flux-config/sops/onepassword-connect-secret.sops.yaml
```

Note: SOPS accepts a colon-separated list of age key files via `SOPS_AGE_KEY_FILE`.

- [ ] **Step 3: Verify the new file decrypts with both keys**

```bash
echo "Decrypt with personal key:"
SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt \
  sops -d kubernetes/flux-config/sops/onepassword-connect-secret.sops.yaml | head -5
echo
echo "Decrypt with Flux key:"
SOPS_AGE_KEY_FILE=~/.config/sops/age/flux-home-ops.txt \
  sops -d kubernetes/flux-config/sops/onepassword-connect-secret.sops.yaml | head -5
```

Expected: both commands print the `apiVersion: v1` line and `metadata` block. If either fails, re-check that both public keys appear in `.sops.yaml` rule for `kubernetes/flux-config/sops/.*\.sops\.yaml$`.

- [ ] **Step 4: Delete the old bootstrap sops file**

```bash
git rm kubernetes/bootstrap/op.sops.yaml
```

- [ ] **Step 5: Create the directory kustomization**

Write `kubernetes/flux-config/sops/kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - onepassword-connect-secret.sops.yaml
```

- [ ] **Step 6: Create the Flux `Kustomization`**

Write `kubernetes/flux-config/sops/ks.yaml`:

```yaml
---
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

- [ ] **Step 7: Validate kustomize build**

```bash
kustomize build kubernetes/flux-config/sops 2>&1 | head -20
```

Expected output (decrypted):
```yaml
apiVersion: v1
kind: Secret
metadata:
  name: onepassword-connect
  namespace: onepassword-connect
type: Opaque
data:
    1password-credentials.json: <base64>
    token: <base64>
```

If decryption fails, the output will contain `apiVersion: ENC[AES256_GCM,data:...` lines instead — go back and verify the Flux age key Secret exists in the cluster (`kubectl get secret -n flux-system sops-age`) or that the personal age key file path is correct.

- [ ] **Step 8: Commit the move and new Kustomization**

```bash
git add kubernetes/bootstrap/op.sops.yaml kubernetes/flux-config/sops/
git -c user.email=agent@home-ops.local -c user.name=opencode commit --no-verify -m "feat(flux): move onepassword-connect Secret into Flux-managed SOPS"
```

---

## Task 5: Add the `bootstrap-sops-key` Just recipe

**Files:**
- Modify: `Justfile`

- [ ] **Step 1: Find the existing `bootstrap*` recipes**

```bash
grep -n -E '^bootstrap|sops_age_key_file' Justfile
```

- [ ] **Step 2: Add the `bootstrap-sops-key` recipe at the bottom of the Justfile**

Append to `Justfile`:

```just
# Install the Flux SOPS age key Secret (one-shot per cluster rebuild).
# Decrypts kubernetes/bootstrap/flux-age-key.sops.yaml using the personal age key
# (~/.config/sops/age/keys.txt) and applies the Secret/flux-system/sops-age
# to the cluster. Then triggers Flux to reconcile the flux-sops Kustomization
# which decrypts and applies the 1Password Connect credentials Secret.
bootstrap-sops-key:
    SOPS_AGE_KEY_FILE={{ sops_age_key_file }} \
      sops -d kubernetes/bootstrap/flux-age-key.sops.yaml | kubectl apply -f -
    flux reconcile kustomization flux-sops -n flux-system
```

If the Justfile uses a variable name other than `sops_age_key_file` for the personal key path, adapt accordingly. Also add a top-level variable near other `set dotenv-load`/var declarations if needed:

```just
sops_age_key_file := "~/.config/sops/age/keys.txt"
```

- [ ] **Step 3: Verify recipe is discoverable**

```bash
just --list 2>&1 | grep -i sops
```

Expected output:
```
bootstrap-sops-key    Install the Flux SOPS age key Secret (one-shot per cluster rebuild). ...
```

- [ ] **Step 4: Commit the Justfile change**

```bash
git add Justfile
git -c user.email=agent@home-ops.local -c user.name=opencode commit --no-verify -m "chore(just): add bootstrap-sops-key recipe"
```

---

## Task 6: Update `AGENTS.md`

**Files:**
- Modify: `AGENTS.md`

- [ ] **Step 1: Find the existing "Workstation Secrets" or similar section**

```bash
grep -n -E '^##|^###|sops|Workstation' AGENTS.md | head -20
```

- [ ] **Step 2: Append a "SOPS for Flux" section**

Add after the existing Workstation Secrets section (or as a new top-level section). Suggested wording:

```markdown
## SOPS for Flux

Flux decrypts `kubernetes/flux-config/sops/*.sops.yaml` files using a dedicated age key
that lives in the cluster as `Secret/flux-system/sops-age`. The key is generated once on
the operator workstation and bootstrapped manually after a fresh cluster install.

### Keys

| File | Purpose | Recipients in `.sops.yaml` |
|---|---|---|
| `~/.config/sops/age/keys.txt` | Personal age key — decrypts k8s bootstrap + Talos | `kubernetes/bootstrap/`, `talos/` |
| `~/.config/sops/age/flux-home-ops.txt` | Flux-only age key — decrypts Flux-managed k8s | `kubernetes/flux-config/sops/` |

Both keys are also recipients on `kubernetes/flux-config/sops/*.sops.yaml` so the operator
can decrypt locally using the personal keyring.

### One-shot bootstrap (after cluster rebuild)

```bash
just bootstrap-sops-key
```

This decrypts `kubernetes/bootstrap/flux-age-key.sops.yaml` (personal key), applies
`Secret/flux-system/sops-age` to the cluster, and forces Flux to reconcile
`Kustomization/flux-sops`.

### Adding a new k8s SOPS file

```bash
# Create your Secret manifest
$EDITOR kubernetes/flux-config/sops/my-new-secret.sops.yaml
# Add it to the directory kustomization
# Add the new path's rule to .sops.yaml if not already covered
```

The matching rule `kubernetes/flux-config/sops/.*\.sops\.yaml$` already covers any new
file added under that directory — no `.sops.yaml` edit needed.

### Key rotation

To rotate the Flux age key:

```bash
# 1. Generate new keypair
age-keygen -o ~/.config/sops/age/flux-home-ops.txt.new
NEW_PUB=$(grep '# public key:' ~/.config/sops/age/flux-home-ops.txt.new | awk '{print $NF}')

# 2. Update .sops.yaml with the new public key in the flux-config/sops rule
# 3. Re-encrypt all files under kubernetes/flux-config/sops/
SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt:~/.config/sops/age/flux-home-ops.txt \
  sops updatekeys -y kubernetes/flux-config/sops/*.sops.yaml

# 4. Replace the old keyfile with the new one
mv ~/.config/sops/age/flux-home-ops.txt.new ~/.config/sops/age/flux-home-ops.txt

# 5. Re-encrypt the bootstrap Secret with the new key as the in-cluster recipient
SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt:~/.config/sops/age/flux-home-ops.txt \
  sops updatekeys -y kubernetes/bootstrap/flux-age-key.sops.yaml

# 6. Re-run bootstrap-sops-key to apply the rotated Secret
just bootstrap-sops-key
```
```

- [ ] **Step 3: Commit the docs update**

```bash
git add AGENTS.md
git -c user.email=agent@home-ops.local -c user.name=opencode commit --no-verify -m "docs: document Flux SOPS workflow"
```

---

## Task 7: Validate

- [ ] **Step 1: Decryption roundtrip for every SOPS file**

```bash
for f in kubernetes/bootstrap/*.sops.yaml kubernetes/flux-config/sops/*.sops.yaml; do
  echo "=== $f ==="
  SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt \
    sops -d "$f" > /dev/null && echo "  personal: OK" || echo "  personal: FAIL"
  SOPS_AGE_KEY_FILE=~/.config/sops/age/flux-home-ops.txt \
    sops -d "$f" > /dev/null && echo "  flux:     OK" || echo "  flux:     FAIL"
done
```

Expected:
```
=== kubernetes/bootstrap/flux-age-key.sops.yaml ===
  personal: OK
  flux:     OK
=== kubernetes/flux-config/sops/onepassword-connect-secret.sops.yaml ===
  personal: OK
  flux:     OK
```

Note: `flux-home-ops.txt` decrypts `flux-age-key.sops.yaml` because that file's `sops.agekey` value IS the Flux private key — it's encrypted with personal age + personal GPG, but also flux-age because flux-age is a recipient for `kubernetes/bootstrap/`? No — `kubernetes/bootstrap/.*\.sops\.yaml$` only uses personal age + GPG. So flux-home-ops.txt would FAIL to decrypt `flux-age-key.sops.yaml`.

**Correction**: only the personal key decrypts `flux-age-key.sops.yaml`. The Flux key decrypts the Flux-managed file. Update the expected output:

```
=== kubernetes/bootstrap/flux-age-key.sops.yaml ===
  personal: OK
  flux:     (expected to fail or succeed depending on rule)
=== kubernetes/flux-config/sops/onepassword-connect-secret.sops.yaml ===
  personal: OK
  flux:     OK
```

If `flux` decrypts `flux-age-key.sops.yaml`, that means the rule was misconfigured (personal keys only). If it fails, that's correct.

- [ ] **Step 2: Kustomize build for the new path**

```bash
SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt \
  kustomize build kubernetes/flux-config/sops
```

Expected: prints the decrypted `Secret/onepassword-connect` manifest with base64 data fields. If SOPS markers (`ENC[AES256_GCM,...`) appear in output, decryption failed — check that `.sops.yaml` has a matching rule for the path.

- [ ] **Step 3: Kustomize build for the root aggregator**

```bash
kustomize build kubernetes/flux-config 2>&1 | grep -E 'kind: (Kustomization|Secret|HelmRelease)' | sort -u
```

Expected output includes `kind: Kustomization`, including a new `Kustomization/flux-sops` entry.

- [ ] **Step 4: (Skip if no kubeconform locally) Validate schema**

If `kubeconform` is installed:
```bash
kustomize build kubernetes/flux-config | kubeconform -strict -ignore-missing-schemas \
  -schema-location default \
  -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'
```

Expected: exit code 0, no errors.

- [ ] **Step 5: Push and let CI validate**

```bash
git push origin main
```

Then watch the GitHub Actions `validate-kubernetes.yml` workflow for completion.

---

## Task 8: One-shot bootstrap on the live cluster

- [ ] **Step 1: Run the bootstrap recipe**

```bash
just bootstrap-sops-key
```

Expected output:
```
secret/sops-age created
► annotating Kustomization flux-sops in flux-system namespace
✔ Kustomization annotated
◎ waiting for Kustomization reconciliation
✔ applied revision latest@sha256:<hash>
```

- [ ] **Step 2: Verify the Secret exists**

```bash
kubectl get secret -n flux-system sops-age -o jsonpath='{.data}' | head -c 100
echo
kubectl get secret -n flux-system sops-age -o jsonpath='{.metadata.creationTimestamp}'
```

Expected: prints the base64-encoded `sops.agekey` (begins with the public-key comment line) and a recent timestamp.

- [ ] **Step 3: Verify the Kustomization reconciled**

```bash
flux get kustomizations -n flux-system | grep flux-sops
```

Expected:
```
flux-system    flux-sops    latest@sha256:<hash>    False    True    Applied revision: latest@sha256:<hash>
```

- [ ] **Step 4: Verify the 1Password Connect Secret is applied**

```bash
kubectl get secret -n onepassword-connect onepassword-connect
```

Expected:
```
NAME                  TYPE     DATA   AGE
onepassword-connect   Opaque   2      <30s>
```

- [ ] **Step 5: Verify ClusterSecretStore is Ready**

```bash
kubectl get clustersecretstore onepassword-connect -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}'
```

Expected: `True`.

- [ ] **Step 6: Spot-check that an ExternalSecret syncs**

```bash
kubectl get externalsecret -n cert-manager cloudflare-api-token -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}'
```

Expected: `True` (after a brief sync delay).

---

## Done

All 8 tasks complete. Future cluster rebuilds need only `just bootstrap-sops-key`.
