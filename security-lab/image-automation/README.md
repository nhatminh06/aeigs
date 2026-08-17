# Lab: image automation digest invariant

## Objective

Confirm that the digest `ImagePolicy` selects, the digest committed into
this repository's Git desired state, and the digest actually running in
the cluster are all the same value.

## Threat

Flux Image Automation adds a write path into this repository. If
`ImagePolicy`'s selection ever silently diverged from what's actually
committed and running — a stuck reconcile, a manual edit that automation
then fights, a partially-applied commit — Git would stop being an
accurate record of desired state without any obvious signal.

## Control

`apps/aegis-api/imagepolicy.yaml`, `apps/aegis-api/imageupdateautomation.yaml`.
This lab does not add a control; it verifies one already in place.

## Test procedure

```
./security-lab/image-automation/test.sh
```

Reads `ImagePolicy/aegis-api`'s `status.latestRef.digest` and the live
`Deployment/aegis-api`'s image digest, and fails if they differ.

## What this does not check

Whether the agreed-upon digest is *trusted* — that's
`security-lab/unsigned-image/test.sh` and
`security/policies/verify-aegis-api-image.yaml`. This lab only proves the
three views agree; Kyverno is what makes "agree" also mean "safe to run".

## Observed result

Run on 2026-08-17, after `ImageUpdateAutomation` committed the v0.1.3
digest and Flux reconciled it live:

```
ImagePolicy selected digest : sha256:b0845756fb57e3e37083da69b181df5dd89eca804c48dcd016e3c1a8df54ab4c
Live Deployment digest      : sha256:b0845756fb57e3e37083da69b181df5dd89eca804c48dcd016e3c1a8df54ab4c
PASS: ImagePolicy selection and live Deployment digest agree
```
