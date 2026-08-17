# Architecture

Current state of the `dev-kind` environment. `architecture.png` predates
Authentik and the credential/bootstrap changes; this file is the accurate
version and the one to update as the platform changes.

## Runtime

```
  operator                          github.com/nhatminh06/aeigs (public)
     |                                          ^
     | scripts/cluster-up.sh                    | anonymous HTTPS, read-only
     v                                          | (no credential in cluster)
  kind: aegis-dev                               |
  kindest/node v1.36.1, pinned by digest        |
  default CNI disabled                          |
     |                                          |
     | scripts/bootstrap-cilium.sh              |
     |   Cilium 1.20.0 -> node Ready, DNS up    |
     |   + Hubble Relay (flow observability)    |
     |   (before Flux: Flux needs a pod network)|
     |                                          |
     | scripts/bootstrap-flux.sh                |
     |   applies committed flux-system/         |
     v                                          |
  Flux v2.9.4 controllers  ------ GitRepository/flux-system
     |                                   |
     |                                   v
     |                        Kustomization/flux-system (root, 1m)
     |                                   |
     |            +----------------+-----+------+----------------+
     |            v                v            v                v
     |         apps          observability   kyverno          identity
     |       (podinfo)      (Prometheus,    + kyverno-      (Authentik +
     |                       Grafana)        policies        Postgres)
     |                                          |                |
     v                                          |                v
  Kubernetes API  <---- admission control ------+          Grafana OIDC
```

Kyverno enforces admission on everything Flux applies; Authentik is the
OIDC provider Grafana authenticates against.

## Network observability

```
  Cilium agent (per node)
     |-- dataplane: pod networking, service translation
     +-- Hubble server (on by default, node-local socket)
              |
              v
        Hubble Relay  ---- one cluster-wide flow API
              |
              v
        hubble CLI (ships inside the agent image)
              |
              v
        docs/network/traffic-inventory.md
```

The inventory produced the first enforcement control:

```
  traffic inventory (evidence)
          |
          v
  Kubernetes NetworkPolicy  (security/authentik/networkpolicy-*.yaml)
          |
          +--> PostgreSQL ingress:  server + worker -> 5432 allowed
          |                         everything else denied
          |
          +--> server ingress:      grafana -> 9000 allowed (OIDC backend)
          |                         everything else denied
          |
          +--> worker ingress:      deny all (nothing connects to it,
                                    but it listens on 9000/9300)
```

Ingress arrives through Gateway API, and its peer is not a pod:

```
  external client
        |
        v
  Cilium Gateway / Envoy   (host network, kind forwards host :80)
        |
        |  backend connection is opened under the
        |  reserved:ingress identity, NOT as a pod
        v
  CiliumNetworkPolicy      (security/authentik/ciliumnetworkpolicy-server-gateway.yaml)
        |  reserved:ingress -> authentik-server:9000
        v
  Authentik server

  Grafana pod
        |
        v
  Kubernetes NetworkPolicy (security/authentik/networkpolicy-server.yaml)
        |  grafana -> authentik-server:9000
        v
  Authentik server
```

The two policies union to exactly those two peers. The split is deliberate:
portable `networking.k8s.io/v1` NetworkPolicy expresses every workload peer,
and the one vendor-specific policy exists only because `reserved:ingress` is
assigned by Cilium's proxy datapath and cannot be selected by a
`podSelector`, `namespaceSelector` or `ipBlock`. This is how this Cilium
version presents Gateway backend traffic — it is not a general property of
Gateway API.

Node-originated traffic (kubelet probes, `kubectl port-forward`) is not
subject to pod ingress policy in Cilium, so these boundaries govern
pod-to-pod and Gateway access, not user access. Every other observed flow
remains allowed: there is no namespace-wide default deny and no egress
policy. Hubble UI and Hubble Prometheus metrics are not enabled.

## Secrets

The age private key is the one input that cannot be rebuilt from Git.

```
  age private key (off-cluster backup)
     |
     | bootstrap-flux.sh verifies its public half
     |   matches the recipient in .sops.yaml, then creates:
     v
  Secret/sops-age  (flux-system)
     |
     v
  Flux decrypts *.enc.yaml during reconciliation
     (apps, observability, identity)
```

## Repository controls

```
  push / pull request
     |
     v
  .github/workflows/repo-security.yml
     |-- gitleaks              committed secrets (full history)
     |-- trivy-config          manifest misconfiguration
     |-- kyverno-policy-test   policy regression tests
     |-- kustomize-build       GitOps composition builds
     +-- renovate-config       renovate.json is valid

  Renovate (Mend-hosted app)
     |
     v
  dependency update PR -> same CI gates -> human review -> main -> Flux
```

None of these gates catch a Helm value that the chart never reads.

## Configured Helm value is not consumed Helm value

Helm accepts unknown values silently. A misplaced key is present in
`helm get values`, survives every check above, and does nothing. This has
happened twice here:

- `postgresql.networkPolicy.enabled` sat one level above the key the chart
  tests (`primary.networkPolicy.enabled`), so a permissive database
  NetworkPolicy kept rendering.
- `disable_login_form` sat in `[auth.generic_oauth]`, a section Grafana does
  not read it from, so a login safeguard did nothing.

Neither failed visibly. The first was masked by a hand-deleted resource; the
second matched Grafana's default anyway. Schema validation does not close
this: of the four charts in use only Cilium ships `values.schema.json`, and
it accepted a deliberately bogus key in testing.

So for a value that carries a security or reliability claim, verify against
the pinned chart rather than the API server's acceptance of it:

```
  helm pull <repo>/<chart> --version <pinned> --untar
  helm template <name> ./<chart> -f <values> | <check the resource changed>
```

Toggle the value both ways. The evidence is the rendered resource appearing
or disappearing, not the value showing up in `helm get values`.

## TLS and identity

```
  scripts/bootstrap-pki.sh
     |-- restores the Aegis development CA (off-cluster key, never in Git)
     +-- creates Secret/aegis-dev-ca in the gateway namespace
              |
              v
  cert-manager (Flux-owned HelmRelease, v1.21.1 — the only line
                supporting Kubernetes 1.36)
     |-- Issuer/aegis-dev-ca reads that Secret
     +-- Certificate/grafana-tls, Certificate/auth-tls
              |
              v
  Gateway aegis: https-grafana, https-auth listeners (TLS terminate)
     +-- http listener now redirects (301) to the matching HTTPS host
```

Why the CA key is not in Git, and why it is not the SOPS age key reused for
a second purpose, is `docs/decisions/0011-development-ca-trust-root.md`.
One certificate per hostname, not one SAN certificate for both: a reissue
or a mistake in one does not touch the other, proven live by rotating
`grafana-tls` and confirming `auth-tls`'s serial was unchanged.

Grafana's browser-facing OAuth URLs (`root_url`, `auth_url`) point at the
HTTPS Gateway hostnames; its server-side calls (`token_url`, `api_url`)
stay on cluster-internal Service DNS rather than following the browser to
`auth.aegis.test` — routing them through the Gateway would mean Grafana
also has to trust the development CA for no operational benefit, since the
NetworkPolicy path there already exists and is already tested. See
`docs/network/traffic-inventory.md`'s "HTTPS and the OIDC path" section for
the full request path and live evidence, including a real browser login.

## Owned application supply chain

```
github.com/nhatminh06/aegis-api release.yml (tag push only)
        |
        |-- Trivy scan (linux/amd64 + linux/arm64), fails on HIGH/CRITICAL
        |-- Syft SBOM per platform, SPDX JSON, attached as Cosign
        |     attestations on the digest (durable, independent of the run)
        |-- Cosign keyless signature on the exact digest (GitHub Actions
        |     OIDC -> Fulcio short-lived cert -> Rekor), verified with
        |     issuer + identity constraints in the same job
        v
   same digest promoted to the release tag — never a rebuild
        |
        v
   apps/aegis-api/deployment.yaml (this repo, digest-pinned)
        |
        v
   Kyverno verify-aegis-api-image
        |-- namespace: aegis-api, app: aegis-api only
        |-- requires issuer https://token.actions.githubusercontent.com
        |-- requires subject matching .../workflows/release.yml@refs/tags/v*
        v
   admitted -> Kubernetes
```

Scoped narrowly on purpose: no other workload on this platform is
affected, and this does not claim the image is vulnerability-free, that
the source is trustworthy under every compromise scenario, or that a
compromised GitHub account could not produce a validly-signed image.
Verification depends on live connectivity to GHCR and Sigstore's
Fulcio/Rekor — both at admission time and during Kyverno's background
re-scan.

## Not present yet

Namespace-wide default deny, egress policy, and L7 policy (only the
ingress boundaries above are enforced), Flux Image Automation (release
selection into Git is a manual step), and any persistent cluster. The
development CA is trusted only by clients that explicitly import it —
this is not a publicly trusted certificate and must not be described as
one. Nothing above should be read as implying those exist.
