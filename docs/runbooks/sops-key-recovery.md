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

## Reconstruction authority assessment

This assessment records configuration shape and rotation authority, not recovered
plaintext. No live cluster, database backup, backup age key, or restore-status
file was available on the current workstation when it was performed.

### Grafana and Authentik OIDC model

```text
Authentik OAuth2/OIDC provider
  client ID (non-secret, committed in the matching Grafana HelmRelease)
  client secret (must match the environment's grafana-oidc Secret)
  authorization-code + refresh-token grants
  managed scope mappings: scope-openid, scope-profile, scope-email
  exact Grafana /login/generic_oauth redirect URI
        |
        v
Authentik application -> provider
        |
        v
Grafana Secret/observability/grafana-oidc: stringData.client-secret
        |
        v
GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET + committed Generic OAuth settings
```

The environments deliberately use different clients:

| Setting | dev-kind | home-k3s |
|---|---|---|
| Committed client ID | `a4aabfd0c61e2e6eba4fdaeed174c158b2b6e9f6` | `bf212636c078e13940374b77f00a0e0f64f0a397` |
| Grafana root URL | `https://grafana.aegis.test/` | `https://grafana.aegis.home.arpa:30443/` |
| Required callback | `https://grafana.aegis.test/login/generic_oauth` | `https://grafana.aegis.home.arpa:30443/login/generic_oauth` |
| Browser authorization endpoint | `https://auth.aegis.test/application/o/authorize/` | `https://auth.aegis.home.arpa:30443/application/o/authorize/` |
| Token endpoint | `http://authentik-server.authentik.svc.cluster.local/application/o/token/` | same |
| UserInfo endpoint | `http://authentik-server.authentik.svc.cluster.local/application/o/userinfo/` | same |
| Requested scopes | `openid profile email` | `openid profile email` |
| Known application slug | not recorded outside ciphertext | `grafana-home-k3s` |

Grafana uses explicit OAuth endpoints, not a committed discovery/issuer URL.
Its official Generic OAuth contract derives the callback by appending
`/login/generic_oauth` to `root_url`; the client ID and secret must match the
provider. The committed client IDs can be reused, or each can be replaced if
the provider and HelmRelease are deliberately updated together. The client
secret never needs its old plaintext when both sides are rotated atomically.

The repository proves the required object relationship, grants, scope mappings,
URLs, and home application slug. It does **not** preserve the exact provider
identifier/name, dev application slug, authorization-flow reference, blueprint
metadata, or complete entry structure outside the encrypted documents.
Authentik's blueprint schema is sufficient to author a reviewed replacement,
but not to claim byte-for-byte reconstruction of the original. An export from a
live/restored Authentik would recover most object metadata, but Authentik does
not export write-only OAuth client secrets; those must still be rotated as a
new pair.

### Authentik secret key

Both environments run Authentik 2026.x, well after the pre-2023.6 releases
where the secret key also affected unique user IDs. Current Authentik
documentation says `AUTHENTIK_SECRET_KEY` signs cookies and supports other
cryptographic operations; changing it invalidates active sessions. Therefore:

- dev-kind can safely generate a new key because the environment and database
  are disposable;
- home-k3s does not require the lost value to restore database identities, but
  rotating it is a planned maintenance action that logs out every session and
  requires fresh Authentik and Grafana login validation;
- a database restore does not require the old key for user UUID preservation on
  this Authentik version, but retained sessions must not be presented as
  surviving the rotation.

The key should still be preserved when available; it is not routine rotation
material. For this incident, upstream behavior provides a legitimate generation
authority and a known verification path, so it is no longer an unknown value.

### PostgreSQL credential rotation

The persistent database roles and consumers are:

| Database | Role | Consumer | Secret behavior |
|---|---|---|---|
| `authentik` | `authentik` | Authentik server and worker through `AUTHENTIK_POSTGRESQL__PASSWORD` | `POSTGRES_PASSWORD` initializes a fresh database only; an existing PVC keeps the database role's current password. |
| `aegis_state` | `aegis` | The stateful-lab PostgreSQL process and operator recovery scripts; no separate application client | Same initialization-only behavior for an existing PVC. |

The repository's backup and restore scripts already execute `psql` inside each
PostgreSQL pod over its local socket without supplying the old password. With a
live database or a verified restored copy, that administrative path can issue
`ALTER ROLE` without knowing the old network password. Rotation must coordinate:

1. verified local administrative access to the correct database;
2. `ALTER ROLE` for the documented role;
3. the matching re-encrypted Kubernetes Secret;
4. restart/reconciliation of password-consuming workloads, especially
   Authentik server and worker;
5. database connectivity, application health, and backup/restore verification.

Changing only the Kubernetes Secret does not modify a role in an initialized
database. Changing only the role breaks Authentik when it next connects.
Neither rotation can run until its database state is accessible.

### Authority matrix

`READY` means the old plaintext is unnecessary and a legitimate generation or
rotation authority plus verification procedure is known. It does not authorize
Phase 5C to generate the value. `BLOCKED` means an authority or exact
configuration dependency is unavailable.

| Secret/config | Old plaintext required? | Can regenerate? | Authority | Available now? | Procedure known? | Status |
|---|---:|---:|---|---:|---:|---|
| demo UI message | No | Yes | Selected non-sensitive local value | Yes | Yes | READY |
| dev Grafana admin | No | Yes | Cryptographically generated local credential; disposable Grafana | Yes | Yes | READY |
| home Grafana admin | No | Yes | Cryptographically generated local credential; Grafana has no persistent data volume | Yes | Yes | READY |
| dev Authentik bootstrap password/token | No | Yes | Cryptographically generated bootstrap credentials | Yes | Yes | READY |
| home Authentik bootstrap password/token | No | Yes | Cryptographically generated bootstrap credentials | Yes | Yes | READY |
| dev Authentik secret key | No | Yes | Authentik secure generation guidance; disposable state | Yes | Yes | READY |
| home Authentik secret key | No on Authentik 2026.x | Yes, with session invalidation | Authentik secure generation guidance | Yes | Yes | READY |
| dev bundled PostgreSQL password | No | Yes | Fresh disposable database initialization | Yes | Yes | READY |
| dev OIDC provider/application blueprint and Grafana secret | No if deliberately replaced together | Yes in principle | Reviewed replacement blueprint plus Authentik provider | Partial: exact original blueprint unavailable | Partial | BLOCKED |
| home OIDC provider/application blueprint and Grafana secret | No if deliberately replaced together | Yes in principle | Live/restored Authentik or reviewed replacement blueprint | No | Partial | BLOCKED |
| home Authentik PostgreSQL password | No with database-admin access | Yes | Live or verified-restored `authentik` database role | No | Yes | BLOCKED |
| stateful-lab PostgreSQL password | No with database-admin access | Yes | Live or verified-restored `aegis` database role | No | Yes | BLOCKED |

### Current authority availability

- `~/.kube/config` exists but contains no contexts; the expected
  `~/.kube/home-k3s.yaml` is absent.
- No kind/K3s container or local VM exists.
- Tailscale is installed but logged out (`NeedsLogin`), so it exposes no peers.
- No relevant SSH alias is configured.
- No external disk is mounted.
- Neither database backup directory, neither status file, nor the dedicated
  backup age key exists on this workstation.

Repository history and PR metadata contained useful non-secret architecture,
but no authoritative plaintext and no complete unencrypted blueprint. If Git
history ever reveals actual credentials, stop and treat that as a historical
secret leak rather than using it as recovery material.

### Gates before secret rotation

Phase 5D must not begin until all of these are satisfied:

- **dev OIDC blueprint:** approve a reviewed replacement defining the exact
  OAuth2 provider, application identifier/slug, authorization flow, grants,
  managed scope mappings, callback URI, fixed-or-replaced client ID, and paired
  new secret; define blueprint-apply and real Grafana-login tests.
- **home OIDC blueprint:** obtain live Authentik or a verified readable backup
  to export non-secret provider/application metadata, or explicitly approve a
  reviewed replacement design. Preserve `grafana-home-k3s` unless an intentional
  rename is included. Define the paired-secret update and real login test.
- **home Authentik PostgreSQL:** obtain correct-cluster local database-admin
  access or a verified restored copy plus its backup key; confirm role
  `authentik`, then schedule the atomic role/Secret/workload rotation.
- **stateful-lab PostgreSQL:** obtain the same authority for role `aegis`; prove
  the persistence fingerprint and backup/restore path after rotation.
- **offline search:** check protected password-manager attachments, old operator
  workstation storage, external/offline backups, old
  `~/.config/sops/age/keys.txt`, `~/.config/aegis/backup/age/keys.txt`, both
  `~/.local/share/aegis/backups/...` families, Authentik bootstrap records,
  Grafana OAuth records, and database credential records. Report existence and
  public metadata only until a later phase authorizes secret handling.

Until these gates are met, the outcome remains **blocked** and no replacement
SOPS identity or credential should be generated.
