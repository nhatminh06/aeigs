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

## Not present yet

Namespace-wide default deny, egress policy, and L7 policy (only the three
ingress boundaries above are enforced), Gateway/TLS ingress (access is via
`kubectl port-forward`), image signing/verification, and any persistent
cluster. Nothing above should be read as implying those exist.
