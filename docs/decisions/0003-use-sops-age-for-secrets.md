# 3. Use SOPS + age for secrets

## Status

Accepted

## Context

Kubernetes `Secret` manifests need to live in Git alongside everything
else Flux reconciles, but their values can't be committed in plaintext.
Options considered: SOPS (with age or PGP), External Secrets Operator
pulling from a separate secret store, and HashiCorp Vault.

## Decision

Use SOPS with age-encrypted values, decrypted in-cluster by
kustomize-controller.

Reasons specific to this project:

- No extra running service — kustomize-controller has SOPS decryption
  built in (`spec.decryption` on a `Kustomization`), unlike External
  Secrets Operator or Vault, which are both additional controllers/servers
  to operate and secure before they're worth their cost.
- age keys are simpler to generate, back up, and reason about than PGP for
  a single-operator project at this stage.
- Encrypted files stay reviewable in PRs/diffs — only values are
  encrypted (`encrypted_regex: ^(data|stringData)$` in `.sops.yaml`), keys
  and structure stay visible.

## Consequences

- The age private key is a single point of failure: losing it makes every
  encrypted secret in the repository unrecoverable. It is generated
  locally (`age-keygen`) and never committed; the operator is responsible
  for backing it up out-of-band.
- Bootstrapping decryption on a new/rebuilt cluster is a manual,
  non-GitOps step: `kubectl create secret generic sops-age -n flux-system
  --from-file=age.agekey=<private-key-path>` before Flux can decrypt
  anything. This is intentional — the decryption key can't itself be
  managed by the system it unlocks.
- Key rotation and multi-operator key management aren't solved yet; this
  is a single dev key for the `dev-kind` cluster only. External Secrets
  Operator or Vault are re-evaluated later if multi-cluster or
  multi-operator key distribution becomes a real requirement.
- **Observed, not just theoretical**: a `Deployment` consuming a `Secret`
  via `envFrom` is not restarted automatically when only the `Secret`'s
  data changes (a general Kubernetes behavior, unrelated to SOPS). When
  the demo-app Secret and its consuming Deployment were introduced in the
  same commit, the pod picked up an env var before Flux's decrypted
  value had finished settling, and kept running with a stale value until
  `kubectl rollout restart` was run manually. A Secret-consuming workload
  needs a way to pick up secret changes on its own — e.g. a checksum
  annotation on the pod template derived from the secret content — which
  isn't implemented yet. Until it is, changing a secret's value requires
  a manual rollout restart of anything consuming it.
