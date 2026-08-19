# Aegis

Aegis is a security-focused GitOps platform built to study how Kubernetes
systems behave under failure — not just how to deploy them. It runs two
environments (a disposable local cluster and a persistent home server), one
owned Go application with a full signed release pipeline, and a set of
deliberate failure experiments — leaked secrets, unsigned images, lateral
network movement, a signed-but-broken release, database destruction, host
reboot, a Kubernetes version change — each proven with real commands and
real output, not asserted from configuration alone.

## Why Aegis

Most homelab/portfolio Kubernetes projects stop at "I installed these
tools." Aegis's premise is different: a control isn't real until it's been
tested against a real failure. The project follows one repeating loop —

**Build → Secure → Observe → Break → Recover → Prove**

— and every major claim in this README links to the command, log, or
document that proves it. See ["What I actually tested"](#what-i-actually-tested)
below.

## Architecture

![Aegis architecture: application supply chain, GitOps control plane, policy/secrets/trust, the intentional dev-kind/home-k3s divergence, threat/control/evidence, recovery responsibility model, and feature-freeze/accepted limitations](docs/architecture/architecture.png)

The diagram above is the current, maintained 1:1 architecture reference.
The ASCII summary below and the [two-environment table](#two-environments)
cover the same ground in text form, for anywhere images don't render.

```
                         GitHub (github.com/nhatminh06/aeigs)
                       /                              \
                 aegis (this repo)                 aegis-api
                       |                                |
                     Flux                    CI: tests -> Trivy -> SBOM -> Cosign
                       |                                |
                       |                              GHCR
                       |                                |
                       +------------- digest ----------+
                                       |
                                 Kubernetes
                                       |
                 +---------------------+---------------------+
                 |                     |                     |
             Security              Identity            Observability
                 |                     |                     |
         Kyverno, Cilium         Authentik OIDC      Prometheus, Grafana
         NetworkPolicy, SOPS
```

Two independent Kubernetes clusters run this same shape — they do **not**
share a control plane. See below for exactly how and why they diverge.

## Two environments

| Capability | dev-kind | home-k3s | Why different |
|---|---|---|---|
| Purpose | Experimentation, failure injection, policy development | Long-lived validation, persistence/recovery proof | dev-kind is disposable by design; it can't teach host lifecycle or reboot recovery |
| Lifecycle | Disposable — torn down and rebuilt often | Persistent — survives reboots, service restarts | — |
| Ingress | Cilium Gateway API + Envoy | nginx (Deployment, NodePort) | Cilium's `reserved:ingress` backend datapath deterministically fails on the home-k3s host — see the [Cilium Gateway story](#the-cilium-gateway-story) below |
| TLS | cert-manager + Aegis development CA | cert-manager + same shared development CA | One trust root, two ingress mechanisms |
| Identity | Authentik (bundled/ephemeral PostgreSQL) | Authentik (standalone, persistent PostgreSQL) | home-k3s's identity state must survive restarts; dev-kind's doesn't need to |
| Observability | Prometheus + Grafana, SLO rules | Prometheus + Grafana, SLO rules | Same stack, independently deployed |
| Release promotion | Automatic (Flux Image Automation selects signed digests) | Manual (a human commits the digest) | Persistent environment intentionally has no Git write credential — smaller blast radius, see [ADR 0013](docs/decisions/0013-home-k3s-persistent-environment.md) |
| Persistence | Cluster lifecycle only — rebuild is cheap | Host-backed K3s state + `local-path` PVCs | — |
| Backups | None (nothing worth backing up — disposable) | Scheduled, encrypted, verified (stateful-lab + Authentik) | — |
| Recovery proven | N/A | Pod loss, K3s restart, host reboot, PVC/PV destruction, replacement-host reconstruction, destructive identity restore, K3s patch rollback | See [Failure & recovery evidence](#failure--recovery-evidence) |
| Image automation | Full (`ImageRepository`/`ImagePolicy`/`ImageUpdateAutomation`) | None by design | — |

## What it demonstrates

| Area | Implementation | Evidence |
|---|---|---|
| GitOps | Flux v2.9.4, anonymous Git read, no runtime Git token | Manual drift (`kubectl scale`) reconciled automatically within ~1 poll interval |
| Secrets | SOPS + age, no plaintext credential ever committed | Fresh-cluster decryption tested during every rebuild |
| Admission | Kyverno (`disallow-privileged-containers`, `disallow-latest-tag`, `verify-aegis-api-image`) | 20/20 static tests pass; live signed-allow / unsigned-deny / wrong-signer-deny |
| Networking | Cilium + Kubernetes NetworkPolicy | Lateral movement to Authentik's PostgreSQL flipped from `ALLOWED` to `DENIED`, verified via Hubble |
| TLS | cert-manager + a development CA | Trusted HTTPS on every hostname in both environments |
| Supply chain | Trivy + Syft SBOM + Cosign keyless signing + Kyverno enforcement | Wrong-signer image denied with a distinct error from "unsigned" |
| Reliability | Prometheus SLOs over aegis-api's own metrics | A signed, policy-admitted release with a real latency regression, caught by Prometheus alone |
| Persistence & identity | local-path PostgreSQL, standalone Authentik PostgreSQL | Pod/K3s/host-reboot recovery, PVC/PV destruction + restore, DB-only identity restored with the same UUID |

## What I actually tested

Configuration is not evidence. Every row below is a real command run against
a real cluster, with the actual result — not the intended one.

| Experiment | Failure introduced | Evidence | Result |
|---|---|---|---|
| Leaked credential | Planted RSA private key, scanned in CI | [`security-lab/leaked-secret/`](security-lab/leaked-secret/) | `PASS: Gitleaks detected the planted credential (rule: private-key)`; an inverse test (stubbed always-pass scanner) was correctly caught as a lab failure |
| Unsigned container image | Deployed a real, unsigned aegis-api digest | [`security-lab/unsigned-image/`](security-lab/unsigned-image/) | Denied: `.attestors[0].entries[0].keyless: no signatures found` |
| Wrong signer | Attached a signature from an unrelated GitHub workflow | [`security-lab/unsigned-image/`](security-lab/unsigned-image/) | Denied with a **distinct** error: `subject mismatch: expected .../release.yml@refs/tags/v..., received .../wrong-signer-test.yml@refs/heads/main` |
| Lateral DB movement | `busybox` probes from an unrelated namespace to Authentik's PostgreSQL/server/worker | [`security-lab/network-lateral-movement/`](security-lab/network-lateral-movement/) | Before: Hubble `policy-verdict:L4-Only INGRESS ALLOWED`. After: `INGRESS DENIED / DROPPED` on every probed port, legitimate flows (Grafana→Authentik) still `ALLOWED` |
| Signed-but-bad release | `v0.1.4`: real O(2^n) latency regression, passed every supply-chain gate | [`reliability-lab/aegis-api-slo/`](reliability-lab/aegis-api-slo/), [runbook](docs/runbooks/aegis-api-bad-release.md) | p95 4.75ms → 237ms against a 100ms objective; detected in ~1m59s; Git-owned rollback in ~3m; full recovery ~3m45s — see the [highlighted story](#the-signed-but-bad-release-story) below |
| PostgreSQL PVC/PV destruction | Deliberately deleted the PVC backing stateful-lab's PostgreSQL | [runbook](docs/runbooks/stateful-lab-postgresql-backup-restore.md) | Flux rebuilt an empty database (confirmed, not assumed); `pg_restore` from an off-host encrypted backup brought back the exact original rows |
| Replacement-host recovery | Reconstructed home-k3s on a disposable Lima VM that had never run K3s | [runbook](docs/runbooks/home-k3s-recovery.md) | Same exact data fingerprint on a machine with none of `cachyos`'s disk state |
| Cilium Gateway datapath failure | Compared Gateway ingress against an ordinary nginx proxy on the same host | [ADR 0014 addendum](docs/decisions/0014-home-k3s-gateway-blocked-by-cilium-ingress-identity-bug.md) | Gateway: 503 on every request, handshake never completes. Control path: **20/20** success, **20/20** correct 404s — see the [highlighted story](#the-cilium-gateway-story) below |
| Authentik DB destruction | Deleted the PVC/PV backing Authentik's standalone PostgreSQL | [runbook](docs/runbooks/home-k3s-authentik.md) | Confirmed the test identity absent post-reconstruction, then restored with the **same UUID** — see the [highlighted story](#the-identity-recovery-story) below |
| K3s version rollback | Real K3s binary swap (`v1.36.3+k3s1` → `v1.36.2+k3s1` → back) | [runbook](docs/runbooks/home-k3s-upgrade.md) | Full platform, identity, and data validated on both legs, plus a real host reboot mid-cycle |

### The signed-but-bad release story

**Provenance is not correctness.** `v0.1.4` was built by trusted CI,
scanned by Trivy, SBOM-attested, Cosign-signed, and admitted by Kyverno —
every supply-chain gate passed, because every gate checks *who built it*,
not *whether it works*. It carried a real algorithmic regression (recursive
instead of iterative Fibonacci) and was auto-deployed by Flux Image
Automation exactly as designed.

Kubernetes, Kyverno, and Hubble all reported the workload healthy the
entire time — availability stayed 100%, 5xx stayed 0%. Only Prometheus,
evaluating p95 latency against a 100ms objective, caught it: measured
latency was 237ms. Detection took about two minutes (matching the alert's
`for: 2m` window). Recovery went through Git, not `kubectl` — one commit
suspended image automation and rolled the digest back to the known-good
`v0.1.3`. The root cause was fixed, a regression guard (`TestFibonacciStaysLinear`)
was added, and `v0.1.5` went through the full supply chain again before
automation resumed. `v0.1.4`'s tag and signature remain published,
untouched, as incident evidence. Full timeline:
[`docs/runbooks/aegis-api-bad-release.md`](docs/runbooks/aegis-api-bad-release.md).

### The identity recovery story

**GitOps restores desired infrastructure. Backups restore mutable state.**
Git can rebuild every Kubernetes object Authentik needs — the
`StatefulSet`, the `Service`, even Django's own database schema via
migration — but it cannot restore a row of data, because Git never
contained one.

`aegis-recovery-test` was created directly through Authentik's API:
active, deliberately non-admin, and never declared in any Git-managed
blueprint. After deliberately destroying the PVC/PV backing Authentik's
PostgreSQL, Flux rebuilt the Kubernetes objects and Authentik's own
migrations rebuilt the schema — and the test user was confirmed **absent**
before touching the backup, the actual point of the experiment. Restoring
from the encrypted off-host `pg_dump` brought the identity back with the
**same UUID**, still non-admin, and a real interactive Grafana OAuth login
succeeded again — including after a full CachyOS host reboot performed
afterward. Full evidence:
[`docs/runbooks/home-k3s-authentik.md`](docs/runbooks/home-k3s-authentik.md#destructive-identity-recovery).

### The Cilium Gateway story

**Identical architecture was rejected when real datapath evidence
disagreed with the plan.** home-k3s was meant to reuse dev-kind's Cilium
Gateway API for ingress — same CNI, same version, same intended pattern.
It didn't work: every request through the Gateway returned 503. Live
`cilium-dbg monitor --type trace` capture showed why — connections tagged
with Cilium's `reserved:ingress` identity get a SYN-ACK back from the
backend pod, then the handshake never completes.

Rather than assume this was a general host problem, a control experiment
(`ingress-lab/`) proxied the same paths through an ordinary nginx
Deployment instead — first pod-to-pod, then via a plain K3s `NodePort`.
Both control paths worked perfectly: **20/20** successful requests on
every healthy endpoint, **20/20** correct 404s on `/metrics`, full clean
TCP handshakes captured live, every time. The defect isolates specifically
to the Gateway/`reserved:ingress` datapath — reproduced identically on two
Cilium versions, ruled out against NetworkPolicy, the host firewall, and
routing mode. home-k3s now runs a small, Flux-owned nginx reverse proxy
instead — a real architectural divergence driven by evidence, not
preference. Full investigation:
[ADR 0014](docs/decisions/0014-home-k3s-gateway-blocked-by-cilium-ingress-identity-bug.md).

## Security model

**Supply chain**: Trivy (image scan) → Syft (SBOM, attached as a Cosign
attestation) → Cosign keyless signing (GitHub Actions OIDC identity) →
Kyverno `verifyImages` (requires that exact signature before admission).
`ImagePolicy` selects *which* release Git records as desired; Kyverno
independently decides whether the selected digest is *trusted* — proven
distinct controls, not just designed that way (a narrowed `ImagePolicy`
happily selected a real unsigned digest; Kyverno denied it anyway).

**Secrets**: SOPS + age for every Git-managed Secret; no plaintext
credential ever committed; Flux holds no runtime Git write token by
default (dev-kind's Image Automation writer is scoped to one path via its
own dedicated credential, [ADR 0012](docs/decisions/0012-image-automation-git-write-credential.md)).

**Network**: Cilium as CNI, `networking.k8s.io/v1` NetworkPolicy for every
portable peer relationship, one `CiliumNetworkPolicy` only where
dev-kind's Gateway backend traffic carries Cilium's `reserved:ingress`
identity (a case a portable selector genuinely cannot express).

**Identity**: Authentik OIDC backs Grafana login in both environments;
local admin login stays available as a fallback in each.

**Ingress/TLS**: cert-manager issues from a shared Aegis development CA
in both environments — Cilium Gateway API in dev-kind, nginx in home-k3s
(see the [Cilium Gateway story](#the-cilium-gateway-story)).

This is a development-security posture, evidence-backed at every layer
described above — not a zero-trust platform, and not described as one.

### Threat / control / evidence

| Threat | Control | Evidence |
|---|---|---|
| Credential committed to Git | Gitleaks, CI-gated | `leaked-secret` lab |
| Unsigned or tampered image | Kyverno `verifyImages` | `unsigned-image` lab, live denial |
| Wrong signing identity | Cosign keyless subject match | Distinct denial error from "unsigned" |
| Lateral movement to a database | Kubernetes NetworkPolicy | `network-lateral-movement` lab, Hubble before/after |
| Provenance-valid but broken release | Prometheus SLOs | `v0.1.4` experiment |
| Database/identity destruction | Encrypted off-host `pg_dump` + scratch-restore verification | stateful-lab and Authentik destructive-restore proofs |
| Platform version regression | Real K3s patch upgrade/rollback | `docs/runbooks/home-k3s-upgrade.md` |

## Software supply chain

```
source → tests → multi-arch build → Trivy → Syft SBOM → Cosign keyless
signature → GHCR digest → Flux ImagePolicy → Git commit → Kyverno
admission → Deployment
```

Three independent layers, proven separately: `ImagePolicy` **selects**
which version Git should record as desired (a compatibility-range query,
not "always newest"); Kyverno **decides** whether the selected digest is
trusted (signature verification, independent of `ImagePolicy`'s choice);
Prometheus **decides** whether a trusted, admitted application actually
behaves correctly. No layer trusts the one before it.

**dev-kind** wires this up fully automatically: `ImageRepository` scans
GHCR, `ImagePolicy` selects the highest compatible semver tag,
`ImageUpdateAutomation` commits the selected digest into
`apps/aegis-api/deployment.yaml` through its own scoped writer credential.
Git remains the record of desired state; Kyverno remains the final trust
gate regardless of what automation selected.

**home-k3s** deliberately has none of this — release promotion is a human
Git commit, by design (see the environment table above). See
["Owned workloads"](#supply-chain-in-detail) below for the full flow diagram.

## Failure & recovery evidence

See ["What I actually tested"](#what-i-actually-tested) above for the
full experiment table. This section covers the recovery *model* —
what recovers from where.

### Persistent recovery model

| Source | Recovers |
|---|---|
| Git + Flux | Kubernetes desired state (Deployments, Services, PVC declarations, policy) |
| SOPS age key | Encrypted Git-managed Secrets |
| PostgreSQL backup (age-encrypted) | Mutable database rows and identity state |
| Development CA | The same local TLS trust root across both environments |
| GHCR | Application container images |
| Mac (operator workstation) | Currently the only location holding the SOPS key, backup age key, encrypted backup ciphertext, and development CA key |

**Git is not a database backup.** Every destructive-recovery experiment in
this project exists specifically to prove that distinction: Flux always
rebuilds correct, empty Kubernetes objects; only an encrypted backup
brings mutable rows back.

### Failure model

| Failure | Recovery status |
|---|---|
| Pod loss | **PROVEN** |
| K3s service restart | **PROVEN** |
| Full host reboot | **PROVEN** |
| PVC/PV loss | **PROVEN** |
| Fresh/replacement host | **PROVEN** |
| Authentik database loss | **PROVEN** |
| Signed-but-bad app release | **PROVEN** |
| K3s same-minor patch rollback | **PROVEN** |
| Mac recovery-root loss | **NOT PROTECTED — deferred** |
| Cross-minor K3s upgrade | **NOT TESTED** |

## Repository structure

| Path | Contents |
|---|---|
| `apps/` | Applications Flux deploys (`aegis-api`, `demo-app`) |
| `bootstrap/` | One-time cluster bootstrap config (kind node image, Cilium values) |
| `clusters/` | Per-environment Flux root Kustomizations (`dev-kind/`, `home-k3s/`) |
| `docs/` | ADRs, runbooks, architecture notes, portfolio materials |
| `infrastructure/` | cert-manager, ingress (Gateway/nginx) |
| `observability/` | kube-prometheus-stack HelmReleases |
| `security/` | Authentik, Kyverno, admission policies |
| `security-lab/` | Deliberate attack scenarios against real controls |
| `reliability-lab/` | Deliberate reliability experiments (SLOs, bad releases) |
| `ingress-lab/` | Control experiment isolating the Cilium Gateway defect |
| `stateful-lab/` | Persistent PostgreSQL used for destructive-recovery proofs |
| `scripts/` | Bootstrap, backup, restore, and verification tooling |
| `ops/launchd/` | macOS scheduler templates for the backup agents |

## Quick start

### dev-kind (disposable, ~10 minutes)

```
scripts/cluster-up.sh          # pinned kind node image
scripts/bootstrap-cilium.sh    # Cilium + Hubble -> node Ready
scripts/bootstrap-flux.sh      # Flux + SOPS age secret + committed sync config
```

Requires an existing `~/.config/sops/age/keys.txt` (the *same* key used to
encrypt this repo's Secrets — `age-keygen` produces a new, useless one).
`scripts/cluster-down.sh` tears it down completely; both scripts are
idempotent. Full walkthrough: [ADR 0002](docs/decisions/0002-use-kind-for-dev.md)
and the prerequisites below.

### home-k3s (persistent — see the runbook, not a one-command toy)

home-k3s reconstruction is a deliberate, multi-step, evidence-checked
procedure — see [`docs/runbooks/home-k3s-recovery.md`](docs/runbooks/home-k3s-recovery.md)
for the full sequence (K3s install, Cilium, Flux, PKI, backup restore).
It is not duplicated here.

### Prerequisites

`kind`, `kubectl`, `helm`, the `flux` CLI, `sops`, `age` (`age-keygen`),
`shellcheck`, `gitleaks`, `trivy`. home-k3s additionally needs SSH access
to a supported Linux host.

### Pinned versions

```
K3s (home-k3s):          v1.36.3+k3s1
Kubernetes (kind node):  v1.36.1, by tag AND digest
Flux:                    v2.9.4
Cilium:                  1.20.0
Kyverno:                 v1.18.2 (chart 3.8.2)
cert-manager:             v1.21.1
kube-prometheus-stack:   88.3.0
Authentik:               2026.5.6
PostgreSQL:               17-alpine
```

## Demo

A deterministic, read-only 5–10 minute walkthrough — no destructive
steps, no secrets shown — is in [`docs/demo.md`](docs/demo.md).

## Limitations

- Single-node home-k3s; no HA
- home-k3s availability depends on the host being on and reachable —
  sleep/offline means outage
- Development-only PKI — not a publicly trusted CA
- Prometheus is not HA; retention is short
- home-k3s release promotion is manual by design
- No PITR / WAL archiving — logical, point-in-time backups only
- No automatic rollback controller — recovery is a deliberate human action through Git
- No MFA / identity federation
- nginx does not auto-reload on certificate rotation — accepted, documented manual step ([runbook](docs/runbooks/home-k3s-nginx-cert-reload.md))
- No egress NetworkPolicy — evaluated, deferred (no Hubble relay on home-k3s to build a confident traffic inventory)
- **Recovery-root concentration**: the Mac currently holds the only copy of the SOPS key, backup age key, encrypted backups, and development CA key — a second independent copy is deferred until genuinely independent storage exists, not faked
- Cross-minor K3s version change is untested (only a same-minor patch cycle has been proven live)
- External dependencies: GitHub, GHCR, Sigstore (Fulcio/Rekor) must be reachable for full supply-chain verification

## Out of scope

Not missing features — evaluated and deliberately not added without a
concrete, evidence-driven requirement: Vault, External Secrets Operator,
Falco, service mesh, Loki, Tempo, Velero, Longhorn, Rook/Ceph, HA
PostgreSQL, multi-node K3s, public ACME/Let's Encrypt, PITR/WAL archiving,
MFA/federation.

**Aegis's technical feature set is frozen.** Further work is bug fixes,
version upgrades, documentation, and portfolio polish — not new platform
capabilities.

## Design decisions & runbooks

### ADRs

| # | Title | Decision |
|---|---|---|
| [0001](docs/decisions/0001-use-flux.md) | Use FluxCD | Flux over Argo CD — a set of controllers, not a separate server/UI |
| [0002](docs/decisions/0002-use-kind-for-dev.md) | Use kind for local dev | Cheap, disposable, config-driven local clusters |
| [0003](docs/decisions/0003-use-sops-age-for-secrets.md) | SOPS + age for secrets | In-cluster decryption without an extra running service |
| [0004](docs/decisions/0004-use-helm-for-observability.md) | Helm for kube-prometheus-stack | The first component whose CRD-heavy operator pattern justifies Helm |
| [0005](docs/decisions/0005-use-kyverno-for-admission-policy.md) | Kyverno for admission policy | Plain YAML policy, no new DSL |
| [0006](docs/decisions/0006-repo-level-scanning.md) | Repo-level scanning scope | Gitleaks + Trivy config only, until a real build step exists |
| [0007](docs/decisions/0007-use-authentik-for-identity.md) | Authentik for identity | Declarative OIDC config via blueprints, not the admin UI |
| [0008](docs/decisions/0008-kyverno-image-tag-parsed-matching.md) | Parsed image-field matching | Fixed false negatives in raw-string tag matching |
| [0009](docs/decisions/0009-minimize-runtime-git-credentials.md) | Minimize runtime Git credentials | Removed Flux's runtime token; this public repo reads anonymously |
| [0010](docs/decisions/0010-bootstrap-cilium-outside-flux.md) | Bootstrap Cilium outside Flux | Flux's own pods need a working CNI first |
| [0011](docs/decisions/0011-development-ca-trust-root.md) | Development CA trust root | Off-cluster private key, separate trust domain from SOPS |
| [0012](docs/decisions/0012-image-automation-git-write-credential.md) | Scoped image-automation credential | Fine-grained, path-scoped PAT, not shared with `flux-system` |
| [0013](docs/decisions/0013-home-k3s-persistent-environment.md) | Persistent home-k3s environment | Second, persistent environment for host-lifecycle recovery proof |
| [0014](docs/decisions/0014-home-k3s-gateway-blocked-by-cilium-ingress-identity-bug.md) | home-k3s Gateway blocked upstream | Documented, not worked around — see the [Cilium Gateway story](#the-cilium-gateway-story) |
| [0015](docs/decisions/0015-home-k3s-nginx-ingress.md) | nginx for home-k3s ingress | Small, Flux-owned proxy replaces the broken Gateway path |
| [0016](docs/decisions/0016-home-k3s-authentik-identity.md) | Standalone home-k3s Authentik | Own persistent PostgreSQL, not dev-kind's disposable one |

### Runbooks

| Runbook | When to use it |
|---|---|
| [`aegis-api-bad-release.md`](docs/runbooks/aegis-api-bad-release.md) | A signed, admitted release is misbehaving |
| [`home-k3s-authentik.md`](docs/runbooks/home-k3s-authentik.md) | Authentik/Grafana OIDC health, recovery, or backup scheduling |
| [`home-k3s-ingress-recovery.md`](docs/runbooks/home-k3s-ingress-recovery.md) | nginx ingress routing/TLS issues |
| [`home-k3s-nginx-cert-reload.md`](docs/runbooks/home-k3s-nginx-cert-reload.md) | A rotated certificate isn't being served yet |
| [`home-k3s-observability.md`](docs/runbooks/home-k3s-observability.md) | Prometheus/Grafana health on home-k3s |
| [`home-k3s-recovery.md`](docs/runbooks/home-k3s-recovery.md) | General home-k3s health, reboot recovery, or full reconstruction |
| [`home-k3s-stateful-recovery.md`](docs/runbooks/home-k3s-stateful-recovery.md) | stateful-lab PostgreSQL persistence evidence |
| [`home-k3s-upgrade.md`](docs/runbooks/home-k3s-upgrade.md) | K3s version upgrade or rollback |
| [`stateful-lab-postgresql-backup-restore.md`](docs/runbooks/stateful-lab-postgresql-backup-restore.md) | Backup, restore, and the Git-vs-backup distinction |

Portfolio materials (60-second pitch, interview stories, resume bullets):
[`docs/portfolio.md`](docs/portfolio.md).

## Supply chain in detail

```
github.com/nhatminh06/aegis-api  (source, tests, CI, release pipeline)
        |
        | tag push v* -> staging build -> scan -> SBOM -> sign -> verify
        |                -> ONLY THEN promote the same digest to vX.Y.Z
        v
   ghcr.io/nhatminh06/aegis-api@sha256:...  (signed)
        |
        v
   ImageRepository/aegis-api  (dev-kind only, scans GHCR, read-only)
        |
        v
   ImagePolicy/aegis-api  (highest 0.1.x semver tag — a compatibility
        |                  range, not "always newest")
        v
   ImageUpdateAutomation/aegis-api  (dev-kind only — commits the selected
        |                            digest into apps/aegis-api/deployment.yaml,
        |                            own scoped writer credential, ADR 0012)
        v
   apps/aegis-api/  (this repository, Flux-owned — Git remains the
        |            record of which release is desired, in both environments)
        v
   Flux -> Kubernetes -> Kyverno verify-aegis-api-image (signature required,
                          independent of ImagePolicy's selection)
                       -> Prometheus (ServiceMonitor, SLO rules)
                       -> NetworkPolicy + CiliumNetworkPolicy
```

A small Go API (`/healthz`, `/readyz`, `/metrics`, `/api/v1/info`,
`/api/v1/work`) built specifically to exercise this operating model.
Application CI never deploys directly — it only builds and publishes the
image; Git state is what Flux reconciles, and on dev-kind, Git state
itself is now updated automatically for trusted releases.

`ImagePolicy` and Kyverno are proven independent controls, not just
designed that way: a test `ImagePolicy` narrowed to a range that could
only select `v0.1.0` — a real published digest already confirmed unsigned
— selected it without complaint, because `ImagePolicy` has no concept of
trust. Kyverno denied that exact digest regardless.
