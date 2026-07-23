---
name: home-ops-external-secrets
description: Use when creating ExternalSecret resources to sync secrets from 1Password Connect into Kubernetes namespaces - the only secret backend currently in use
---

# External Secrets (1Password Connect)

All app secrets are synced from 1Password Connect via the External Secrets Operator. The single `ClusterSecretStore` is named `onepassword-connect`.

## ClusterSecretStore (already deployed)

Defined at `kubernetes/external-secrets-system/external-secrets/config/clustersecretstore.yaml`:

```yaml
apiVersion: external-secrets.io/v1
kind: ClusterSecretStore
metadata:
  name: onepassword-connect
spec:
  provider:
    onepassword:
      connectHost: http://onepassword-connect.onepassword-connect.svc.cluster.local:8080
      vaults:
        home-ops: 1
      auth:
        secretRef:
          connectTokenSecretRef:
            name: onepassword-connect
            namespace: onepassword-connect
            key: token
```

**Vault name**: `home-ops`. **Item references** in `remoteRef.key` are 1Password item titles in that vault.

## ExternalSecret template

`kubernetes/{namespace}/{component}/app/externalsecret.yaml`:

```yaml
---
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: {app}-config
  namespace: {namespace}
spec:
  refreshInterval: 1h
  secretStoreRef:
    kind: ClusterSecretStore
    name: onepassword-connect
  target:
    name: {app}-config            # resulting K8s Secret name
  data:
    - secretKey: api_key          # resulting K8s Secret key
      remoteRef:
        key: {1password-item-name}  # 1Password item title in "home-ops" vault
        property: credential       # field on the 1Password item
```

Common `property` values: `username`, `password`, `credential`, `token`.

## HelmRelease wiring

Reference the synced secret in the bjw-s app-template values:

```yaml
    controllers:
      {app}:
        containers:
          {app}:
            env:
              - name: API_KEY
                valueFrom:
                  secretKeyRef:
                    name: {app}-config
                    key: api_key
```

## Verification

```bash
# Secret was created
kubectl get secret -n {namespace} {app}-config

# ExternalSecret status
kubectl get externalsecret -n {namespace} {app}-config
kubectl describe externalsecret -n {namespace} {app}-config

# ESO logs
kubectl logs -n external-secrets-system -l app.kubernetes.io/name=external-secrets
```

## Important conventions

- **Never reference Vault** — that backend is not configured anywhere
- **One ExternalSecret per logical secret group** — don't fan out tiny single-field secrets
- **`refreshInterval: 1h`** is standard; ESO also pushes updates immediately on 1Password change
- For sensitive keys that need rotation, use `refreshInterval: 5m` or add a webhook receiver (Flux notifies on commit)

## See also

- `home-ops-add-new-app` — full app workflow including secret wiring
