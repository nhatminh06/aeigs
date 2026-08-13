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
- Flux reconciliation on dev-kind

In progress:
- (nothing currently)

Planned:
- first GitOps-managed application
- HelmRelease conventions
- SOPS + age secrets
- Prometheus / Grafana
- Kyverno admission policies
- security-lab attack scenarios
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

## Architecture (current stage)

```
Laptop
  |
Docker
  |
kind (cluster "aegis-dev")
  |
FluxCD (reconciling clusters/dev-kind from this repo)
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

GitOps-managed applications and every security/observability layer
described in `CLAUDE.md` are planned but not yet present in this
repository. Nothing above this stage should be assumed to work until the
Status section says it's implemented.

## Roadmap

Aegis evolves over months, in small PR-sized increments: repository
foundation, local kind cluster, Flux bootstrap, a first GitOps-managed
application, secrets (SOPS), observability (Prometheus/Grafana), admission
control (Kyverno), a security lab of deliberate attack scenarios, a
software supply-chain baseline, identity (Authentik), network policy, and
eventually a persistent home cluster with backup/disaster-recovery drills.
Each phase is implemented, validated, and documented before the next
begins.
