# Architecture

Current state of Aegis's two environments. Most of this document
describes `dev-kind`, the disposable engineering environment where every
control here was built and tested; `home-k3s`, the newer persistent
environment, is covered in its own section below rather than duplicated
throughout. `architecture.png` predates Authentik, the credential/
bootstrap changes, and home-k3s entirely; this file is the accurate
version and the one to update as the platform changes.

## Runtime

```
  operator                          github.com/nhatminh06/aeigs (public)
     |                                          ^
     | scripts/cluster-up.sh                    | anonymous HTTPS, read-only
     v                                          | (no credential in cluster)
  kind: aegis-dev                               |
  kindest/node v1.36.1, pinned by digest        |
  default CNI disabled                          |
     |                                          |
     | scripts/bootstrap-cilium.sh              |
     |   Cilium 1.20.0 -> node Ready, DNS up    |
     |   + Hubble Relay (flow observability)    |
     |   (before Flux: Flux needs a pod network)|
     |                                          |
     | scripts/bootstrap-flux.sh                |
     |   applies committed flux-system/         |
     v                                          |
  Flux v2.9.4 controllers  ------ GitRepository/flux-system
     |                                   |
     |                                   v
     |                        Kustomization/flux-system (root, 1m)
     |                                   |
     |            +----------------+-----+------+----------------+
     |            v                v            v                v
     |         apps          observability   kyverno          identity
     |       (podinfo)      (Prometheus,    + kyverno-      (Authentik +
     |                       Grafana)        policies        Postgres)
     |                                          |                |
     v                                          |                v
  Kubernetes API  <---- admission control ------+          Grafana OIDC
```

Kyverno enforces admission on everything Flux applies; Authentik is the
OIDC provider Grafana authenticates against.

## Network observability

```
  Cilium agent (per node)
     |-- dataplane: pod networking, service translation
     +-- Hubble server (on by default, node-local socket)
              |
              v
        Hubble Relay  ---- one cluster-wide flow API
              |
              v
        hubble CLI (ships inside the agent image)
              |
              v
        docs/network/traffic-inventory.md
```

The inventory produced the first enforcement control:

```
  traffic inventory (evidence)
          |
          v
  Kubernetes NetworkPolicy  (security/authentik/networkpolicy-*.yaml)
          |
          +--> PostgreSQL ingress:  server + worker -> 5432 allowed
          |                         everything else denied
          |
          +--> server ingress:      grafana -> 9000 allowed (OIDC backend)
          |                         everything else denied
          |
          +--> worker ingress:      deny all (nothing connects to it,
                                    but it listens on 9000/9300)
```

Ingress arrives through Gateway API, and its peer is not a pod:

```
  external client
        |
        v
  Cilium Gateway / Envoy   (host network, kind forwards host :80)
        |
        |  backend connection is opened under the
        |  reserved:ingress identity, NOT as a pod
        v
  CiliumNetworkPolicy      (security/authentik/ciliumnetworkpolicy-server-gateway.yaml)
        |  reserved:ingress -> authentik-server:9000
        v
  Authentik server

  Grafana pod
        |
        v
  Kubernetes NetworkPolicy (security/authentik/networkpolicy-server.yaml)
        |  grafana -> authentik-server:9000
        v
  Authentik server
```

The two policies union to exactly those two peers. The split is deliberate:
portable `networking.k8s.io/v1` NetworkPolicy expresses every workload peer,
and the one vendor-specific policy exists only because `reserved:ingress` is
assigned by Cilium's proxy datapath and cannot be selected by a
`podSelector`, `namespaceSelector` or `ipBlock`. This is how this Cilium
version presents Gateway backend traffic — it is not a general property of
Gateway API.

Node-originated traffic (kubelet probes, `kubectl port-forward`) is not
subject to pod ingress policy in Cilium, so these boundaries govern
pod-to-pod and Gateway access, not user access. Every other observed flow
remains allowed: there is no namespace-wide default deny and no egress
policy. Hubble UI and Hubble Prometheus metrics are not enabled.

## Secrets

The age private key is the one input that cannot be rebuilt from Git.

```
  age private key (off-cluster backup)
     |
     | bootstrap-flux.sh verifies its public half
     |   matches the recipient in .sops.yaml, then creates:
     v
  Secret/sops-age  (flux-system)
     |
     v
  Flux decrypts *.enc.yaml during reconciliation
     (apps, observability, identity)
```

## Repository controls

```
  push / pull request
     |
     v
  .github/workflows/repo-security.yml
     |-- gitleaks              committed secrets (full history)
     |-- trivy-config          manifest misconfiguration
     |-- kyverno-policy-test   policy regression tests
     |-- kustomize-build       GitOps composition builds
     +-- renovate-config       renovate.json is valid

  Renovate (Mend-hosted app)
     |
     v
  dependency update PR -> same CI gates -> human review -> main -> Flux
```

None of these gates catch a Helm value that the chart never reads.

## Configured Helm value is not consumed Helm value

Helm accepts unknown values silently. A misplaced key is present in
`helm get values`, survives every check above, and does nothing. This has
happened twice here:

- `postgresql.networkPolicy.enabled` sat one level above the key the chart
  tests (`primary.networkPolicy.enabled`), so a permissive database
  NetworkPolicy kept rendering.
- `disable_login_form` sat in `[auth.generic_oauth]`, a section Grafana does
  not read it from, so a login safeguard did nothing.

Neither failed visibly. The first was masked by a hand-deleted resource; the
second matched Grafana's default anyway. Schema validation does not close
this: of the four charts in use only Cilium ships `values.schema.json`, and
it accepted a deliberately bogus key in testing.

So for a value that carries a security or reliability claim, verify against
the pinned chart rather than the API server's acceptance of it:

```
  helm pull <repo>/<chart> --version <pinned> --untar
  helm template <name> ./<chart> -f <values> | <check the resource changed>
```

Toggle the value both ways. The evidence is the rendered resource appearing
or disappearing, not the value showing up in `helm get values`.

## TLS and identity

```
  scripts/bootstrap-pki.sh
     |-- restores the Aegis development CA (off-cluster key, never in Git)
     +-- creates Secret/aegis-dev-ca in the gateway namespace
              |
              v
  cert-manager (Flux-owned HelmRelease, v1.21.1 — the only line
                supporting Kubernetes 1.36)
     |-- Issuer/aegis-dev-ca reads that Secret
     +-- Certificate/grafana-tls, Certificate/auth-tls
              |
              v
  Gateway aegis: https-grafana, https-auth listeners (TLS terminate)
     +-- http listener now redirects (301) to the matching HTTPS host
```

Why the CA key is not in Git, and why it is not the SOPS age key reused for
a second purpose, is `docs/decisions/0011-development-ca-trust-root.md`.
One certificate per hostname, not one SAN certificate for both: a reissue
or a mistake in one does not touch the other, proven live by rotating
`grafana-tls` and confirming `auth-tls`'s serial was unchanged.

Grafana's browser-facing OAuth URLs (`root_url`, `auth_url`) point at the
HTTPS Gateway hostnames; its server-side calls (`token_url`, `api_url`)
stay on cluster-internal Service DNS rather than following the browser to
`auth.aegis.test` — routing them through the Gateway would mean Grafana
also has to trust the development CA for no operational benefit, since the
NetworkPolicy path there already exists and is already tested. See
`docs/network/traffic-inventory.md`'s "HTTPS and the OIDC path" section for
the full request path and live evidence, including a real browser login.

## Owned application supply chain

```
github.com/nhatminh06/aegis-api release.yml (tag push only)
        |
        |-- Trivy scan (linux/amd64 + linux/arm64), fails on HIGH/CRITICAL
        |-- Syft SBOM per platform, SPDX JSON, attached as Cosign
        |     attestations on the digest (durable, independent of the run)
        |-- Cosign keyless signature on the exact digest (GitHub Actions
        |     OIDC -> Fulcio short-lived cert -> Rekor), verified with
        |     issuer + identity constraints in the same job
        v
   same digest promoted to the release tag — never a rebuild
        |
        v
   ImageRepository/aegis-api  (scans GHCR, no write access)
        |
        v
   ImagePolicy/aegis-api  (semver 0.1.x only; sha-* staging tags,
        |                  v0.2.0+ ignored — a compatibility range,
        |                  not "always newest")
        v
   ImageUpdateAutomation/aegis-api  (Setters marker in
        |                            apps/aegis-api/deployment.yaml)
        v
   commit to this repo's main, path apps/aegis-api only —
   via GitRepository/aegis-api-image-writer, NOT GitRepository/flux-system
        |
        v
   apps/aegis-api/deployment.yaml (this repo, digest-pinned; Git remains
        |                          the record of which release is desired)
        v
   Kyverno verify-aegis-api-image
        |-- namespace: aegis-api, app: aegis-api only
        |-- requires issuer https://token.actions.githubusercontent.com
        |-- requires subject matching .../workflows/release.yml@refs/tags/v*
        v
   admitted -> Kubernetes
```

Scoped narrowly on purpose: no other workload on this platform is
affected, and this does not claim the image is vulnerability-free, that
the source is trustworthy under every compromise scenario, or that a
compromised GitHub account could not produce a validly-signed image.
Verification depends on live connectivity to GHCR and Sigstore's
Fulcio/Rekor — both at admission time and during Kyverno's background
re-scan.

`ImagePolicy` and Kyverno are independent controls answering different
questions — "which release should Git select" versus "is the selected
artifact signed by the trusted producer" — proven independent, not just
asserted: a test `ImagePolicy` was pointed at a narrowed version range
that could only select `v0.1.0`, a real published digest already
confirmed unsigned, and it selected it without complaint. Kyverno denied
that exact digest regardless. `ImagePolicy` has no concept of trust; it
is not supposed to, and nothing about widening its selection range can
skip Kyverno.

`ImageUpdateAutomation` has no credential field of its own — it
authenticates through whichever `GitRepository` its `sourceRef` names.
Reusing `GitRepository/flux-system` (used by every Kustomization above)
would have put a write-capable credential on the object this platform
deliberately keeps anonymous — see `docs/decisions/0009-minimize-runtime-git-credentials.md`.
A second, dedicated `GitRepository/aegis-api-image-writer` exists for
exactly this — see `docs/decisions/0012-image-automation-git-write-credential.md`
for the credential itself, its scope, and why it is stored off-cluster
rather than SOPS-encrypted into the repository it can write to.

## Reliability feedback loop

The supply chain above proves an artifact's provenance and identity, not
its runtime correctness — a signature says a release came from the
trusted pipeline, not that the code inside it is good. That gap is closed
by Prometheus, and recovery goes back through Git, manually:

```
aegis-api release (passes tests, Trivy, SBOM, Cosign, Kyverno)
        |
        v
Flux Image Automation deploys it (same path as above)
        |
        v
application-level regression, invisible to Kubernetes/Kyverno/Cilium —
Pod stays Ready, liveness/readiness stay healthy, Kyverno stays satisfied
        |
        v
Prometheus (aegis_api:request_success_ratio / http_5xx_ratio /
             http_request_duration_p95_seconds, apps/aegis-api/prometheusrule.yaml)
        |
        v
alert fires -> operator diagnoses (rules out network via Hubble, rules
        |       out supply chain via Cosign/Kyverno re-check) -> confirms
        |       the regression is in the application itself
        v
Git commit: suspend ImageUpdateAutomation + roll deployment.yaml back
   to the known-good digest — together, one commit, to avoid a race
   against automation's own write path
        |
        v
Flux reconciles the rollback; SLO recovers
        |
        v
root cause fixed + regression guard added -> new release -> independently
   verified (Trivy/SBOM/Cosign/Kyverno) -> automation resumed through Git
```

This is a manual, evidence-based loop by design — see
`reliability-lab/aegis-api-slo/` and
`docs/runbooks/aegis-api-bad-release.md` for the incident this proved it
against. There is deliberately no automatic rollback controller: the
thresholds above are development-lab objectives sized from one measured
baseline, not validated enough to be trusted to change production state
unattended.

## Persistent environment (home-k3s)

`dev-kind` is disposable by design; it can't teach persistent
control-plane state, host lifecycle, or reboot recovery. `home-k3s` is a
second, independent environment on a real Linux host that does — not a
replacement, and not yet carrying most of what `dev-kind` runs:

```
                       Aegis Git (github.com/nhatminh06/aeigs)
                                     |
                     +---------------+---------------+
                     |                               |
                     v                               v
                dev-kind                        home-k3s
           (disposable, kind)              (persistent, K3s on a
                     |                       real Linux host)
        automated release selection                |
        (Flux Image Automation,           known-good release only,
         ImageRepository/Policy/           promoted by a deliberate
         UpdateAutomation)                 human Git commit — no
                     |                     ImageRepository/Policy/
        failure injection, SLO,            UpdateAutomation, no
        security labs                      write credential at all
                     |                               |
                     v                               v
              Kyverno (3 policies,              Kyverno (same 3
              signature required)               policies, reused as-is)
                     |                               |
                     v                               v
           Cilium Gateway API/TLS/            nginx ingress (TLS,
           Prometheus/Grafana/                HTTP->HTTPS redirect) +
           Authentik                          Prometheus/Grafana +
                                               own persistent Authentik
                                               (own PostgreSQL, own
                                               OAuth client) — NOT
                                               Cilium Gateway API,
                                               see below.
```

Both environments read the same public repository anonymously — neither
has ever had a runtime Git token. Only `dev-kind` can write to it (via
the dedicated `aegis-api-image-writer` credential,
`docs/decisions/0012-image-automation-git-write-credential.md`);
`home-k3s` is a Git consumer only, by design, so there is exactly one
place a bad release can get auto-selected from, and one deliberate human
step between "validated on dev-kind" and "running on home-k3s."

K3s (pinned `v1.36.3+k3s1`) and Cilium (1.20.0, same version as
dev-kind, bootstrap-managed outside Flux for the same reason — Flux
needs a working pod network before it can reconcile anything) form the
base; Flux (core controllers only — no image automation) reconciles
`clusters/home-k3s`. Proven live: a K3s service restart, a real full
host reboot, and a GitOps drift-and-correct cycle all recovered fully
automatically, with no manual `kubectl apply` at any point.

Full reasoning — including three real, host-specific networking failures
found and fixed live (kube-proxy/Cilium coexistence, Cilium's
device/MTU auto-detection picking up the wrong interface, a host
firewall silently dropping pod-to-Service traffic) — is in
`docs/decisions/0013-home-k3s-persistent-environment.md`. Day-to-day
health checks are in `docs/runbooks/home-k3s-recovery.md`.

home-k3s now has permanent, trusted HTTPS ingress
(`api.aegis.home.arpa`, `grafana.aegis.home.arpa`, `auth.aegis.home.arpa`)
and Prometheus/Grafana observability — but deliberately **not** through
Cilium's Gateway API, which is broken on this host (a `reserved:ingress`
datapath defect, `docs/decisions/0014-...md`) and replaced by a small,
dedicated nginx reverse proxy instead
(`docs/decisions/0015-home-k3s-nginx-ingress.md`). Both environments
share the same development CA (ADR 0011), so a client that trusts
dev-kind's certificates trusts home-k3s's too.

Grafana now authenticates through a persistent, home-k3s-specific
Authentik instance (`docs/decisions/0016-home-k3s-authentik-identity.md`)
— its own PostgreSQL (standalone, not the bundled/ephemeral subchart
dev-kind uses), its own OAuth client credentials, and a portable
`NetworkPolicy` instead of dev-kind's Cilium Gateway exception (since
home-k3s's ingress is an ordinary workload, confirmed live via Cilium
trace evidence — a genuine architectural difference, not forced
symmetry with dev-kind). Local admin login stays available as a
recovery fallback. A DB-only, non-Git test identity
(`aegis-recovery-test`) proved identity state survives Pod loss, K3s
restart, and a real host reboot through the actual OIDC login flow —
proven with two separate interactive browser logins, before and after
reboot, verified server-side via Grafana's API each time.

**Explicitly not present on home-k3s yet**: any image automation.
See the environment-comparison table below.

### Persistent application state (stateful-lab)

A single PostgreSQL `StatefulSet` (`stateful-lab/postgresql/`, its own
`stateful-lab` namespace — never Authentik's database) proves data on a
`local-path` PVC survives Pod recreation, a K3s service restart, and
GitOps drift correction. This chain is deliberately drawn separate from
the Git/Flux one above — Git recreates Kubernetes objects, it does not
contain or restore database rows:

```
PostgreSQL (stateful-lab/postgresql/)
        |
        v
   PersistentVolumeClaim (1Gi, StorageClass local-path)
        |
        v
   PersistentVolume (rancher.io/local-path provisioner)
        |
        v
   /var/lib/rancher/k3s/storage/<pv-name> on the CachyOS disk
```

versus, separately:

```
Aegis Git (StatefulSet/Service/PVC declaration, encrypted Secret)
        |
        v
   Flux -> recreates the Kubernetes objects above
        |
        X  -- does NOT recreate the rows inside PostgreSQL's data files
```

Full results and the persistence/failure model (Pod loss, K3s restart,
host reboot — all proven safe) are in
`docs/runbooks/home-k3s-stateful-recovery.md`.

### Backup and destructive restore

Proven live: an encrypted, off-host `pg_dump` backup, followed by
deliberately destroying the PVC/PV/backing directory, letting Flux
rebuild the Kubernetes objects onto fresh storage, confirming the
database rows are genuinely gone, then restoring the exact original data
from that backup:

```
PostgreSQL (stateful-lab)
        |
      pg_dump (inside the container, exact version match)
        |
        v
   encrypted backup (age, dedicated key — not the SOPS or CA key)
        |
        v
   OFF-HOST: operator's own machine, never the K3s host, never Git
```

The disaster path this proves, drawn separately so Git is never implied
to store database rows:

```
PVC/PV/data lost
        |
        v
   Aegis Git -> Flux -> recreates Kubernetes objects, NEW empty PVC
        |
        v
   (database rows still absent at this point — confirmed, not assumed)
        |
        v
   off-host encrypted backup -> pg_restore -> exact original rows return
```

Full evidence (checksums, exact fingerprint match, the mandatory proof
that Flux alone left the database empty) is in
`docs/runbooks/stateful-lab-postgresql-backup-restore.md`. Backup
*creation* and its *verification* are now scheduled (see below); restore
itself remains a deliberate, manual, operator-run step — no PITR, no WAL
archiving, no automatic disaster recovery.

The same shape was proven for Authentik's own identity database on
2026-08-19 — a DB-only, non-Git test identity (`aegis-recovery-test`) as
the load-bearing proof that Git/Flux reconstruction, and Authentik's own
Django schema migrations, do not by themselves recreate identity rows:

```
Authentik PVC/PV/data lost
        |
        v
   Aegis Git -> Flux -> recreates the StatefulSet, NEW empty PVC
        |
        v
   Django migrations re-run against the fresh database
   (schema returns; identity rows do not)
        |
        v
   (aegis-recovery-test confirmed absent at this point — not assumed)
        |
        v
   off-host encrypted backup -> pg_restore -> identity returns,
   OIDC login to Grafana works again, survives a full host reboot
```

Full evidence is in `docs/runbooks/home-k3s-authentik.md`'s "Destructive
identity recovery". Unlike stateful-lab, this proof was not repeated on
an empty replacement host.

### Scheduled backup operations

```
      CachyOS / home-k3s
              |
         PostgreSQL
              |
           pg_dump
              |
              v
        Mac launchd scheduler (per-user LaunchAgents, not a
              |                 Kubernetes CronJob — keeps database
              |                 storage and backup storage in
              |                 genuinely separate failure domains)
        age encryption
              |
              v
     immutable timestamped backups
              |
      +-------+-------+
      |               |
 retention       archive verification (every backup: checksum,
 (latest 14 +      decrypt, pg_restore --list)
  protected              |
  baseline)              v
                   scratch restore verification (daily: real restore
                   into a throwaway database, fingerprint compared
                   against that backup's own recorded value)
```

Recovery still depends on the same external roots as before — Git, the
SOPS age key, the backup ciphertext, the backup age key, and GHCR for
the application image — none of which this scheduling layer changes.

### Empty-host reconstruction

Proven live on a disposable Lima VM (never `cachyos` itself — see
`docs/runbooks/home-k3s-recovery.md`'s "Empty host recovery"): a Linux
host that has never run K3s can reach a fully working `home-k3s`,
including the exact restored database, using only external roots — none
of `cachyos`'s own disk is read or copied:

```
                       GitHub (Aegis Git)
                            |
                          Flux
                            |
                replacement home-k3s (empty host)
                            |
                     fresh local-path
                            |
                       PostgreSQL
                            ^
                            |
                  encrypted backup + its own age key
                            |
                     Mac / off-host
```

A second, independent root feeds Git decryption specifically:

```
SOPS age key (off-host, off-cluster)
        |
        v
  decrypts Secret objects Git carries (e.g. stateful-lab's
  postgresql credential) once Flux applies them
```

Recovery dependency table — what each root is for, and what happens if
it's lost:

| Asset | Stored where | Required for | If lost |
|---|---|---|---|
| Aegis Git repository | GitHub | Kubernetes desired state | Blocking — nothing rebuilds without it (unless a separate clone/mirror exists) |
| SOPS age private key | Off-host (`~/.config/sops/age/`) | Decrypting Git-managed `Secret` objects | Blocking — encrypted Secrets stay undecryptable forever |
| PostgreSQL backup artifacts | Off-host (Mac, `~/.local/share/aegis/backups/{stateful-lab,authentik}/`) | Database schema + rows (two separate families — stateful-lab and Authentik never share an artifact) | Blocking for data recovery — infrastructure still rebuilds, database stays empty |
| PostgreSQL backup age key | Off-host (`~/.config/aegis/backup/age/`) | Decrypting both backup artifact families (same key, one trust purpose) | Blocking — the backup files alone are useless without it |
| GHCR | External registry | `aegis-api` container image | Application reconstruction impacted; Kubernetes/database recovery unaffected |
| Development CA key | Off-host (`~/.config/aegis/pki/`) | TLS on dev-kind AND home-k3s (one shared root, ADR 0015) | Blocking for both — `scripts/bootstrap-pki.sh` (dev-kind) / `scripts/bootstrap-pki-home-k3s.sh` (home-k3s) both restore from this same file |
| Image-writer PAT | dev-kind only | Flux Image Automation writes | **Not required for home-k3s** — no writer credential exists there at all |

Failure-domain view (which physical machine, if lost, takes what with
it):

| Machine lost | Consequence |
|---|---|
| CachyOS (K3s host) | Recoverable — proven live on a replacement host, given Git + the SOPS key + the off-host backup + backup key |
| Mac (control workstation) | **The current single point of failure**: holds the only copies of both the backup ciphertext and the backup age key (and the SOPS age key). Losing it loses recoverability entirely until a second protected copy of both keys exists — see "Key redundancy" in `docs/runbooks/stateful-lab-postgresql-backup-restore.md`, currently unresolved. |
| GitHub (Aegis Git) | Blocking for reconstruction until available again or a local mirror exists |
| GHCR | Blocks pulling a new `aegis-api` image; already-running Pods and Kubernetes/database recovery are unaffected |

## Not present yet

Namespace-wide default deny, egress policy, and L7 policy (only the
ingress boundaries above are enforced). Any node-level HA is not
present on `home-k3s`. Cilium Gateway API is installed but not the
active ingress mechanism there (ADR 0014/0015). Authentik's PostgreSQL
destructive PVC/PV restore was proven live 2026-08-19 (below); an
empty-replacement-host reconstruction for Authentik specifically has not
been attempted (only stateful-lab's database has that second proof).
The
development CA is trusted only by clients that explicitly import it —
this is not a publicly trusted certificate and must not be described as
one. Automatic rollback, progressive delivery/canary release, or any
controller that changes production state based on the SLO alerts above
— rollback today is a deliberate, evidence-based human action through
Git. Alertmanager delivery is not installed; alert *evaluation* runs in
Prometheus regardless. Nothing above should be read as implying those
exist.
