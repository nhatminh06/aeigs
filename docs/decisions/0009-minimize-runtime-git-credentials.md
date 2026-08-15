# 9. Minimize the runtime Git credential Flux holds

## Status

Accepted

## Context

Flux was originally bootstrapped over SSH, then re-bootstrapped over
HTTPS with a GitHub token (`--token-auth`) once this network turned out
to block the SSH protocol entirely (see the README's bootstrap section).
`flux bootstrap github --token-auth` wires that same token into
`GitRepository.spec.secretRef` — not just for the bootstrap operation
itself, but as the ongoing runtime credential `source-controller` uses
for every fetch, on a 1-minute interval, indefinitely.

This repository is public, and the token in question turned out not to
be scoped to it at all. Checking the live Secret's actual GitHub-reported
scopes (via the `X-OAuth-Scopes` response header, without ever printing
the token itself) showed `gist, read:org, repo, workflow` — the same
broad personal-access-token scopes as the `gh auth token` used
interactively for bootstrap, confirmed by comparing against `gh auth
status` in the same environment. `repo` alone grants read/write to every
repository the account can reach, public and private; `workflow` can
modify GitHub Actions; none of that is needed to read one public repo.

## Problem

If `source-controller`, another controller in the `flux-system`
namespace, or any identity with Secret-read access there is compromised,
the blast radius extends to whatever that token can reach on GitHub —
not just this repository, and not just read access.

## Decision

Distinguish **bootstrap credential** from **runtime credential**:

- Bootstrap (`flux bootstrap github --token-auth`) still needs a token —
  it writes commits and creates the deploy setup via the GitHub API,
  which anonymous access can't do.
- Runtime reads (`GitRepository.spec.secretRef`, used by
  `source-controller` every interval) don't need one for a public repo.
  `gotk-sync.yaml`'s `GitRepository` no longer references `secretRef`.

## Verification (not assumed)

- **Anonymous read, outside the cluster**: `git ls-remote
  https://github.com/nhatminh06/aeigs.git` with `credential.helper`
  explicitly cleared and `GIT_TERMINAL_PROMPT=0` succeeded, returning the
  correct `HEAD`/`main` SHA. A bare `curl` to the smart-HTTP
  `info/refs?service=git-upload-pack` endpoint (no Git credential
  machinery involved at all) returned `200`.
- **Anonymous read, live in-cluster**: with the `flux-system`
  Kustomization suspended (so it couldn't revert the test), the live
  `GitRepository/flux-system` was patched to remove `secretRef`, then
  `source-controller` was forced to reconcile twice independently — both
  fetched the correct revision successfully.
- **Secret no longer needed at all**: with `secretRef` still removed, the
  `flux-system` Secret itself was deleted from the live cluster and
  reconciliation was forced again — it still succeeded. Every
  `Kustomization` (`apps`, `flux-system`, `identity`, `kyverno`,
  `kyverno-policies`, `observability`) remained `Ready=True` throughout,
  and no pod in the cluster was affected.

## Consequences

- If this repository is ever made private, `secretRef` needs to come
  back — anonymous HTTPS won't work anymore. That's a deliberate, visible
  config change at that point, not a silent gap.
- `flux bootstrap` re-runs regenerate `gotk-sync.yaml` with `secretRef`
  wired back in by default (same as the reconcile-interval override
  already documented in that file) — remove it again after any future
  bootstrap re-run.
- The `flux-system` Secret (the token, plus unused leftover SSH keypair
  material from the original bootstrap attempt) was deleted from the live
  `dev-kind` cluster as part of validating this change — it was already
  fully unreferenced at that point, and this is a disposable dev cluster
  that gets rebuilt from Git plus documented bootstrap commands anyway.
  On a cluster where this deletion hasn't happened yet, it's a safe
  manual cleanup once this change has reconciled:
  `kubectl -n flux-system delete secret flux-system`.

## Future private-repository case

Not implemented here, but worth naming: if Aegis ever becomes a private
repository, options for a properly-scoped runtime credential include a
deploy key (read-only, repo-scoped), a narrowly-scoped GitHub App
installation token, or a fine-grained personal access token limited to
this one repository's contents. Any of those would be a smaller runtime
credential than the current bootstrap PAT, but none are needed while the
repository stays public.
