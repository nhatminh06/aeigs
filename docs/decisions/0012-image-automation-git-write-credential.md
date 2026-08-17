# 12. A dedicated, narrowly-scoped Git write credential for image automation

## Status

Accepted

## Context

`docs/decisions/0009-minimize-runtime-git-credentials.md` established that
no runtime Git credential is needed at all: `GitRepository/flux-system`
reads this public repository anonymously, and every controller that
reconciles cluster state only ever reads.

Flux Image Automation breaks that property by necessity. `ImageUpdateAutomation`
selects a trusted aegis-api release and commits the chosen digest back into
this repository — an operation anonymous HTTPS cannot perform. Some Git
write capability has to exist somewhere in the cluster for that to happen
at all.

Inspecting the installed `image.toolkit.fluxcd.io/v1` CRD directly (not
assumed from documentation) showed `ImageUpdateAutomation.spec` has no
credential field of its own: `spec.sourceRef` names a `GitRepository`, and
whatever that `GitRepository`'s `spec.secretRef` holds is the only
credential the automation controller ever uses, for both checkout and
push. Attaching write credentials to `GitRepository/flux-system` — the
same object every Kustomization already reads through — would put a
write-capable secret on the one object ADR 0009 specifically emptied out.

## Decision

A second, dedicated `GitRepository/aegis-api-image-writer` (`flux-system`
namespace) exists for exactly one purpose: being the `sourceRef` for
`ImageUpdateAutomation/aegis-api`. `GitRepository/flux-system` is
untouched — still no `secretRef`, still read anonymously, still what every
Kustomization uses.

The credential is a **fine-grained GitHub personal access token**, scoped
to only `nhatminh06/aeigs`, with exactly one permission: **Contents: Read
and write**. Not repository admin, not other repositories, not
organization-level access, not the classic account-wide PAT scope ADR
0009 already flagged as a problem once.

### Why a PAT and not an SSH deploy key

A repository-scoped SSH deploy key with write access was the first design
and was actually created and registered on GitHub before being reverted.
SSH turned out to be blocked in this network — confirmed empirically, not
assumed: `ssh -T git@github.com` and the documented `ssh.github.com:443`
fallback both timed out during the banner exchange, tested both from the
development workstation and from inside the cluster via a throwaway pod.
The deploy key was deleted from GitHub once this was confirmed, since an
unusable-from-this-network write-capable key sitting registered is pure
risk with no offsetting benefit. A fine-grained PAT over HTTPS was the
remaining officially-supported option, and HTTPS is confirmed working
throughout this project.

The tradeoff accepted: fine-grained PATs cannot be created via the GitHub
API or `gh` CLI — only through the web UI — so provisioning this
credential is a manual, one-time human step, unlike the deploy key which
could have been created entirely by tooling.

## Storage

Not SOPS-encrypted in Git. The age key that decrypts every `*.enc.yaml` in
this repository and the Git-write credential are kept as separate trust
domains on purpose — the same reasoning already applied to the development
CA key in `docs/decisions/0011-development-ca-trust-root.md`. Encrypting
the writer token into the repository it can write to would mean whatever
already holds the age key (Flux, at runtime) could also reach a credential
capable of pushing to that same repository, collapsing a separation this
project has otherwise been careful to keep.

Instead it is restored off-cluster, the same restore-not-regenerate shape
as the age key and the CA key: `scripts/bootstrap-image-writer.sh` reads
the token from a local file (`~/.config/aegis/git-writer/token` by
default, `0600`) and creates `Secret/aegis-api-image-writer` in
`flux-system`. Unlike the other two, there is no `--init` path that
generates this credential — fine-grained PAT creation requires the GitHub
web UI, so the one-time provisioning step happens outside any script in
this repository.

## Recovery implications

- **Cluster loss, workstation intact**: `bootstrap-image-writer.sh`
  restores the same token; image automation resumes writing with the same
  identity and scope.
- **Token expiry or revocation**: `ImageUpdateAutomation` and
  `GitRepository/aegis-api-image-writer` report a failed condition;
  `GitRepository/flux-system` and every Kustomization it drives are
  entirely unaffected, because they never reference this credential.
- **Workstation loss**: the token is gone from local storage but still
  exists on GitHub until explicitly revoked there; a fresh one can be
  generated on GitHub's side and restored the same way.

## Security impact — stated plainly

**Before this decision**: no Git write credential existed anywhere in the
cluster.

**After**: one exists, scoped to `Contents: Read and write` on exactly
`nhatminh06/aeigs`, held only in `Secret/aegis-api-image-writer`
(`flux-system` namespace), consumed only by
`GitRepository/aegis-api-image-writer` and, through it,
`ImageUpdateAutomation/aegis-api`. If that Secret is exfiltrated, the
blast radius is: commits to this one repository's `main` branch, on the
path `apps/aegis-api`, in the shape `ImageUpdateAutomation` produces. It
cannot reach any other repository, cannot modify GitHub Actions
(`workflow` scope was deliberately not granted), and cannot escalate
repository settings or collaborators.

This is not zero trust, and the automated commits it produces are not
independently verified as *correct* — only Kyverno's signature check,
downstream in the cluster, decides whether a digest that lands in Git this
way is ever actually admitted. Compromise of this credential could still
select and commit a real, validly-signed-but-unwanted release; it cannot
bypass the signature requirement itself.

## Alternatives considered

- **Classic PAT**: rejected outright — ADR 0009 already identified this
  exact problem (`repo` scope reaching every repository) and removed one.
  Reintroducing it here for a narrower purpose would be a regression.
- **GitHub App installation token**: the most granular and rotation-friendly
  option, but requires registering and installing a GitHub App — real
  operational weight for a single personal repository that a fine-grained
  PAT already covers adequately.
- **Push to a review branch instead of `main`**: considered and rejected
  for this milestone specifically because the goal is proving the full
  automated chain end-to-end (see the engineering log for this milestone).
  A review-branch model is a legitimate stronger-control alternative and
  worth revisiting if this repository's trust model changes.
