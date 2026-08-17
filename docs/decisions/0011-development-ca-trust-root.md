# 11. Development CA trust root lives off-cluster

## Status

Accepted

## Context

Serving Gateway routes over TLS needs a certificate authority. Three
options were evaluated for where the CA's private key lives:

- **A** — off-cluster root key, restored into the cluster by a script,
  mirroring how the SOPS age key already works.
- **B** — the CA private key committed to Git, SOPS-encrypted.
- **C** — a self-signed `Issuer` that generates its CA key inside the
  cluster, with no copy outside it.

The constraint that ruled out C first: a CA generated only inside the
cluster does not survive `cluster-down.sh`. Every certificate this
platform trusts would need reissuing after every rebuild, and every
client that had trusted the old CA would need to trust a new one —
silently, since nothing signals that the root changed.

B keeps the key alongside everything else this repository already manages,
but it puts a TLS signing key inside the same blast radius as a Git
compromise, and next to the SOPS age key it is meant to be independent of.
The Helm effectiveness audit earlier in this project already showed how a
single misconfigured value survives review; a plaintext-adjacent signing
key deserves a smaller number of things that can go wrong with it, not a
larger one.

## Decision

**Option A.** The development CA key pair is generated once, outside the
repository, at `~/.config/aegis/pki/` (overridable via `AEGIS_PKI_DIR`).
`scripts/bootstrap-pki.sh` restores it into the cluster as a
`kubernetes.io/tls` Secret that cert-manager's `Issuer` signs from.

This deliberately mirrors `scripts/bootstrap-flux.sh`'s handling of the
SOPS age key: a required local file, checked before use, restored — never
regenerated — during ordinary cluster reconstruction. The two keys are
kept as separate identities on purpose. The age key decrypts Git secrets;
this key signs TLS certificates. A compromise of one must not yield the
other, and reusing one key for both purposes would make that impossible to
reason about.

`bootstrap-pki.sh` refuses to generate a new CA if one already exists at
that path, and refuses to *restore* one if none exists — generation
(`--init`) and restoration are separate, explicit code paths, so an
operator cannot accidentally regenerate the trust root on a routine
rebuild.

## Recovery implications

- **Cluster loss, workstation intact**: `bootstrap-pki.sh` restores the
  existing CA into the rebuilt cluster. Certificates re-issue against the
  same root. Clients that already trust the CA continue to work with no
  action.
- **Workstation loss**: the CA is gone. This is accepted for a development
  platform — see Limitations below.
- **Git compromise**: the CA private key is not exposed. An attacker with
  repository write access could still change which `Issuer`/`Certificate`
  resources exist, but could not sign a certificate that this CA's
  existing trust would validate, because they do not have the key.

## Security implications

- The CA's public certificate (`ca.crt`) is not secret and is the thing
  clients trust; only `ca.key` needs protection.
- `ca.key` is written with `0600` permissions in a `0700` directory,
  generated with `umask 077` active before any file exists, and is never
  printed, logged, or placed in a command's stdout.
- The CA subject is explicitly `CN=Aegis Development Root CA` with
  `OU=Development Only`, so a certificate chain inspection cannot be
  mistaken for a real organizational or publicly trusted root.
- Compromise of the cluster does not expose the CA key: the Secret holds
  it, but nothing in the cluster needs to read it back out, and it is not
  in any ConfigMap, log, or exported resource.

## Limitations

- This is **not** a backed-up secret in the way the age key is expected to
  be. If the workstation holding `~/.config/aegis/pki/` is lost without a
  separate backup, the CA is unrecoverable and every certificate must be
  reissued from a new root, which every trusting client must then also
  re-trust. This is acceptable for a local development cluster; it would
  not be for anything beyond that.
- There is no rotation procedure for the CA itself, only for the leaf
  certificates it signs. Rotating the root is equivalent to generating a
  new one and is not automated.
- This ADR governs only the development CA's root of trust. It says
  nothing about a future home or cloud environment's PKI, which is
  explicitly out of scope here and would need its own decision.
