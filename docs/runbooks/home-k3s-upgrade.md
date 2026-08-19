# Runbook: home-k3s K3s upgrade and rollback

Applies to the K3s binary on `cachyos` (`scripts/bootstrap-home-k3s.sh`).
Covers changing the K3s server version itself — not Cilium, Flux,
Kyverno, cert-manager, Authentik, or PostgreSQL, which are versioned and
upgraded independently and are explicitly out of scope for this
procedure.

## Datastore model

Single-node K3s with no `datastore-endpoint` or `cluster-init` in
`/etc/rancher/k3s/config.yaml` — embedded **SQLite**, not etcd, at
`/var/lib/rancher/k3s/server/db/`. This matters for rollback: SQLite
rollback is a stop-service / restore-file-copy / reinstall-binary
procedure (`docs.k3s.io/upgrades/roll-back`), not the etcd snapshot
mechanism multi-node clusters use.

## Before touching K3s

1. Check the actual available versions, don't assume. K3s's own
   channel-server API is authoritative:
   ```
   curl -s https://update.k3s.io/v1-release/channels | python3 -m json.tool
   ```
   Compare `stable`/`latest`/the current minor channel's `latest` against
   the live version (`k3s -v` on the host, or `kubectl get nodes -o wide`).
   **If the live version already matches the channel head, there is no
   upgrade to perform** — don't manufacture one by jumping to a version
   that doesn't exist yet or skipping to an untested minor "because it's
   there."
2. Check Cilium's Kubernetes compatibility table
   (`docs.cilium.io/en/stable/network/kubernetes/compatibility/`) against
   the candidate Kubernetes version. Cilium owns kube-proxy replacement
   here (`disable-kube-proxy: true`) — if the candidate version falls
   outside Cilium's tested range, do not proceed without a separately
   justified Cilium upgrade first.
3. Same-minor patch changes (e.g. `v1.36.2+k3s1` ↔ `v1.36.3+k3s1`) carry
   materially lower risk than a cross-minor change: the Kubernetes API
   group versions and datastore object schema are identical within one
   minor. K3s's own rollback-safety warnings ("you must have a datastore
   snapshot taken on the version you're rolling back to") are about
   cross-**minor** schema changes, not patch-level ones. Prefer a patch
   change as the first lifecycle experiment; treat a minor change as a
   separately-scoped, higher-risk exercise.
4. Fresh, verified backups for both database families
   (`scripts/run-stateful-lab-backup.sh`, `scripts/run-authentik-backup.sh`),
   confirmed via `scripts/backup-status.sh`. These protect application
   data; they are independent of the K3s datastore backup below.
5. Record a pre-change snapshot: node/K8s version, PVC/PV UIDs for both
   database StatefulSets, `aegis-recovery-test` UUID/active/non-admin
   state, Grafana OAuth application presence, TLS cert serials
   (api/grafana/auth), aegis-api image digest, Flux revision and all
   Kustomizations' Ready state, one NetworkPolicy attacker-denied check.
   A real interactive OIDC login as `aegis-recovery-test`, confirmed
   server-side via Authentik's own `authentik_events_event` log
   (`action = 'authorize_application'`) rather than relying solely on
   Grafana's `/api/org/users` `lastSeenAt` field — that field has been
   observed not to update on every re-authorization when the browser
   still holds a valid session cookie, so it under-reports fresh logins.

## K3s SQLite datastore backup

Distinct from the PostgreSQL application backups above — this protects
the Kubernetes control-plane state specifically, in case a version
change corrupts it. Requires `sudo` on `cachyos` (no passwordless sudo
configured on this host — every step below needs to be run interactively
by whoever holds that password):

```
sudo systemctl stop k3s
sudo cp -a /var/lib/rancher/k3s/server/db /var/lib/rancher/k3s/server/db.backup-<version>-<timestamp>
sudo cp -a /var/lib/rancher/k3s/server/token /var/lib/rancher/k3s/server/token.backup-<version>-<timestamp>
sudo systemctl start k3s
```

`systemctl stop/start`, not `k3s-killall.sh` — the killall script tears
down all containers and network state, which is unnecessary and
disruptive for a snapshot-only operation; a plain service stop leaves
already-running Pods serving traffic under containerd, only the API
server becomes briefly unreachable. Confirm the node returns to `Ready`
before proceeding.

This backup currently stays **local to `cachyos`**, root-owned,
timestamped. It is not copied off-host — that's the separately-deferred
recovery-root-redundancy milestone's scope, not this one's.

## Performing the version change

Same mechanism `scripts/bootstrap-home-k3s.sh` already uses — the
official installer with an explicit pinned version, never a floating
channel:

```
curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION=vX.Y.Z+k3sN sh -
```

Requires `sudo`; run interactively on `cachyos`. This works identically
whether the version number is going up or down — K3s's installer just
replaces the binary and restarts the service; there is no separate
"upgrade" vs. "downgrade" code path for a same-minor patch change.

## Post-change validation (run after every version change, both directions)

- Node `Ready`, reported version matches the target.
- All Pods settle to `Running` (expect a brief window of `Unknown`
  status across every Pod right after a K3s restart or host reboot —
  this is kubelet/containerd catching up, not a real failure; wait for
  it to clear before drawing conclusions).
- Cilium agent/operator healthy, CoreDNS actually resolves
  (`kubernetes.default.svc.cluster.local` from a throwaway Pod), kube-proxy
  replacement intact.
- All Flux Kustomizations `Ready` (proves SOPS decrypt and HelmReleases
  still reconcile against the new API server version).
- `kyverno test security/policies/tests/` plus a **live, correctly
  labeled** admission proof — the `verify-aegis-api-image` policy is
  scoped to Pods with `app: aegis-api` in the `aegis-api` namespace; a
  test Pod without that label is silently out of policy scope and proves
  nothing. Apply a real manifest with the correct label: the actual
  signed digest should be allowed, a fabricated/wrong digest under the
  same image path should be denied with a Sigstore verification error.
- cert-manager Pods healthy, `Certificate` objects `Ready`, and **serials
  unchanged** — a K3s version change should never trigger reissuance.
- nginx ingress: HTTPS 200/302 on all three hostnames, unknown-host 404.
- Prometheus/Grafana healthy (`/api/health` → `database: ok`).
- **PVC/PV UIDs for both database families unchanged** — a K3s binary
  swap must never recreate persistent volumes. If a UID changes,
  something is badly wrong and this is not a benign version change.
- `aegis-recovery-test` UUID/active/non-admin unchanged, OAuth
  application still present.
- NetworkPolicy: attacker→Authentik PostgreSQL still denied.
- A real interactive OIDC login, confirmed via Authentik's event log —
  do this **per version-change leg**, not just once for the whole cycle.

## Rollback

For a same-minor patch change, rollback is simply running the installer
again with the prior version string — there is no meaningful risk
difference between the "upgrade" and "rollback" direction, since both
are patches of the same Kubernetes minor. The SQLite datastore backup
taken before the first change is available as a safety net but is not
expected to be needed in this case; restoring it would only be
appropriate if the live datastore were actually found corrupted, and
that restoration should be done live and documented at the time, never
simulated.

For a **cross-minor** rollback (not exercised by this runbook — a
separately-scoped, higher-risk procedure): stop k3s, replace
`server/db/` and `server/token` with the pre-upgrade backup taken while
running the older minor, reinstall that older version's binary, start
k3s, verify. K3s's own documentation is explicit that a rollback without
a same-minor datastore snapshot is unsupported.

## Proof: the 2026-08-19 patch-cycle upgrade/rollback

K3s's channel-server API confirmed `v1.36.3+k3s1` was already the
`stable`/`latest` version at the time of this test — there was no newer
version to upgrade to. The exercise was reframed as a same-minor patch
cycle: `v1.36.3+k3s1` → `v1.36.2+k3s1` (the "upgrade" leg) → back to
`v1.36.3+k3s1` (the "rollback" leg), ending on the version that was
already correct to run, using two real, previously-published K3s
builds rather than fabricating a nonexistent version.

Both legs completed cleanly: PVC UIDs, TLS cert serials, the
`aegis-recovery-test` UUID, and the `persistence_proof` invariant were
all identical before, during, and after. A real host reboot was
performed while on `v1.36.2+k3s1`, with full automatic recovery and a
fresh server-side-verified OIDC login afterward. No SQLite datastore
restore was needed at any point. See the milestone's own final report
for exact timings and the full checklist result.

## What this does not prove

- **Cross-minor version change** — not attempted. The datastore-schema
  risk K3s's own docs warn about only applies there, and this runbook's
  "clean, no restore needed" result should not be read as evidence that
  a minor version change would be equally uneventful.
- **Multi-node rollback** — this is a single-node cluster; nothing here
  addresses coordinating a version change or rollback across multiple
  control-plane or agent nodes.
- **etcd-based rollback** — this host uses SQLite; the etcd snapshot
  mechanism is a different procedure entirely.
