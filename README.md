# Aegis

Self-hosted Kubernetes platform managed declaratively through Git with
FluxCD. Local development uses `kind`; a persistent home cluster (K3s,
later Talos) and an optional AWS EKS environment are long-term targets.
Security controls (admission policy, encrypted secrets, image scanning and
signing, network isolation, centralized identity) are added one layer at a
time as the platform matures — see `CLAUDE.md` for the engineering rules
that govern how this repository is built.

## Status

```
Implemented:
- local kind cluster (create/delete via scripts/cluster-up.sh, cluster-down.sh)
- Flux reconciliation on dev-kind, bootstrapped against github.com/nhatminh06/aeigs
- first GitOps-managed application (apps/demo-app: podinfo)
- SOPS + age secrets, decrypted in-cluster by Flux
- Prometheus + Grafana (kube-prometheus-stack via HelmRelease)
- Kyverno admission policies (deny privileged containers, deny latest tags)
- security-lab: 3 documented attack scenarios (security-lab/)
- repo-level scanning in CI: Gitleaks (secrets) + Trivy config (manifest misconfigurations)
- Authentik identity, Grafana logs in via OIDC through it

In progress:
- (nothing currently)

Planned:
- container build/scan/SBOM/signing (needs a real image-building app repo first)
- NetworkPolicy / default-deny
- persistent home cluster
- backup and disaster-recovery drills
```

## Prerequisites (for local development)

- Docker
- `kind`
- `kubectl`
- `flux` CLI
- `sops` and `age` (secrets)

### Pinned versions

Rebuilding the cluster should reproduce the same baseline rather than
picking up whatever happens to be installed, so two things are pinned:

```
Kubernetes (kind node): v1.36.1, by tag AND digest
                        (bootstrap/kind/cluster.yaml)
Flux CLI + controllers: v2.9.4
                        (clusters/dev-kind/flux-system/gotk-components.yaml)
```

Verify before bootstrapping a cluster:

```
flux version --client     # expect: flux: v2.9.4
```

The Flux CLI writes `gotk-components.yaml` at its own version, so a CLI
that doesn't match the committed manifest would silently upgrade (or
downgrade) the controllers on the next `flux bootstrap`. `flux version`
against a running cluster prints the controller versions for comparison
(`distribution: flux-v2.9.4`).

Upgrading either is deliberate, not incidental: pick the new version,
re-pin it (for the node image, tag **and** digest together — the digest
is the multi-arch manifest list, so it works on arm64 and amd64), then
re-run the platform validation rather than assuming the existing controls
still hold on a new baseline.

## Architecture (current stage)

![Aegis architecture: source & bootstrap, FluxCD GitOps control plane, Kubernetes API & workloads, admission control, and the local dev/drift-test loop](docs/architecture/architecture.png)

*Diagram predates Authentik (added after this image was made): identity
isn't pictured yet. It sits alongside Kyverno conceptually — another
`security/` component Flux reconciles, providing OIDC for Grafana. See
the Authentik paragraph below and
`docs/decisions/0007-use-authentik-for-identity.md` for what the diagram
doesn't yet show.*

Laptop → Docker → `kind` (cluster `aegis-dev`) → FluxCD (reconciling
`clusters/dev-kind` from this repo) → `apps/demo-app` (podinfo, namespace
`demo-app`) and `observability/kube-prometheus-stack` (Prometheus +
Grafana, namespace `observability`), with `security/kyverno` +
`security/policies` enforcing admission control on everything Flux
applies.

Create the cluster with `scripts/cluster-up.sh` and remove it with
`scripts/cluster-down.sh` (destructive — deletes all workloads on it,
no confirmation prompt). Both scripts are idempotent: re-running
`cluster-up.sh` on an existing cluster or `cluster-down.sh` with no
cluster present is a no-op rather than an error.

This repository's remote is `github.com/nhatminh06/aeigs`. Flux was
bootstrapped onto `aegis-dev` with:

```
GITHUB_TOKEN=$(gh auth token) flux bootstrap github \
  --owner=nhatminh06 --repository=aeigs --branch=main \
  --path=clusters/dev-kind --personal --token-auth
```

This uses HTTPS with a GitHub token rather than the SSH deploy key Flux
defaults to — this network blocks the SSH protocol entirely (both port
22 and `ssh.github.com:443` time out; plain HTTPS works fine), so the
default SSH bootstrap doesn't work here. Don't assume SSH works on every
network when bootstrapping elsewhere; test it first, and use
`--token-auth` if not. This generated
`clusters/dev-kind/flux-system/gotk-components.yaml` and `gotk-sync.yaml`
(an HTTPS `GitRepository` with a token-backed `secretRef`, plus a
self-managing `Kustomization`), committed them, and applied them to the
cluster. `gotk-sync.yaml`'s `Kustomization` interval was shortened from
Flux's 10m default to 1m afterward, so dev config changes converge
quickly — see the comment in that file (re-running `flux bootstrap`
regenerates this file and resets the interval; re-apply the shortened
interval if that happens).

The bootstrap token and the runtime Git credential are two different
concerns. `flux bootstrap` needs a token — it writes commits and creates
the deploy setup via the GitHub API — but that same token then sits in
the `flux-system` Secret as the credential `source-controller` uses for
every fetch afterward, indefinitely, even though this repository is
public and doesn't need one for reads. `gotk-sync.yaml`'s `GitRepository`
has had that `secretRef` deliberately removed (verified live: anonymous
HTTPS reconciliation works with it gone); see
`docs/decisions/0009-minimize-runtime-git-credentials.md`.

**That is why rebuilds no longer re-run `flux bootstrap`.** By its own
`--help`, `flux bootstrap github` "commits the Flux manifests to the
specified branch" — so re-running it regenerates `gotk-sync.yaml` with a
token-backed `secretRef` and pushes that to `main`, silently undoing the
hardening above (and resetting the 1m interval). The manifests it would
generate are already committed here, so a rebuild applies those instead
via `scripts/bootstrap-flux.sh`, which needs no GitHub token and cannot
modify the repository. The original bootstrap command is kept above as
the historical record of how `flux-system/` first came to exist, not as
the recovery procedure.

### Rebuilding the cluster

`kind` has no "stop" — `cluster-down.sh` deletes the cluster entirely,
wiping all in-cluster state. Two commands bring it back:

```
scripts/cluster-up.sh        # pinned kind node image (see above)
scripts/bootstrap-flux.sh    # Flux + sops-age + committed sync config
```

`bootstrap-flux.sh` applies the committed `gotk-components.yaml`, waits
for the CRDs and controllers, restores the `sops-age` secret from the age
key on disk, then applies `gotk-sync.yaml`. Flux takes over from there
and reconciles everything else from Git. It refuses to run against a
kubectl context other than `kind-aegis-dev`, and it needs no GitHub
token — the `GitRepository` reads this public repository anonymously.

The one thing that cannot be rebuilt from Git is the **age private key**:
it decrypts every `*.enc.yaml`, so `apps`, `observability`, and
`identity` cannot reconcile without it. Restore the *existing* key from
backup to `~/.config/sops/age/keys.txt` (or point `SOPS_AGE_KEY_FILE` at
it) before running the script — running `age-keygen` instead produces a
new key that cannot decrypt anything already committed. The script fails
loudly rather than continuing if the key is missing.

After the first bootstrap, ongoing changes to `clusters/dev-kind/` just
need a commit and push; no manual `kubectl apply` is needed.

`apps/demo-app` runs `podinfo`, wired in via
`clusters/dev-kind/apps.yaml` (a Flux `Kustomization` pointing at
`./apps/demo-app`). Both the deploy loop (Git commit → Flux → running
pod) and drift correction (manual `kubectl scale` reverted by Flux within
about a minute, matching the 1m reconcile interval) have been verified
against the real cluster. See `docs/decisions/` for why Flux and kind were
chosen.

Secrets are encrypted with SOPS + age (see
`docs/decisions/0003-use-sops-age-for-secrets.md`). To bring up decryption
on a cluster:

```
age-keygen -o ~/.config/sops/age/keys.txt   # once, keep the output safe — never commit it
kubectl -n flux-system create secret generic sops-age \
  --from-file=age.agekey=~/.config/sops/age/keys.txt
```

The `apps` Kustomization (`clusters/dev-kind/apps.yaml`) references this
secret via `spec.decryption`. This is a manual, non-GitOps step by
design: the key that unlocks encrypted secrets can't itself be managed by
the system it unlocks. To encrypt a new secret, name it `secret.enc.yaml`
(or `<descriptive-name>.enc.yaml` if the directory already has one —
matches `.sops.yaml`'s `path_regex`) and run `sops --encrypt --in-place
<file>`; the
`age` public key encoded in `.sops.yaml` is safe to commit, the private
key at `~/.config/sops/age/keys.txt` is not — export
`SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt` so `sops` finds it on
macOS.

`kube-prometheus-stack` (Prometheus, Grafana, kube-state-metrics,
node-exporter, the Prometheus Operator; Alertmanager disabled) runs via a
Flux `HelmRelease` — see
`docs/decisions/0004-use-helm-for-observability.md` for why Helm was used
here specifically, and `clusters/dev-kind/observability.yaml`. Grafana's
admin credentials are a SOPS-encrypted `Secret`
(`observability/kube-prometheus-stack/secret.enc.yaml`), referenced via
`grafana.admin.existingSecret` rather than a plaintext Helm value.
Prometheus is confirmed scraping real targets (kubelet, coredns,
kube-state-metrics, node-exporter); some kind-specific control-plane
targets (etcd, scheduler, controller-manager) show as down, since kind
doesn't expose those the way a kubeadm cluster does — not yet
investigated. Grafana login and Grafana→Prometheus querying have both
been verified against the real decrypted credentials, not just assumed
from the chart installing.

Kyverno enforces two admission policies (`security/policies/`): no
privileged containers, no `latest`/missing image tags — see
`docs/decisions/0005-use-kyverno-for-admission-policy.md`. Both are in
`Enforce` mode (block, not just report) and both have been tested against
the real cluster with a passing and a failing manifest each
(`security/policies/tests/`) — actual admission rejection was observed,
not assumed from the policy YAML alone.

`security-lab/` runs deliberate attack scenarios against controls that
already exist — privileged containers, mutable/missing image tags, and
GitOps drift — each documented with the actual command run and the real
output observed, not a hypothetical. See `security-lab/README.md` for the
list and what's deliberately not a lab yet (RBAC escalation, leaked
secrets, unsigned images — none of those have a backing control in this
repo yet).

`.github/workflows/repo-security.yml` runs Gitleaks and Trivy config on
every push/PR — see
`docs/decisions/0006-repo-level-scanning.md` for why this is scoped to
repo-level scanning rather than the full source→build→scan→sign pipeline
(nothing in this repo builds a container image yet). `trivy.yaml` is the
single source of truth for scan settings, used identically by CI and
locally (`trivy config --config trivy.yaml .`). CI gates on
`HIGH`/`CRITICAL` findings.

Authentik (`security/authentik/`, `HelmRelease`, chart pinned `2026.5.6`,
in-cluster non-persistent Postgres) provides identity, with Grafana's
login wired to it via OIDC — see
`docs/decisions/0007-use-authentik-for-identity.md`, including three real
bugs hit and fixed while setting it up (an empty `grant_types`, missing
scope property mappings, and the SSH-blocked-network issue above). The
Authentik→Grafana OIDC provider/application are defined declaratively via
an Authentik **blueprint**, mounted from a SOPS-encrypted `Secret` — not
configured by hand through the Authentik UI. Verified with a real login:
Grafana provisioned a new user (`akadmin@aegis.local`,
`authLabels: ["Generic OAuth"]`) distinct from the local `admin` account,
confirmed via the Grafana API, not just observed once in a browser.
Reaching both services requires `kubectl port-forward` on this dev
cluster (`authentik-server` to `9000`, `kube-prometheus-stack-grafana` to
`3000`) — no ingress yet.

Every security layer described in `CLAUDE.md` beyond this is planned but
not yet present in this repository. Nothing above this stage should be
assumed to work until the Status section says it's implemented.

## Roadmap

Aegis evolves over months, in small PR-sized increments: repository
foundation, local kind cluster, Flux bootstrap, a first GitOps-managed
application, secrets (SOPS), observability (Prometheus/Grafana), admission
control (Kyverno), a security lab of deliberate attack scenarios, a
software supply-chain baseline, identity (Authentik), network policy, and
eventually a persistent home cluster with backup/disaster-recovery drills.
Each phase is implemented, validated, and documented before the next
begins.
