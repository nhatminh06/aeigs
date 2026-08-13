# 6. Repo-level scanning: Gitleaks + Trivy config, not a full build pipeline

## Status

Accepted

## Context

The project's supply-chain phase (`source → build → scan → SBOM → sign →
registry`) assumes something that builds a container image. Nothing in
this repository does: `apps/demo-app` runs the public `podinfo` image
unmodified, and Aegis itself is GitOps configuration, not application
source. Implementing the full pipeline here would mean building it around
a fake application just to have something to scan.

## Decision

Scope this first supply-chain step to what's actually true of this repo:
static analysis of the repo's own content.

- **Gitleaks** (`.github/workflows/repo-security.yml`) scans full commit
  history for committed secrets on every push/PR.
- **Trivy config** scans Kubernetes manifests for misconfigurations
  (`trivy.yaml`), used identically in CI and locally so results never
  differ between the two.

Both were verified against this repo before being wired into CI, not
just installed and trusted:

- Gitleaks: confirmed zero false positives against the SOPS-encrypted
  `secret.enc.yaml` files and full history, and confirmed via a positive
  control (a real private-key block) that it actually detects something
  when there is something to detect — a scanner that's never been shown
  to catch anything isn't proven to work.
- Trivy config: found 2 real `HIGH` findings on `apps/demo-app/deployment.yaml`
  (missing `readOnlyRootFilesystem`, no pod-level `securityContext`) that
  were fixed as part of enabling this scanner (see the commit hardening
  `podinfo`'s `securityContext`) — the scanner was proven to work before
  the gate was allowed to block anything, and it started clean rather
  than immediately red on `main`.

`security/policies/tests/` (deliberately insecure fixtures) and
`clusters/dev-kind/flux-system/` (Flux's own generated, "DO NOT EDIT"
manifests) are excluded from the Trivy scan via `trivy.yaml`'s
`skip-dirs` — scanning intentionally-bad fixtures as if they were real
workloads defeats their purpose, and we don't own Flux's generated
output.

CI gates on `HIGH`/`CRITICAL` only; `MEDIUM` and below are visible but
non-blocking for now (e.g. `KSV-0125`, restricting container images to
trusted registries — a real future Kyverno policy, not yet implemented,
so not fair to block on today).

## Consequences

- No SBOM, no image signing, no container vulnerability scanning yet —
  those need a real image build step, which doesn't exist in this repo.
  When one does (a real application repository, or this repo starts
  building something itself), that's a new PR, not a retrofit onto this
  one.
- The two scanners run independently in CI; a Gitleaks failure doesn't
  block the Trivy job or vice versa, so a PR gets both signals at once.
