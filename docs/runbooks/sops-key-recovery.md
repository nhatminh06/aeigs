# SOPS age key recovery

## Incident status

Fresh `dev-kind` reconstruction reached healthy Cilium, but Flux bootstrap
stopped because the age identity expected at
`~/.config/sops/age/keys.txt` was unavailable. The committed recipient is:

```text
age1gfycq3cyvq29hwkluywkhyc6rpt9y257u9ltltea769khtkysawslec0vw
```

The original private key has not been recovered. No replacement identity has
been generated, no encrypted manifest has been changed, and recovery remains
blocked. A random new age identity cannot decrypt ciphertext encrypted to the
recipient above.

## Safe original-key recovery

Search protected workstation backups, external drives, password-manager
attachments, old home directories, and another still-running cluster or
operator machine. Never print an `AGE-SECRET-KEY-...` value. For each candidate,
compare only its public half:

```sh
age-keygen -y /protected/path/to/candidate
```

The output must exactly match the committed recipient above. Restore a match
with owner-only permissions and verify decryption without displaying plaintext:

```sh
install -d -m 700 ~/.config/sops/age
install -m 600 /protected/path/to/candidate ~/.config/sops/age/keys.txt
scripts/verify-sops-key.sh
```

Do not edit encrypted files when the original key works. Before relying on the
restored identity, create a second independent protected copy. Record only that
the copy exists, never its location or private material in Git or PR evidence.

## Encrypted manifest inventory

SOPS encrypts `data` and `stringData`, so names and field names are visible but
values are not. This inventory does not claim that plaintext was recovered.

| File | Secret / purpose and consumer | Category | Recreation authority and rotation impact |
|---|---|---|---|
| `apps/demo-app/secret.enc.yaml` | `demo-app/podinfo-ui`; UI message consumed by the demo deployment | A | A new non-sensitive demonstration value can be selected; only displayed behavior changes. |
| `observability/kube-prometheus-stack/secret.enc.yaml` | dev `observability/grafana-admin`; Grafana administrator login | A | Generate a new credential for disposable dev Grafana. |
| `observability/kube-prometheus-stack/home-k3s/grafana-admin.enc.yaml` | home `observability/grafana-admin`; persistent Grafana administrator login | A, conditional | Rotate through the running Grafana instance or its documented recovery path, then synchronize the Secret. Existing database state means replacing only Git ciphertext is insufficient. |
| `observability/kube-prometheus-stack/grafana-oidc.enc.yaml` | dev `observability/grafana-oidc`; Grafana OAuth client secret | C | Must match the client secret inside the dev Authentik blueprint. Reconstruct both from a reviewed blueprint, not independently. |
| `observability/kube-prometheus-stack/home-k3s/grafana-oidc.enc.yaml` | home `observability/grafana-oidc`; Grafana OAuth client secret | C | Must match the persistent Authentik provider/application and encrypted home blueprint. Requires the live Authentik database or a verified backup plus an intentional client-secret rotation. |
| `security/authentik/blueprint.enc.yaml` | dev `authentik/authentik-blueprints`; full Grafana OIDC blueprint | C | The whole blueprint document is encrypted, not only its secret. Rebuild from an authoritative reviewed blueprint and coordinate its client secret with Grafana. |
| `security/authentik/home-k3s/blueprint.enc.yaml` | home `authentik/authentik-blueprints`; persistent Grafana OIDC blueprint | C | Recover from live Authentik/verified backup or deliberately reconstruct and validate provider, application, redirect URIs, identifiers, and client secret. |
| `security/authentik/config.enc.yaml` | dev `authentik/authentik-config`; Authentik secret key, bundled PostgreSQL password, bootstrap password/token | Mixed A/B | Disposable database and bootstrap credentials can be regenerated. Preserve the Authentik secret key if possible; otherwise treat its change as a separate Authentik reset and validate all dependent behavior. |
| `security/authentik/home-k3s/config.enc.yaml` | home `authentik/authentik-config`; Authentik secret key and bootstrap credentials | Mixed A/B | Bootstrap values can be reissued. Preserve the secret key from a live Secret or protected source if possible; do not assume changing it is harmless to persistent Authentik state. |
| `security/authentik/home-k3s/postgresql-secret.enc.yaml` | `authentik/authentik-postgresql`; persistent Authentik database role password | A, conditional | Rotate against the live/restored PostgreSQL role and update Authentik in the same operation. An existing PVC or restored database will not adopt a new init Secret automatically. |
| `stateful-lab/postgresql/secret.enc.yaml` | `stateful-lab/postgresql`; persistent lab database role password | A, conditional | Rotate against the live/restored PostgreSQL role. Replacing the Kubernetes Secret alone does not change an initialized database. |

Category A means a legitimate authority can issue a replacement; conditional A
items still require that authority to be reachable. Category B values should be
preserved if possible because rotation affects persistent state or trust.
Category C remains a blocker until the dependency and authoritative source are
available.

## If the original identity is permanently lost

Do not generate a new identity until every Category C item has an authoritative
reconstruction source and each persistent credential has a coordinated rotation
procedure. At minimum this requires access to the persistent Authentik and
PostgreSQL state or verified backups and their separate backup identity.

Once those prerequisites are satisfied:

1. Capture and verify the authoritative configuration without committing
   plaintext.
2. Generate a new SOPS identity under `umask 077` and immediately make a second
   independent protected copy.
3. Commit only its public recipient to `.sops.yaml`.
4. Rotate coupled credentials as one change: each OAuth blueprint with its
   Grafana client Secret, and each PostgreSQL role with its consumer.
5. Re-encrypt every required manifest using restrictive temporary files; remove
   plaintext immediately and confirm it was never tracked.
6. Run Gitleaks and inspect `git diff` and `git status` before committing.
7. Rebuild `dev-kind` only through `cluster-up.sh`, `bootstrap-cilium.sh`, and
   `bootstrap-flux.sh`.
8. Require Ready Git sources, Kustomizations, HelmReleases, healthy controllers,
   no persistent SOPS errors, and application-level tests for every rotated
   integration.

Do not rotate the development CA, backup age key, Cosign identity, GitHub
credentials, or TLS material as part of SOPS recovery unless a separate,
evidence-backed dependency requires it.

## Recovery evidence required

Recovery is complete only after `scripts/verify-sops-key.sh` succeeds, a fresh
dev cluster consumes the encrypted Git state through Flux, affected
Kustomizations reconcile, and the applications behind recreated credentials are
tested. A matching public recipient alone is necessary but not sufficient.
