# Runbook: home-k3s recovery

Applies when `home-k3s` (the persistent environment on `cachyos`) needs
diagnosing — after a reboot, a network blip, or general "is it healthy"
checks. Not a general Linux administration guide; only what's specific to
this environment. See
`docs/decisions/0013-home-k3s-persistent-environment.md` for why this
environment is built the way it is.

## Reconstruction vs. reboot — know which one you're doing

**Reboot**: the same machine comes back. K3s's on-disk state
(`/var/lib/rancher/k3s`) survives; systemd restarts K3s automatically;
Cilium, Flux, and the application all recover with no manual action.
This is the normal case and is proven live (see the ADR).

**Reconstruction**: a new or wiped machine. K3s must be reinstalled
(`scripts/bootstrap-home-k3s.sh`), Cilium re-bootstrapped
(`scripts/bootstrap-cilium-home-k3s.sh`), Flux re-bootstrapped
(`scripts/bootstrap-flux-home-k3s.sh`) — Git rebuilds the workload state
from there, same as `dev-kind`. **Proven live** on a genuinely empty
replacement host (a disposable Lima VM, never `cachyos` itself) — see
"Empty host recovery" below and
`docs/runbooks/stateful-lab-postgresql-backup-restore.md` for the
database side of that same test.

## Empty host recovery

Proven live, once, 2026-08-18, against a disposable Lima VM (`cachyos`
was never touched). Full sequence:

```
prepare a Linux host that has NEVER run K3s
        |
        v
scripts/bootstrap-home-k3s.sh          (on the target host — installs
        |                                pinned K3s, needs sudo)
        v
fetch its kubeconfig into a SEPARATE file/context — never overwrite
~/.kube/home-k3s.yaml or reuse the "home-k3s" context name for a
recovery target
        |
        v
scripts/bootstrap-cilium-home-k3s.sh   (AEGIS_HOME_K3S_KUBECONFIG /
        |                                AEGIS_HOME_K3S_CONTEXT /
        |                                AEGIS_CILIUM_DEVICE env vars
        |                                point this at the recovery
        |                                cluster without risking the
        |                                real one)
        v
restore the SOPS age identity (existing key — verify its public
recipient matches .sops.yaml; never generate a new one)
        |
        v
scripts/bootstrap-flux-home-k3s.sh     (same env var overrides; no
        |                                `flux bootstrap github`,
        |                                anonymous Git read, root path
        |                                ./clusters/home-k3s)
        v
Flux reconstructs Kyverno -> policies -> aegis-api -> stateful-lab,
unassisted
        |
        v
verify Kyverno actually enforces (signed digest -> ALLOWED, unsigned ->
DENIED) before trusting aegis-api — a Running Pod alone isn't proof
        |
        v
verify the fresh PostgreSQL database is EMPTY before touching any
backup — this is the proof Git didn't smuggle in data
        |
        v
scripts/restore-stateful-lab-postgres.sh (AEGIS_HOME_K3S_CONTEXT set;
                                           reuses the EXISTING off-host
                                           backup — never create a new
                                           one from the recovery host)
```

Required external inputs (see `docs/architecture/README.md`'s recovery
dependency table for the full picture): the Git repository itself, the
SOPS age private key, the PostgreSQL backup artifact, and its dedicated
backup age key. Nothing from the old host's disk — no copied
`/var/lib/rancher/k3s`, no copied `local-path` directory, no copied
kubeconfig — is used or needed.

Two real gaps this test found and fixed (not hypothetical — the
committed scripts would have reproduced already-solved bugs without
these): the committed `bootstrap-home-k3s.sh` was missing
`disable-kube-proxy: true`, present only as a live, undocumented fix on
`cachyos`; and the recovery target's actual network interface name
differs from `cachyos`'s `wlan0`, handled via `AEGIS_CILIUM_DEVICE`
rather than changing the primary host's committed Cilium values.

**What this proves**: an empty replacement Linux host can reconstruct
`home-k3s` from committed Aegis state and independently restore
PostgreSQL data from an encrypted off-host backup. **What it does not
prove**: unattended/automatic disaster recovery, HA, or a production
RTO — every step above was run by a human operator.

## Prerequisites

- SSH access to the host (`ssh cachyos` or equivalent), key-based.
- `~/.kube/home-k3s.yaml` present locally (`scripts/fetch-home-k3s-kubeconfig.sh`
  if missing or stale).
- Every command below assumes `export KUBECONFIG=~/.kube/home-k3s.yaml`
  first, or `KUBECONFIG=~/.kube/home-k3s.yaml` prefixed per command.
  **Never** merge this into `~/.kube/config` — see the ADR's reasoning on
  avoiding an accidental wrong-cluster `kubectl`.

## Health checks, in order

1. **Reachability**: `ssh cachyos uptime` — if this fails, the problem is
   the host/network (asleep, disconnected, Tailscale down), not
   Kubernetes. Check `tailscale status` on the operator machine first.
2. **K3s service**: `ssh cachyos systemctl status k3s --no-pager`. Expect
   `active (running)`.
3. **Node**: `kubectl get nodes`. Expect `Ready`. `NotReady` with no
   Cilium pods running usually means Cilium hasn't come up yet (check
   step 4) — this is expected for the first ~30s after a cold boot, not
   an incident on its own.
4. **Cilium**: `kubectl -n kube-system get pods` — `cilium-*`,
   `cilium-envoy-*`, `cilium-operator-*` all `Running`. `cilium-dbg
   status --brief` (via `kubectl -n kube-system exec ds/cilium --`)
   should report `OK`.
5. **CoreDNS**: same namespace, `coredns-*` should be `1/1 Running`.
   `0/1` for more than ~30s after Cilium is healthy is the specific
   failure mode documented in the ADR (kube-proxy/Cilium ClusterIP
   routing, or the host firewall) — check `kubectl -n kube-system logs
   deploy/coredns` for `"waiting for Kubernetes API"` repeating
   indefinitely as the signature.
6. **Flux**: `flux get sources git` and `flux get kustomizations` —
   all `Ready=True` at the same revision. A stale revision usually means
   the `GitRepository` hasn't fetched yet; `flux reconcile source git
   flux-system` forces it.
7. **Kyverno**: `kubectl -n kyverno get pods` — all `Running`.
8. **Application**: `kubectl -n aegis-api get pods` — `1/1 Running`.
   `kubectl -n aegis-api port-forward svc/aegis-api 18080:80` (Phase-1
   validation path only, not the long-term access method — see the ADR)
   then `curl localhost:18080/api/v1/info` and confirm the version/commit
   match the digest pinned in `apps/aegis-api/home-k3s/deployment.yaml`.
9. **Stateful lab (PostgreSQL)**:
   ```
   kubectl -n stateful-lab get pvc data-postgresql-0    # Bound
   kubectl -n stateful-lab get pod postgresql-0          # 1/1 Running
   kubectl -n stateful-lab exec postgresql-0 -- \
     psql -U aegis -d aegis_state -c \
     "SELECT id, value FROM persistence_proof ORDER BY id;"
   ```
   Expected exactly two rows: `1 | aegis-persistence-proof` and
   `2 | home-k3s-postgresql-lab`. See
   `docs/runbooks/home-k3s-stateful-recovery.md` for what this does and
   does not protect against — do not treat a healthy Pod as proof the
   data survived; query it.

**If Kubernetes objects are missing** (`Namespace`/`Secret`/`StatefulSet`/
`Service`/`PVC` declaration gone) — check Flux first
(`flux get kustomizations`); it owns all of those and will recreate them
on its own once the `GitRepository` is healthy.

**If the SQL data itself is missing** (table absent, rows absent, or a
fingerprint mismatch) — **Flux cannot fix this.** It has never contained
a database row. Recovery requires a verified encrypted backup and its
dedicated age key — see
`docs/runbooks/stateful-lab-postgresql-backup-restore.md`. Do not expect
`flux reconcile` to help here.

**Checking whether backups themselves are healthy**: run
`scripts/backup-status.sh` — it reports HEALTHY/STALE against the stated
6h backup / 24h restore-verification objectives. Backups run on a
schedule (two per-user launchd agents; see the backup runbook's
"Scheduled backup operations" section) but restore itself is always a
manual, operator-run step — a STALE status here does not mean data was
lost, only that the safety net hasn't refreshed recently, most often
because `cachyos` or this Mac was offline at the scheduled time.

## Common situations

**"It was fine yesterday, now everything's unreachable."** Almost always
the host itself (asleep laptop, Tailscale disconnected, Wi-Fi changed).
Check reachability (step 1) before assuming a Kubernetes problem.

**Node `Ready` but Flux Kustomizations show a stale/errored RBAC message
right after a restart.** Observed once, live, during a K3s service
restart test: a transient RBAC lookup failure (built-in ClusterRoles not
yet re-populated) that self-cleared on Flux's own next reconcile.
`flux reconcile kustomization <name>` to force it sooner; don't treat a
single transient error right after a restart as a real incident without
checking whether it clears within a minute.

**Pod-to-Service traffic works from a `hostNetwork` pod but not from an
ordinary pod.** This is the exact multi-layer failure documented in the
ADR (kube-proxy/Cilium coexistence, device/MTU auto-detection, UFW).
Don't re-debug it from scratch — read the ADR's "What changed during
implementation" section first.

## What NOT to do

- Don't run `flux bootstrap github` here — see
  `scripts/bootstrap-flux-home-k3s.sh`'s own comments; it would push a
  token-backed credential to Git that this environment deliberately
  never has.
- Don't create an `ImageRepository`/`ImagePolicy`/`ImageUpdateAutomation`
  here "for consistency with dev-kind" — this environment is a Git
  consumer only, by design.
- Don't promote a newer `aegis-api` release here by editing
  `apps/aegis-api/home-k3s/deployment.yaml` unless that release has
  already been through `dev-kind`'s full pipeline and SLO/incident-lab
  loop.
