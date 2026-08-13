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

In progress:
- Flux reconciliation on dev-kind

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

## Prerequisites (for local development, once implemented)

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
```

Create the cluster with `scripts/cluster-up.sh` and remove it with
`scripts/cluster-down.sh` (destructive — deletes all workloads on it,
no confirmation prompt). Both scripts are idempotent: re-running
`cluster-up.sh` on an existing cluster or `cluster-down.sh` with no
cluster present is a no-op rather than an error.

Flux, GitOps-managed applications, and every security/observability layer
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
