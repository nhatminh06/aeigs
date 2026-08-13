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

In progress:
- (nothing currently)

Planned:
- supply-chain baseline (scanning, SBOM, signing)
- Authentik identity
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

## Architecture (current stage)

```
Laptop
  |
Docker
  |
kind (cluster "aegis-dev")
  |
FluxCD (reconciling clusters/dev-kind from this repo)
  |
apps/demo-app (podinfo Deployment + Service, namespace demo-app)
  |
observability/kube-prometheus-stack (Prometheus + Grafana, namespace observability)
  |
security/kyverno + security/policies (admission control, namespace kyverno)
```

Create the cluster with `scripts/cluster-up.sh` and remove it with
`scripts/cluster-down.sh` (destructive — deletes all workloads on it,
no confirmation prompt). Both scripts are idempotent: re-running
`cluster-up.sh` on an existing cluster or `cluster-down.sh` with no
cluster present is a no-op rather than an error.

This repository's remote is `github.com/nhatminh06/aeigs`. Flux was
bootstrapped onto `aegis-dev` with:

```
flux bootstrap github \
  --owner=nhatminh06 --repository=aeigs --branch=main \
  --path=clusters/dev-kind --personal
```

This generated `clusters/dev-kind/flux-system/gotk-components.yaml` and
`gotk-sync.yaml` (an SSH-based `GitRepository`, using a deploy key Flux
registered on the repo, plus a self-managing `Kustomization`), committed
them, and applied them to the cluster. `gotk-sync.yaml`'s `Kustomization`
interval was shortened from Flux's 10m default to 1m afterward, so dev
config changes converge quickly — see the comment in that file.

To bring the platform up from a stopped cluster: `cluster-up.sh`, then
re-run the `flux bootstrap github` command above (idempotent — it detects
the existing deploy key and sync manifests and just reconciles). Ongoing
changes to `clusters/dev-kind/` just need a commit and push; no manual
`kubectl apply` is needed after the first bootstrap.

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
(matches `.sops.yaml`) and run `sops --encrypt --in-place <file>`; the
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
