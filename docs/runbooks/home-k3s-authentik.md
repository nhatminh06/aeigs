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

## Destructive identity recovery

Proven live, once, on 2026-08-19: what happens when the Authentik
PostgreSQL PVC/PV is actually destroyed, not just the Pod restarted.
Same distinction as stateful-lab's own destructive-restore proof
(`docs/runbooks/stateful-lab-postgresql-backup-restore.md`'s "Proof: the
2026-08-18 destructive restore") — Git/Flux reconstructs Kubernetes
objects and, for Authentik specifically, re-runs Django's own schema
migrations against the fresh empty database (unlike stateful-lab, which
has no such self-migrating schema). Neither of those is a database
backup; the DB-only test identity is the proof.

### Restoring

```
scripts/restore-authentik-postgres.sh <path-to-.dump.age> [--replace-existing]
```

Re-checks the artifact's checksum against its metadata, decrypts,
copies the plaintext dump into the pod's own `/tmp` (the
`kubectl exec -i` duplex-streaming workaround, see above), runs
`pg_restore --list` to confirm structure, then restores. **Without**
`--replace-existing`, fails loudly if target objects already exist —
which they normally will, since a freshly Flux-reconstructed `authentik`
database already has Django's migrated (but empty) schema in it.
**With** `--replace-existing`, drops and recreates the whole `authentik`
database first, then restores into the truly empty result — chosen over
`pg_restore --clean --if-exists` per-object because Authentik's
`pgtrigger`-generated functions have dependency ordering that
`--clean --if-exists` can't reliably unwind; a full database
drop/recreate has no such ordering problem. Requires the `authentik`
role to still exist (it does — Flux/Helm creates it, restore never
touches roles). Quiesce `authentik-server` and `authentik-worker` first
(`kubectl -n authentik scale deploy authentik-server authentik-worker
--replicas=0`) — `DROP DATABASE` fails while either holds an open
connection — then scale them back to `1` once the restore completes;
`authentik-postgresql` itself is never scaled down for a restore, only
for the destructive-test procedure below.

### Proof: the 2026-08-19 destructive restore

**Pre-destruction state**: user `aegis-recovery-test`, `is_active: t`,
`uuid: 3e2b70c1-23b4-46e7-af5b-60b7b7ef2cc4`, 0 group memberships
(non-admin), OAuth application `grafana-home-k3s` present. Real
interactive Grafana OIDC login confirmed server-side (`role: Viewer`,
`authLabels: ["Generic OAuth"]`, fresh `lastSeenAt`). PVC
`data-authentik-postgresql-0` (UID `1d6707d6-d527-4ffc-a190-ad6ffa18ea04`)
on PV `pvc-1d6707d6-...` (UID `1a28ae09-c20e-4ca4-b582-7a9eb0cac963`),
`local-path` StorageClass, reclaim policy `Delete`.

1. **Safety gate**: fresh `scripts/verify-authentik-backup-restore.sh`
   run (checksum, decrypt, `pg_restore --list`, full scratch restore,
   application-level fingerprint match) — passed. Live DB/server/worker
   confirmed healthy, NetworkPolicy re-checked (attacker denied), one
   more real pre-destruction OIDC login confirmed server-side.
2. **Suspended only** `Kustomization/authentik` (not `flux-system`,
   Cilium, Kyverno, `observability`, `ingress`, `aegis-api`, or
   `stateful-lab`) — the single Kustomization that owns the PostgreSQL
   StatefulSet, the HelmRelease, the blueprint Secret, and all three
   NetworkPolicies.
3. Scaled `StatefulSet/authentik-postgresql` to 0, confirmed the Pod
   terminated and the PVC showed `Used By: <none>`.
4. **Deleted `PersistentVolumeClaim/data-authentik-postgresql-0`.**
   Confirmed the PV was gone (`kubectl get pv` → `NotFound`, 4s) and,
   separately, that the host-path backing directory no longer appeared
   in a listing of its parent directory on `cachyos` — not just trusting
   `kubectl delete`'s exit code.
5. **Resumed** `Kustomization/authentik`. Flux recreated the
   StatefulSet/PVC/Service; the fresh Postgres Pod came up on a
   genuinely new PVC/PV UID (`1a9dbe9c-...` / `a408849c-...`); the
   server/worker Deployments ran their own Django migrations against
   the new, empty database (first-boot migration path, ~2 minutes) —
   this is Authentik's own schema self-repair, not identity recovery.
6. **Mandatory proof, checked before touching the backup**: queried the
   fresh database for `aegis-recovery-test` — **zero rows**, though
   `\dt` showed the fully migrated schema. `authentik_core_application`
   was empty too (`grafana-home-k3s` absent — the OAuth blueprint is
   Git-owned and reapplies on its own schedule, but the identity itself
   never does). A real login attempt as `aegis-recovery-test` against
   the reachable login page failed, as expected. Flux and Django rebuilt
   the infrastructure and the schema. Neither rebuilt the identity.
7. **Restored** using the *same, pre-existing* backup
   (`authentik-postgresql-20260819T075657Z.dump.age` — no new backup was
   generated from the destroyed environment for this test) via
   `scripts/restore-authentik-postgres.sh ... --replace-existing`, after
   scaling server/worker to 0 and re-verifying the checksum one more
   time immediately beforehand. `pg_restore` completed with no errors.
8. **Exact identity recovery, verified**: same username, `is_active: t`,
   same UUID `3e2b70c1-23b4-46e7-af5b-60b7b7ef2cc4`, still 0 group
   memberships, `grafana-home-k3s` OAuth application present again.
   Server/worker scaled back to 1, reached `Ready` with no crash loop.
9. **Real interactive OIDC login, post-restore**: confirmed server-side
   via Grafana's API (`role: Viewer`, `authLabels: ["Generic OAuth"]`,
   fresh `lastSeenAt`). NetworkPolicy re-checked (attacker still
   denied). HTTPS healthy, cert serial unchanged from before destruction
   (cert-manager was never touched).
10. **Pod-recreation check**: deleted the new (post-restore) Postgres
    Pod once more; the StatefulSet recreated it on the *same* PVC UID;
    the identity was still present — proving it lives on the PVC, not
    in process memory.
11. **Real CachyOS reboot**, user-executed (`sudo reboot` — no
    passwordless sudo on this host). Full automatic recovery observed:
    node `Ready`, all 9 Kustomizations `Ready=True`, Authentik Pods
    settled to `1/1 Running` with no manual `kubectl apply`, no manual
    Pod deletion, no certificate recreation — same self-clearing
    transient churn already documented for this host (a brief
    `SandboxChanged` container recreation during containerd restart).
    Identity present with the same UUID, same PVC UID, HTTPS healthy,
    cert serial unchanged, NetworkPolicy re-verified.
12. **Second real interactive OIDC login, post-reboot**: Authentik's own
    event log (`authentik_events_event`, `action = 'authorize_application'`)
    showed a fresh authorization timestamped after the reboot completed,
    zero `login_failed` events. **Caveat, disclosed rather than
    papered over**: Grafana's own `/api/org/users` `lastSeenAt` field
    did not advance on this second login, even though a genuine new
    OAuth round trip happened at Authentik's end — Grafana appears not
    to refresh `lastSeenAt` on every re-authorization when its own
    session cookie is still valid client-side. Authentik's event log is
    the authoritative signal for "did a fresh login happen," not
    Grafana's `lastSeenAt`, which can lag or not move at all.
13. **Regression sweep**: aegis-api (`200`), Prometheus/Grafana Pods
    running, Grafana `/api/health` → `database: ok`, `stateful-lab`
    Pod/PVC untouched, all 9 Kustomizations `Ready=True`.
14. **New backup created after success**
    (`20260819T084803Z`) as a fresh point-in-time artifact — the
    original `20260819T075657Z` proof artifact used throughout this test
    was never deleted or overwritten.

### Timings (lab measurements, not RTO/RPO commitments)

- PVC delete → confirmed gone (object + host-path listing): ~4s
- Flux resume → fresh Postgres Pod `Ready`: ~20s
- Django migrations on the fresh empty database (first boot only):
  ~2 minutes
- Restore (`pg_restore` into the freshly recreated database): a few
  seconds
- Server/worker back to `Ready` after restore: ~1 minute

### Failure model, after this milestone

| Failure | Status |
|---|---|
| Pod loss | Protected — PVC persists (prior milestone) |
| Host reboot | Protected — local disk persists (prior milestone) |
| PVC / PV / backing-directory loss | **Recoverable from backup** — proven live above |
| Grafana OAuth blueprint drift | Recovers from Git via Flux — separate from identity, see "If the Grafana OAuth blueprint doesn't apply automatically" above |

### What this does not claim

Same posture as stateful-lab's own restore doc: scheduled logical
snapshots only, no PITR/WAL archiving, single backup destination (this
Mac) with no independent backup of its own, the backup age key has no
second physically separate copy (same unresolved, disclosed limitation
as stateful-lab's — see that runbook's "Key redundancy"), restore
remains a manual operator-driven procedure (not scheduled), and this
proves recovery on the *same* host — an empty-replacement-host
reconstruction for Authentik specifically (mirroring stateful-lab's
"Second proof") has not been attempted.

## What NOT to do

- Don't add the test user (or any real user) to
  `security/authentik/home-k3s/blueprint.enc.yaml` — it must stay
  DB-only to mean anything as a recovery proof.
- Don't reuse dev-kind's OAuth client_id/client_secret or the CA/SOPS
  key handling patterns without checking they still apply — home-k3s
  has its own client credentials by design.
- Don't add Authentik to the launchd backup schedule without a
  deliberate decision recorded — it isn't scheduled today. Inspected
  2026-08-19: `scripts/manage-backup-scheduler.sh`'s `LABELS` array and
  `run-now backup|verify` sub-command are stateful-lab-specific by name;
  adding Authentik isn't a drop-in two-plist addition, it needs the
  script's target-selection restructured first (e.g. a `--target`
  flag). Deferred for that reason, not decided against.
