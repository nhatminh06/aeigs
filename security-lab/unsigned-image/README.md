# Lab: unsigned/wrong-identity image admission

## Objective

Confirm Kyverno's `verify-aegis-api-image` policy actually requires a
valid Cosign signature from this project's own release workflow before
admitting an `aegis-api` Pod — not merely that the policy object exists.

## Threat

Before this control, any digest under `ghcr.io/nhatminh06/aegis-api` —
signed, unsigned, or built by someone else entirely — was equally
admissible into the `aegis-api` namespace. Changing the digest in Git (or
applying a manifest directly) was sufficient to run anything.

## Control

`security/policies/verify-aegis-api-image.yaml`: a Kyverno `verifyImages`
rule scoped to `namespace: aegis-api` + `app: aegis-api`, requiring a
keyless Cosign signature whose certificate was issued by GitHub Actions'
OIDC issuer for `nhatminh06/aegis-api`'s `release.yml` workflow,
triggered by a semver tag.

## Test procedure

```
./security-lab/unsigned-image/test.sh
```

Three candidates, each `kubectl apply --dry-run=server` (nothing is ever
scheduled):

1. The currently Git-owned signed digest — expect **ALLOWED**.
2. `v0.1.0`'s digest, confirmed unsigned with `cosign verify` before use
   here — expect **DENIED**.
3. The signed release's own `linux/amd64` platform-child digest — signed
   as part of the same publish, but never itself passed to `cosign sign`
   (only the multi-platform index digest was signed) — expect **DENIED**.
   This is what proves the signature is bound to the exact digest that
   was signed, not to "the release" loosely.

## Observed result

Run on 2026-08-17, Kyverno 1.18.2, against `v0.1.2`.

```
==> signed release digest (v0.1.2 index) — expect ALLOWED
PASS: signed digest admitted

==> unsigned digest (v0.1.0) — expect DENIED
PASS: unsigned digest denied

==> unsigned platform-child digest of the signed release — expect DENIED
PASS: platform-child digest denied
```

Kyverno's actual admission error for the unsigned case:

```
verify-aegis-api-image:
  verify-aegis-api-signature: 'failed to verify image ghcr.io/nhatminh06/aegis-api@sha256:6357...:
    .attestors[0].entries[0].keyless: no signatures found'
```

## Wrong-signer identity — tested, not automated here

A fourth case was verified manually and is not part of this script: a
real Cosign signature from a *different* identity in the same repository
(`.github/workflows/wrong-signer-test.yml` instead of `release.yml`,
produced by a temporary `workflow_dispatch` workflow, removed after the
test) was attached to `v0.1.0`'s digest and admission was tested against
it. Kyverno denied it with a distinctly different error from the
unsigned case — proof it evaluates *which* signer, not only whether a
signature exists:

```
verify-aegis-api-image:
  verify-aegis-api-signature: 'failed to verify image ghcr.io/nhatminh06/aegis-api@sha256:6357...:
    .attestors[0].entries[0].keyless: subject mismatch: expected
    ^https://github\.com/nhatminh06/aegis-api/\.github/workflows/release\.yml@refs/tags/v[0-9]+\.[0-9]+\.[0-9]+$,
    received https://github.com/nhatminh06/aegis-api/.github/workflows/wrong-signer-test.yml@refs/heads/main'
```

This case is not automated because reproducing it requires signing an
artifact from a second, deliberately-untrusted GitHub Actions identity —
the temporary workflow used to do that has been removed from the
`aegis-api` repository, and the signature it produced remains attached to
`v0.1.0`'s digest in the registry (the CLI token used in this session
lacked `delete:packages` scope to remove it cleanly; noted here rather
than silently left undocumented).

## Limitation

This proves L3-level admission control — whether Kyverno lets a Pod spec
reference a given digest through. It says nothing about whether the image
content itself is safe (that is Trivy's job, upstream in the release
pipeline) or about compromise of the GitHub account/workflow that
produced a validly-signed image.
