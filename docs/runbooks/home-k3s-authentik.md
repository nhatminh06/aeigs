# Runbook: home-k3s Authentik

Applies to persistent Authentik on `home-k3s`
(`security/authentik/home-k3s/`). See
`docs/decisions/0016-home-k3s-authentik-identity.md` for why it's built
the way it is — standalone PostgreSQL, portable NetworkPolicy instead
of dev-kind's Cilium exception, a DB-only test identity.

## Health checks, in order

1. **PostgreSQL**: `kubectl -n authentik get pod authentik-postgresql-0`
   — `1/1 Running`; `kubectl -n authentik get pvc
   data-authentik-postgresql-0` — `Bound`.
2. **Server/worker**: `kubectl -n authentik get pods` — both `1/1
   Running`. A first-ever install takes ~6 minutes for Django
   migrations against a fresh database (the HelmRelease's `timeout:
   10m0s` accounts for this) — an ordinary restart is fast, migrations
   already applied.
3. **HTTPS**: `curl -k -H "Host: auth.aegis.home.arpa"
   https://<node-IP>:30443/-/health/live/` → `200`. Add `--cacert
   ~/.config/aegis/pki/ca.crt` (drop `-k`) to verify trust.
4. **NetworkPolicy**: `kubectl -n authentik get networkpolicy` — three
   policies (`authentik-postgresql-ingress`, `authentik-server-ingress`,
   `authentik-worker-ingress`).

## Grafana OIDC login

Browser flow: `https://grafana.aegis.home.arpa:30443` → "Sign in with
Authentik" → Authentik's own login page (`auth.aegis.home.arpa`) →
redirected back to Grafana, authenticated. Local admin login stays
available on the same page as a recovery fallback — it is not removed
by adding OIDC.

**If "Sign in with Authentik" spins forever**: almost always a missing
port somewhere. home-k3s's ingress is on NodePort `30443`, not the
browser's implicit `443` — every hostname reference in
`observability/kube-prometheus-stack/home-k3s/helmrelease.yaml`
(`root_url`, `auth_url`) and in
`security/authentik/home-k3s/blueprint.enc.yaml` (`redirect_uris`) must
include `:30443` explicitly, or the browser gets redirected to a port
nothing is listening on.

**If Authentik's own login page shows "the request failed and the
interceptors did not return an alternative response"**: check
`infrastructure/ingress/home-k3s/configmap.yaml`'s `auth.aegis.home.arpa`
server block uses `proxy_set_header Host $http_host;`, not `$host` —
nginx's `$host` strips the port, and Authentik's frontend needs it to
build its own API calls correctly.

## If the Grafana OAuth blueprint doesn't apply automatically

Observed live, not fully root-caused: after mounting a new/changed
`authentik-blueprints` Secret, the worker's `blueprints_discovery` task
sometimes gets enqueued but never actually runs (no "Task started" log
line for it, unlike other periodic tasks). Confirm with:

```
kubectl -n authentik exec deploy/authentik-worker -- \
  curl -s http://localhost:9000/api/v3/core/applications/
# or, without a Service:
kubectl -n authentik exec <worker-pod> -- ak apply_blueprint \
  /blueprints/mounted/secret-authentik-blueprints/grafana-oidc.yaml
```

The second command applies it directly and is safe to re-run — it's
the same idempotent blueprint apply the discovery task would have run.

## The DB-only test identity

`aegis-recovery-test` — a non-admin user created through Authentik's
API, **not** declared anywhere in Git. Its existence after any recovery
event (Pod loss, K3s restart, host reboot) is the proof that identity
state survived from the database, not from Git reconstruction:

```
kubectl -n authentik exec authentik-postgresql-0 -- \
  psql -U authentik -d authentik -t -A \
  -c "SELECT username, is_active FROM authentik_core_user WHERE username = 'aegis-recovery-test';"
```

Expect `aegis-recovery-test|t`. Do not add this user to a blueprint —
that would defeat the entire point of the check.

## Backup

`scripts/backup-authentik-postgres.sh` / `run-authentik-backup.sh` /
`verify-authentik-backup-restore.sh` / `prune-authentik-backups.sh` —
same proven shape as the stateful-lab scripts, own backup root
(`~/.local/share/aegis/backups/authentik/postgresql/`), own status file
(`~/.local/state/aegis/backups/authentik/status.txt`), same dedicated
backup age key. **Not** wired into the launchd scheduler in this
milestone — run manually until a scheduling decision is made
deliberately, not as an afterthought.

The fingerprint recorded in each backup's metadata
(`pre_backup_identity_fingerprint_sha256`) is application-level: the
test user's username+active-state and the Grafana OAuth application's
slug — not a full-table hash, since Authentik's schema has volatile
tables (sessions, events, task logs) that change on every request and
would never let a full hash match after a legitimate restart.

**If `kubectl exec -i` fails with "connection reset by peer" /
"broken pipe"** during a backup or restore-verify run: this is a known,
reproduced issue with `kubectl exec`'s stdin/stdout duplex streaming
over this host's network path once the payload is a few MB (Authentik's
dump, unlike stateful-lab's few-KB one). Both scripts already work
around it (`kubectl cp` the file in, then `exec` against the local
path) — if you see this error, something upstream of that workaround
changed; don't re-add a raw `exec -i ... < file` pipe.

## What NOT to do

- Don't add the test user (or any real user) to
  `security/authentik/home-k3s/blueprint.enc.yaml` — it must stay
  DB-only to mean anything as a recovery proof.
- Don't reuse dev-kind's OAuth client_id/client_secret or the CA/SOPS
  key handling patterns without checking they still apply — home-k3s
  has its own client credentials by design.
- Don't add Authentik to the launchd backup schedule without a
  deliberate decision recorded — it isn't scheduled today.
- Don't run a destructive Authentik PostgreSQL restore against the live
  database — not proven yet, see ADR 0016's "Consequences".
