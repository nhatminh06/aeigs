# CLAUDE.md

Durable engineering rules for the Aegis repository. Read this before making
any change. This file records standing decisions, not task-specific notes —
task notes belong in PR descriptions or commit messages, not here.

## Project purpose

Aegis is a self-hosted Kubernetes platform managed with FluxCD (GitOps).
Git is the source of truth for cluster state; a local `kind` cluster is the
primary development/test environment; a persistent home cluster (K3s or
later Talos) and an optional AWS EKS environment are long-term targets.
Security controls (admission policy, secret encryption, image scanning and
signing, network isolation, identity) are added incrementally as the
platform matures.

Aegis is **not**: a finished product, a portfolio piece optimized for
apparent size, or something that copies "production-grade" tooling without
testing that the control actually works. Claims about what is implemented
must match reality — see "Status honesty" below.

## Architecture principles

- Git is the source of truth for Kubernetes desired state. Manual `kubectl`
  changes are temporary debugging only and are expected to be reverted by
  Flux reconciliation.
- FluxCD is the GitOps reconciler for every cluster.
- `kind` is the local, disposable development/test environment. It is never
  removed in favor of a persistent cluster — persistent clusters (home,
  cloud) are additional environments, not replacements.
- Home infrastructure will later use K3s, with Talos evaluated separately
  as a deliberate comparison, not because it's more interesting.
- Cloud environments (if built) reuse the same GitOps and security patterns
  as `kind`/home rather than inventing cloud-specific architecture.
- Security is layered (repo, build, GitOps, admission, secrets, identity,
  network, runtime) and layers are added one at a time, each tested before
  the next begins.
- Services are added slowly and deliberately; a new service must fit
  existing platform requirements (GitOps-managed, secrets handled
  correctly, monitored, access-controlled) before it's added.
- Prefer understanding and maintaining a small set of tools over installing
  many tools that look impressive but aren't operated with real
  understanding.

## Repository conventions

- Directories are created when a milestone actually needs them, not in
  advance. The long-term repository shape is documented in project
  planning, not pre-built as empty scaffolding.
- Environments live under `clusters/<name>/` (`dev-kind`, `home`, `cloud`).
- Flux resources for a cluster live under that cluster's directory;
  reusable manifests live under `infrastructure/`, `security/`,
  `observability/`, `apps/`, etc., and are referenced by Kustomizations,
  not duplicated per cluster.
- Plain Kustomize is used until an application genuinely needs Helm's
  templating (parameterized upstream charts). Don't wrap Helm in
  unnecessary layers.
- Secrets are never committed in plaintext. Once secrets are needed, SOPS +
  age is the default mechanism; alternatives are evaluated only if SOPS
  proves insufficient.
- Documentation lives under `docs/`: `decisions/` for ADRs (only for
  decisions with real tradeoffs — not "we made a folder"), `runbooks/` for
  operational procedures, others as they become necessary.
- Scripts live under `scripts/` unless tightly scoped to one bootstrap
  method (e.g. `bootstrap/kind/`).

## Engineering standards

- No plaintext secrets in Git, ever — including in commit history.
- No `latest` image tags; pin image tags (and prefer digests where it
  matters) for anything deployed.
- Pin tool and chart versions rather than tracking a moving target.
- Document non-obvious architectural decisions as ADRs under
  `docs/decisions/`; don't document obvious ones.
- Avoid unnecessary abstraction, premature templating, and duplicated YAML.
  Three similar files are fine; a generator for three files is not.
- Fail loudly. Scripts and manifests should surface errors, not silently
  continue in a broken state.
- Shell scripts use `set -euo pipefail` unless there's a specific reason
  not to, quote variables, and check that required commands exist before
  using them.
- Automation must be understandable by a human operator reading it once —
  no 500-line Bash frameworks.
- Destructive commands (cluster teardown, secret rotation, force operations)
  are clearly labeled as destructive in scripts and docs.
- Prefer reproducibility over convenience: if a step can't be re-run from
  Git plus documented bootstrap commands, that's a gap to close, not a
  shortcut to take.

### Status honesty

Distinguish clearly between: implemented, experimental, planned,
production-inspired, and production-ready. Never describe a control as
providing zero trust, high availability, disaster recovery, a secure
supply chain, or full observability until it has been built **and tested**
end to end. README and docs must reflect the platform's actual current
state, not its eventual goal.

## AI/tooling rules

- No AI attribution anywhere in this repository: no AI contributor entries,
  no "Generated by/with AI" notices, no `Co-Authored-By: Claude` or
  `Co-Authored-By: Anthropic` trailers, no AI badges, no mention of AI
  tooling in commit messages, PR text, code comments, or docs (unless
  documentation about development tooling is explicitly requested).
- Never modify Git author/committer identity or `.gitconfig`.
- Never run `git commit`, `git push`, or create a pull request unless
  explicitly instructed to in that turn. Inspecting `git status`/`diff`/
  `log`/branches is always fine.
- When committing is requested, make many small, focused commits rather
  than one large batched commit — each commit should represent one
  coherent change (one PR-sized unit of work, or a clear sub-step of one),
  so the history reads as incremental engineering work over time, not a
  single generated dump.
- Comments explain non-obvious decisions (a workaround, a constraint, why
  a value was chosen), never what the code already says.
- Avoid marketing language ("robust", "comprehensive", "seamless",
  "cutting-edge", "production-ready", "enterprise-grade", "powerful",
  "scalable solution") unless the claim is demonstrated and justified.
- Don't create files, directories, docs, examples, or abstractions to make
  the repository look larger or more complete than the work that's
  actually been done.
