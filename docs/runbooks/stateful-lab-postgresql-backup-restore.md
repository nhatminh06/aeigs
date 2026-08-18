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

## Scheduled backup operations

The two scripts above are proven correct but manual — a human has to
remember to run them, and remember to check whether the result is
actually still restorable. This section covers the operational layer on
top: scheduled backups, automatic per-backup verification, a separate
periodic full scratch restore, retention, and visible status. Neither
`backup-stateful-lab-postgres.sh` nor `restore-stateful-lab-postgres.sh`
is modified — everything below wraps them.

**Aegis development backup objectives** (explicitly not production
SLAs):

| Objective | Value | Reasoning |
|---|---|---|
| Backup frequency | every 6 hours | Small, infrequently-changing lab data; cheap online logical backup. Max intended data-loss window: 6h. |
| Restore-verification cadence | daily | Archive verification (checksum/decrypt/`pg_restore --list`) is cheap and runs on *every* backup; a full scratch restore touches the live database and costs more, so it runs less often. |
| Retention | latest 14 verified backups + the permanent disaster-recovery baseline | 6h × 14 ≈ 3.5 days of rolling history. A starting point sized for a lab with infrequent changes, not a measured requirement — revisit if evidence says otherwise. |

### Pipeline

```
scripts/run-stateful-lab-backup.sh
        |
acquire lock (mkdir — atomic, no flock on macOS)
        |
call backup-stateful-lab-postgres.sh (unchanged)
        |
archive verification, EVERY backup:
  re-check encrypted checksum, decrypt, pg_restore --list
        |
   PASS -> write a NEW sidecar <timestamp>.verified.txt
           (metadata.txt itself is never mutated after creation)
   FAIL -> exit non-zero; no sidecar, no status update, no retention
        |
update ~/.local/state/aegis/backups/stateful-lab/status.txt
        |
scripts/prune-stateful-lab-backups.sh --apply  (only on success)
```

Locking → verify-before-status → status-before-retention is the
load-bearing ordering: a run that dies at any earlier stage leaves the
previous good state exactly as it was.

### Protecting the disaster-recovery backup

The one backup already used as evidence for both the destructive
same-host restore and the empty-host reconstruction
(`20260818T124518Z`) carries an empty `PROTECTED` marker file in its
directory — a new sidecar, not a change to the immutable
artifact/metadata pair. Retention always keeps any backup set carrying
this marker, regardless of age or count.

### Retention

```
scripts/prune-stateful-lab-backups.sh --dry-run   # default, prints only
scripts/prune-stateful-lab-backups.sh --apply     # actually deletes
```

Only considers backup sets with a `.verified.txt` sidecar — a failed or
partial run is never retention-eligible, it just sits there for a human
to notice. Validates the resolved backup root isn't empty, `/`, `$HOME`,
or outside the expected `.../aegis/backups/stateful-lab/postgresql` path
before any `rm -rf`. Tested against a 20-set synthetic fixture
(`--dry-run` showed exactly 5 eligible deletions with 1 protected + 14
latest correctly excluded; `--apply` on the fixture deleted exactly
those 5) before ever running against the real directory.

### Scratch restore verification

```
scripts/verify-stateful-lab-backup-restore.sh [path-to-.dump.age]
```

With no argument, restores the newest archive-verified backup into a
throwaway `aegis_restore_verify_<pid>` database, computes the same
canonical fingerprint query used at backup time, and compares it against
**that backup's own recorded `pre_backup_fingerprint_sha256`** — never a
hardcoded constant, since the lab's data may legitimately change later.
Drops the scratch database in a `trap` regardless of outcome. Never
touches `aegis_state`.

### Status and freshness

```
scripts/backup-status.sh
```

Reads `~/.local/state/aegis/backups/stateful-lab/status.txt` (plain
`key: value` text, same style as backup metadata — no new format):
`last_attempt_at`, `last_success_at`/`last_success_backup`,
`last_verification_at`/`last_verification_backup`,
`last_error_summary`. Compares ages against the objectives above and
prints HEALTHY or STALE per check, exiting 0 or non-zero accordingly. No
credentials in this file.

### Scheduling: macOS launchd, not a Kubernetes CronJob

Deliberately scheduled from the **operator's own machine**, not as a
Kubernetes CronJob — this keeps "where the database lives" and "where
the backup lives" genuinely separate failure domains, which is the
entire point of an off-host backup.

Two per-user LaunchAgents (`ops/launchd/*.plist.template`, generated
into `~/Library/LaunchAgents/` by
`scripts/manage-backup-scheduler.sh install` with this machine's actual
paths substituted — the templates themselves carry no username or
secrets):

- `com.aegis.stateful-lab-backup` — `StartCalendarInterval` at
  00:15/06:15/12:15/18:15.
- `com.aegis.stateful-lab-restore-verify` — `StartCalendarInterval` at
  03:30.

`StartCalendarInterval`, not `StartInterval`: per Apple's own launchd
documentation, a `StartCalendarInterval` job missed while the Mac is
**asleep** runs on wake; one missed while the Mac is **off** simply
waits for the next scheduled time — `StartInterval` jobs have no
documented wake-catchup behavior. Both agents set `PATH`, `HOME`, and
`KUBECONFIG` explicitly via `EnvironmentVariables` (paths only, never
secret values — launchd's inherited environment is minimal and cannot
be assumed to match an interactive shell).

Operator commands, via `scripts/manage-backup-scheduler.sh`:

```
install            # generate + launchctl bootstrap both agents
uninstall          # launchctl bootout both, remove plists — backups
                     themselves are never touched by this
status             # launchctl print state for both
run-now backup     # launchctl kickstart -k, forces an immediate real
run-now verify       launchd-triggered run (not just running the shell
                     script directly — proves the launchd environment
                     itself works)
```

Both agents were force-run this way and completed successfully with no
interactive shell, no Terminal session, and no inherited shell PATH —
the mandatory proof that the scheduled path actually works, not just the
manually-invoked one.

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

## Second proof: restoring onto a replacement host

The destructive restore above reused the same, already-running
`cachyos` cluster — a new PVC, but the same physical disk and the same
K3s installation. That leaves one question unanswered: does this backup
actually work anywhere, or only on the machine that made it? Answered
live, same day, same backup artifact, against a genuinely empty Lima VM
that had never run K3s before (`docs/runbooks/home-k3s-recovery.md`'s
"Empty host recovery" section covers the full Kubernetes-level
reconstruction; this is the database-specific part of that same test):

- **Storage identity, confirmed unrelated to both prior ones**: PVC UID
  `ed016a93-a1dd-413e-9da4-764a6cc0f00c` on PV
  `pvc-ed016a93-a1dd-413e-9da4-764a6cc0f00c` — distinct from both the
  original destroyed identity (`adeb161e-...`) and the same-host restore
  identity (`5715dccc-...`).
- **Mandatory pre-restore proof, repeated on the new host**: `\dt` found
  no relations; `SELECT * FROM persistence_proof` failed with `relation
  "persistence_proof" does not exist`.
- **The exact same backup file and checksum were reused** — no new
  backup was created for this test, matching the point being proven
  (this artifact, made once, is independently useful anywhere).
- **`scripts/restore-stateful-lab-postgres.sh` needed one real fix**: it
  hardcoded the context name `home-k3s`, which would have made it
  refuse to run against a second cluster at all (or, worse, silently
  targeted the wrong one if the names had been made to match). Now
  reads `AEGIS_HOME_K3S_CONTEXT`, defaulting to today's exact value —
  see the script's own comment.
- **Fingerprint after restore**:
  `97056e51cfb5de13169d52a122a67d067886e13352cc2bfe11605a95b858b54a` —
  identical to both the original and the same-host restore.
- **Survived a real reboot of the replacement host** (not `cachyos`):
  full automatic recovery, same data, confirmed after the VM came back.

## Timings (lab measurements, not RTO/RPO commitments)

- Backup: ~1s
- Destruction (PVC delete → confirmed gone via provisioner logs): ~4s
- Reconstruction (Flux resume → Pod `Ready` on fresh storage): ~30s
- Restore (`pg_restore` into the fresh database): a few seconds
- End-to-end, backup-exists to fully-restored-and-reverified: well under
  two minutes of actual work, excluding the deliberate verification
  pauses (scratch restore, negative tests) taken before destruction

## Current RPO / RTO

**RPO**: with scheduled backups now running, the stated objective is
**≤6h since the last successful backup** — but the scheduler cannot back
up a database it can't reach. If `cachyos` or the Mac is offline longer
than the backup interval, actual RPO exposure exceeds the nominal 6h
until connectivity returns; `scripts/backup-status.sh` makes this
visible (STALE) rather than silently claiming success. Scheduler
frequency is an objective, not a guarantee — source availability still
governs the real number. **Not** zero data loss, not continuous
protection.

**RTO**: this lab's observed restore time (see "Timings" above), which
still requires a human operator to run the restore script by hand,
retrieve the backup and its key, and verify each stage — scheduling only
automated *backup creation and verification*, never restore itself. Not
a production RTO commitment.

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
| Primary K3s host loss | **Recoverable — proven on a replacement host**: a genuinely empty machine, given only Git + the SOPS age key + this backup + its backup age key, reconstructed the platform and the exact data. See "Second proof" above and `docs/runbooks/home-k3s-recovery.md`. |

## What this does not claim

**"PostgreSQL backups are generated on a schedule, encrypted off-host,
retained according to a documented policy, and periodically validated
by a full scratch restore."** Not "continuous backups," not "zero data
loss," not "PITR," not "production backup system," not "automatic
disaster recovery" — restore itself remains a manual, operator-driven
runbook procedure; only backup creation and its verification are
scheduled. Specifically still true after this milestone:

- Scheduled logical snapshots only — no PITR, no WAL archiving.
- Backup success still depends on source host/network availability;
  launchd cannot back up a database it can't reach, and does not create
  backups while both machines are inaccessible.
- Single backup destination (this Mac); itself has no independent backup
  of its own.
- The backup age key has no second, independent copy — see "Key
  redundancy" below. Same true of the SOPS age key.
- Single-node K3s; `local-path` storage remains node-local, no HA.
- Restore verification uses the current source PostgreSQL instance for
  its scratch database — it is not an independent verification engine.
- Empty-replacement-host reconstruction is proven on a disposable Lima
  VM, not by actually wiping and reinstalling `cachyos` itself.
- No Gateway/TLS/monitoring/Authentik on home-k3s; manual release
  promotion remains; no Prometheus/Alertmanager monitoring of backup
  status — `scripts/backup-status.sh` is a manual/on-demand check, not
  an alerting system.

### Key redundancy

**Backup age key** (`~/.config/aegis/backup/age/keys.txt`): exists only
on this Mac. If the Mac is lost, every existing encrypted backup becomes
permanently undecryptable, even though the backups themselves might
still exist. **Not resolved by this milestone** — no cloud upload was
added (the milestone explicitly excludes that), and no other physically
separate protected location has been set up yet. **Required user
action, stated plainly**: copy `~/.config/aegis/backup/age/keys.txt` to
at least one other physically separate, protected location (e.g. an
encrypted external drive, or a password manager's secure file/attachment
storage if it handles small binary/text files appropriately) — this is
a manual step, not something this tooling can do on the user's behalf
safely.

**SOPS age key** (`~/.config/sops/age/keys.txt`): same exposure, same
unresolved state, same required action — it is the *other* critical
reconstruction dependency (decrypts every `Secret` Git carries) and
currently also lives only on this Mac. Deliberately not merged with the
backup key — they represent different trust purposes and should keep
independent second copies, not share one.

**Development CA key** (`~/.config/aegis/pki/`): lower priority —
confirmed **not required** for the current home-k3s recovery path (no
Gateway/TLS there yet), so its own redundancy is out of scope here and
does not block this milestone.

A structural weakness worth stating plainly: currently the Mac holds
both the backup ciphertext *and* the only copy of the key that decrypts
it. Losing the Mac loses both at once. The ideal end state is backup
ciphertext in at least two locations and the decryption key in at least
two separate protected locations — not implemented now, flagged
honestly rather than claimed solved.

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
- **"REFUSED: another backup run is already in progress"** — a previous
  run's lock directory (`~/.local/state/aegis/backups/stateful-lab/.run.lock`)
  still exists. Normally cleaned up automatically; if a run was killed
  ungracefully and the lock is genuinely stale, remove that directory by
  hand after confirming no backup is actually running.

## Operator commands

```
scripts/run-stateful-lab-backup.sh              # backup now (manual, ad-hoc)
scripts/backup-status.sh                        # backup status (HEALTHY/STALE)
scripts/verify-stateful-lab-backup-restore.sh    # verify latest restore now
scripts/prune-stateful-lab-backups.sh --dry-run  # retention dry-run
ls ~/.local/share/aegis/backups/stateful-lab/postgresql/  # list backups

scripts/manage-backup-scheduler.sh install       # enable scheduler
scripts/manage-backup-scheduler.sh uninstall     # disable scheduler
                                                    (backups are NOT deleted)
scripts/manage-backup-scheduler.sh status        # scheduler status
scripts/manage-backup-scheduler.sh run-now backup  # force a real
scripts/manage-backup-scheduler.sh run-now verify    launchd-triggered run

tail -f ~/.local/state/aegis/logs/stateful-lab-backup.log
tail -f ~/.local/state/aegis/logs/stateful-lab-restore-verify.log
```
