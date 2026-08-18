# stateful-lab PostgreSQL: backup and destructive restore

Answers the question `docs/runbooks/home-k3s-stateful-recovery.md`
deliberately left open: what happens when the actual Kubernetes volume
is destroyed, not just the Pod or the host? Proven live, once, on
2026-08-18 — see the results below.

## Core distinction

**Persistence != backup. GitOps != data recovery.**

| | Recovers | Does not recover |
|---|---|---|
| Git + Flux | `Namespace`, `Secret` declaration, `Service`, `StatefulSet`, `PersistentVolumeClaim` declaration, policy | Database rows |
| Backup (`pg_dump`) | PostgreSQL schema + rows | Kubernetes objects, the PVC itself, cluster-global roles |
| K3s / `local-path` | Freshly-provisioned storage for Git's declared PVC | Nothing — it has no memory of what used to be there |

A PostgreSQL Pod reaching `Ready` is not evidence of a successful
restore. The only acceptable proof is the exact `persistence_proof`
query, before and after, matching byte-for-byte.

## Backup strategy: logical (`pg_dump`), not volume-level

Chosen over a filesystem/volume-level backup because PostgreSQL
understands its own consistency model (no need to quiesce or snapshot a
live filesystem), the backup is portable independent of `local-path`'s
node-local directory layout, and `pg_dump`'s custom format
(`-Fc`) is inspectable with `pg_restore --list` before ever attempting a
restore. `local-path` has no native snapshot mechanism to exercise here.
This protects a *different* thing than a volume-level backup would
(schema + rows, not the exact PGDATA bytes) — not a universal
replacement for one.

## Encryption: a dedicated age identity

A third, independent trust purpose gets its own key — not the SOPS
Git-decryption key, not the development CA key:

- Private key: `~/.config/aegis/backup/age/keys.txt` (dir `0700`, file
  `0600`) — same off-repo, off-cluster pattern as
  `docs/decisions/0011-development-ca-trust-root.md` already established
  for the CA key.
- Public recipient (safe to record):
  `age1syg4jxryth9pjjamwc4wa9gd52e5h4e86vnyekuur3fm9n7jqvdqm9l8jl`

**Both the backup file and this key are required for recovery.** Losing
either makes the backup useless. This key currently has no second
off-site copy — an explicit, named limitation, not a hidden one.

## Backup location

`~/.local/share/aegis/backups/stateful-lab/postgresql/<UTC timestamp>/`
on the **operator's own machine** — never the K3s host, never inside the
cluster, never Git. `pg_dump` runs inside the `postgresql-0` container
via `kubectl exec` (guarantees exact PostgreSQL-version match, needs no
local client) and streams straight to this machine; the plaintext dump
never touches disk anywhere but a local temp file, deleted immediately
after encryption (`trap`-guaranteed).

## Running a backup

```
scripts/backup-stateful-lab-postgres.sh
```

Refuses to run against any `kubectl` context other than `home-k3s`.
Produces an encrypted `.dump.age` artifact and a plaintext `.metadata.txt`
alongside it (timestamp, source, database, PostgreSQL version, both
plaintext/encrypted SHA-256 checksums, the pre-backup data fingerprint,
Git revision, PVC/PV identity — no credentials, ever).

## Running a restore

```
scripts/restore-stateful-lab-postgres.sh <path-to-.dump.age> <target-db> [--replace-existing]
```

Verifies context, re-checks the artifact's checksum against its metadata
file, decrypts, runs `pg_restore --list` to confirm structure before
touching any database, then restores. Fails loudly by default if target
objects already exist; `--replace-existing` adds `--clean --if-exists`
only when explicitly passed.

## Proof: the 2026-08-18 destructive restore

**Pre-destruction state**: PostgreSQL 17.11, `persistence_proof(id,
value, created_at)`, rows `1 | aegis-persistence-proof` / `2 |
home-k3s-postgresql-lab`, fingerprint (SHA-256 of the canonical
`id,value` query, ordered by `id`):
`97056e51cfb5de13169d52a122a67d067886e13352cc2bfe11605a95b858b54a`.
PVC `data-postgresql-0` (UID `adeb161e-d46d-450d-aedb-13b6d5848393`) on
PV `pvc-adeb161e-d46d-450d-aedb-13b6d5848393` (UID
`593aa942-beef-4ead-933e-3c5ed65db9d5`).

1. **Backup** created: `stateful-lab-postgresql-20260818T124518Z.dump.age`,
   encrypted SHA-256 `690900beb8...`, plaintext dump 1874 bytes,
   encrypted artifact 2074 bytes. ~1s.
2. **Structural verification**: `pg_restore --list` on the decrypted
   archive showed the table, its data, and its primary key constraint —
   before any destruction.
3. **Non-destructive scratch restore**: restored into a temporary
   `aegis_restore_verify` database on the *same live* instance;
   fingerprint matched the pre-backup one exactly; scratch database
   dropped, original untouched.
4. **Negative tests, on copies only**: decrypting with a freshly
   generated wrong key failed (`no identities found`); a truncated copy
   failed age's own payload authentication (`file may be corrupted or
   tampered with`); a copy with a flipped byte failed the restore
   script's checksum check before decryption was even attempted. The
   real backup file was never touched by any of these.
5. **Safety gate**: all criteria passed (backup exists off-host,
   checksums verified, structure verified, scratch restore fingerprint
   matched, original database still healthy, Git tree clean except this
   milestone's own new files) — proceeded to destruction.
6. **Suspended only** `Kustomization/stateful-lab` (not `flux-system`,
   Cilium, Kyverno, or `aegis-api`).
7. Scaled the `StatefulSet` to 0, confirmed the Pod terminated and
   nothing had the PVC mounted.
8. **Deleted `PersistentVolumeClaim/data-postgresql-0`.** Confirmed via
   `local-path-provisioner`'s own logs — not just "the object is
   gone" — that it ran a helper pod and genuinely `rm -rf`'d
   `/var/lib/rancher/k3s/storage/pvc-adeb161e-…`: *"Volume
   pvc-adeb161e-… has been deleted on cachyos-x8664:…"*. Direct host
   filesystem inspection was not used as evidence here — `local-path`'s
   `0700` directory permissions correctly refuse an unprivileged SSH
   session either way, so the provisioner's own deletion log is the
   authoritative proof, not a filesystem probe that can't distinguish
   "gone" from "permission denied."
9. Deliberately did **not** additionally delete the `StatefulSet`,
   `Service`, or `Secret` — the PVC alone is the actual variable this
   milestone tests (data-volume loss); deleting the rest would only add
   risk without adding evidence about that one question.
10. **Resumed** `Kustomization/stateful-lab`. Flux recreated the PVC (via
    the unchanged `volumeClaimTemplate`) and the Pod restarted onto
    fresh, empty storage — new PVC UID
    `5715dccc-bf2f-4907-b705-741dbeca57df`, new PV
    `pvc-5715dccc-bf2f-4907-b705-741dbeca57df` (UID
    `6032ea41-631c-4c6b-8739-967938418007`) — genuinely different
    identity from the destroyed one, not the same disk reused.
11. **Mandatory proof, checked before touching the backup**: queried the
    fresh database. `\dt` found no relations at all;
    `SELECT * FROM persistence_proof` failed with `relation
    "persistence_proof" does not exist`. Flux rebuilt the infrastructure.
    It did not, and cannot, rebuild the data.
12. **Restored** from the real off-host backup into the fresh
    `aegis_state` database. `pg_restore` completed with no errors.
13. **Exact data recovery, verified**: schema identical (same column
    types, same primary key), rows identical
    (`1 | aegis-persistence-proof`, `2 | home-k3s-postgresql-lab`),
    fingerprint **exactly** `97056e51cfb5de13169d52a122a67d067886e13352cc2bfe11605a95b858b54a`
    — matching the pre-destruction value precisely.
14. **Pod-recreation check**: deleted the new Pod once more; the
    `StatefulSet` recreated it; the restored data was still present —
    proving it lives on the new PVC, not in process memory.

A second K3s service restart or host reboot after restore was not
repeated — both were already proven safe for data in the prior milestone
against a different PVC identity; re-running them here would not add new
evidence.

## Timings (lab measurements, not RTO/RPO commitments)

- Backup: ~1s
- Destruction (PVC delete → confirmed gone via provisioner logs): ~4s
- Reconstruction (Flux resume → Pod `Ready` on fresh storage): ~30s
- Restore (`pg_restore` into the fresh database): a few seconds
- End-to-end, backup-exists to fully-restored-and-reverified: well under
  two minutes of actual work, excluding the deliberate verification
  pauses (scratch restore, negative tests) taken before destruction

## Current RPO / RTO

**RPO**: exactly the time of the latest successful backup. Any write
between that backup and a real destructive event is lost — this is one
manual, point-in-time backup, not continuous protection. **Not** zero
data loss.

**RTO**: this lab's observed restore time (see above), which required a
human operator to run both scripts by hand, retrieve the backup and its
key, and verify each stage. Not a production RTO commitment.

## Recovery responsibility model

```
Git / Flux recovers:      Namespace, Secret, Service, StatefulSet, PVC
                           declaration, policy
Backup recovers:           PostgreSQL schema + rows
K3s / local-path provides: fresh node-local storage for Git's declared PVC
```

## Failure model, after this milestone

| Failure | Status |
|---|---|
| Pod loss | Protected — PVC persists |
| K3s service restart | Protected — local disk persists |
| Host reboot | Protected — local disk persists (prior milestone) |
| PVC deletion | **Recoverable from backup** — proven live above |
| PV / backing-directory loss | **Recoverable from backup** — same proof, since that's exactly what was destroyed |
| Host disk loss | Database recoverable *if* a new K3s environment, Git, the SOPS age key, the backup file, and the backup age key are all available — **not tested as a combined, wiped-host scenario** |

## What this does not claim

**"Destructive database restore proven from an independent off-host
logical backup."** Not "disaster recovery complete," not "zero data
loss," not "production database backups." Specifically still true after
this milestone:

- Backup is manual — no schedule, no CronJob, no automation.
- No retention policy; every backup is a permanent, individually-named
  artifact until manually removed.
- No PITR, no WAL archiving — single point-in-time snapshots only.
- Single backup target, itself with no independent backup.
- The backup age key has no second, independent copy yet.
- Single-node K3s; `local-path` storage remains node-local.
- A full wiped-host rebuild-plus-restore has not been proven — only a
  wiped *volume* on an already-running host.
- No Gateway/TLS/monitoring/Authentik on home-k3s; manual release
  promotion remains.

## Common failure modes

- **"Decryption failed"** — wrong or missing
  `~/.config/aegis/backup/age/keys.txt`, or the artifact was corrupted
  in transit. Confirmed live: age's own authenticated encryption
  detects tampering; it does not silently produce garbage output.
- **"checksum mismatch"** — the `.dump.age` file doesn't match its
  `.metadata.txt`. Treat as corrupted; do not proceed.
- **`pg_restore --list` fails** — the archive itself is invalid; the
  restore script stops here, before touching any database.
- **Restoring into a database that already has the target objects**
  without `--replace-existing` fails loudly by design — this is the
  safety behavior, not a bug.
