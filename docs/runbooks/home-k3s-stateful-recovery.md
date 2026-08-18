# home-k3s stateful persistence experiment

## Objective

home-k3s has proven persistent *cluster* lifecycle — K3s survives service
restarts and reboots, Flux recovers desired state after drift — but until
now, nothing had ever stored actual data on it. This answers a narrower
question: does data written to a `local-path`-backed PVC survive Pod
recreation, a K3s service restart, and a real host reboot? **Yes — proven
live across all four.** This is **not** a backup story. See
`docs/decisions/0013-home-k3s-persistent-environment.md` for the
platform context this builds on.

## Workload

A single-instance PostgreSQL `StatefulSet` (`stateful-lab/postgresql/`,
namespace `stateful-lab`) — deliberately separate from Authentik's
database, so this storage experiment never mixes with identity or
application behavior. `postgres:17-alpine`, pinned by digest. Non-root
(`fsGroup`-based volume ownership), read-only root filesystem with
scoped `emptyDir` mounts for the two paths the official image writes to
outside `PGDATA`. 1Gi PVC, explicit `storageClassName: local-path`.

## Known data invariant

```sql
CREATE TABLE persistence_proof (
    id INTEGER PRIMARY KEY,
    value TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
```

Expected, always:

```
 id |          value          
----+-------------------------
  1 | aegis-persistence-proof
  2 | home-k3s-postgresql-lab
```

## Results

| Test | Result | Data |
|---|---|---|
| Pod deletion | Pod UID changed (`be1fb945…` → `b34242fb…`), PVC UID unchanged, recovered in 10s | Unchanged |
| StatefulSet rollout restart | New Pod UID, no leftover Git drift | Unchanged |
| K3s service restart | Full stack recovered automatically, API server reachable within seconds, no manual Postgres restart | Unchanged |
| GitOps drift (scale to 2 replicas) | Flux reverted to `replicas: 1` in 28s | Unchanged (the surviving replica was always `-0`) |
| Full host reboot | Host rebooted (`uptime -s` confirmed a fresh boot); full stack (K3s, Cilium, CoreDNS, Flux, Kyverno, aegis-api, PostgreSQL) recovered automatically, no manual intervention | Unchanged — same PVC UID (`adeb161e-…`) before and after |

Resource usage at steady state: ~19m CPU / ~19Mi memory — well under the
100m/256Mi requests, nothing pathological.

One side effect from the drift test worth recording: scaling the
`StatefulSet` down from 2 replicas to 1 did **not** delete the
now-unused `data-postgresql-1` PVC — StatefulSets don't reclaim PVCs on
scale-down unless a `persistentVolumeClaimRetentionPolicy` says to.
Harmless here (it was never mounted, confirmed via `Used By: <none>`
before deleting it by hand), but a real operational detail rather than
something to assume away in future scale-testing.

## Persistence model

| Failure | Protected? | Basis |
|---|---|---|
| Pod/container loss | **Safe** | Observed live — PVC persists independently of Pod identity. |
| K3s service restart | **Safe** | Observed live. |
| Full host reboot | **Safe** | Observed live — same `persistence_proof` rows, same PVC UID, before and after a real reboot of the host. |
| PVC deletion | **NOT protected** | `local-path`'s `StorageClass` has `reclaimPolicy: Delete` (confirmed live on the actual `PV`) — deleting the PVC deletes the backing directory. Not tested; analysis only, per this milestone's own scope. |
| Host disk loss | **NOT protected** | No backup exists. This is the key unresolved risk driving the next milestone. |

## GitOps recreates objects, not data

Git can recreate the `StatefulSet`, `Service`, `PersistentVolumeClaim`
declaration, and the encrypted `Secret` — proven directly by the drift
test above, where Flux rewrote the `StatefulSet`'s `spec.replicas` back
to what Git says. **Git does not contain, and cannot restore, the
`persistence_proof` row itself.** If the PVC's backing directory were
lost, Flux would faithfully recreate an *empty* database with the right
schema-less shell around it — nothing in the reconciliation loop touches
row data. This is exactly why backup is a distinct, later concern, not
something GitOps already provides for free.

## local-path limitations, stated plainly

`local-path` provides node-local persistence — the PVC's data survives
independently of any single container or the Kubernetes control plane
restarting. It does **not** provide replication, HA, snapshot
orchestration, remote backup, or recovery from losing the node itself.
Describing it as durable storage beyond this single host would be
inaccurate.

## What's next

Backup — but not yet, and not a tool choice made in advance. The next
milestone should first decide *what* needs backing up (PostgreSQL
logical data vs. volume-level PVC snapshots vs. the Kubernetes manifests
themselves, which Git already covers) before picking a mechanism, then
prove it with a real destroy-and-restore cycle against this exact
`persistence_proof` invariant.
