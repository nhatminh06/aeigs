# 10. Bootstrap Cilium outside Flux

## Status

Accepted

## Context

Replacing kind's default CNI (kindnet) with Cilium means the cluster has
no pod network between `kind create cluster` and the CNI being installed.
The node stays `NotReady` and CoreDNS stays `Pending` during that window.

Every other component in this repository is installed by Flux from Git.
Doing the same for Cilium looks consistent, but inverts a dependency:
Flux's controllers are pods that need a working pod network and DNS to
reconcile anything at all. They cannot install the thing they run on.

## Decision

Install Cilium from `scripts/bootstrap-cilium.sh`, before Flux, using
Helm with the chart version pinned in the script. Flux does not manage
Cilium — there is no HelmRelease for it.

Bootstrap order is now:

```
scripts/cluster-up.sh        kind cluster, no CNI, node NotReady
scripts/bootstrap-cilium.sh  Cilium -> node Ready, DNS working
scripts/bootstrap-flux.sh    Flux -> everything else from Git
```

Cilium 1.20.0 was chosen because it is the only stable line that lists
Kubernetes 1.36 — this repository's pinned baseline — as e2e tested.
Cilium 1.19 covers 1.31–1.34. This was a compatibility constraint, not a
preference for the newest release.

## Alternatives considered

**Flux owns Cilium after an initial manual install.** Rejected for now.
It reads as more GitOps-consistent, but consider the failure case: Flux
reconciles a bad Cilium upgrade, the CNI breaks, pod networking goes with
it, and the controller that would roll the change back has just lost the
network it needs to fetch Git. Recovery would mean manual intervention in
exactly the situation where automation was supposed to help. The blast
radius of that failure is the whole cluster, and the upside is avoiding
one command during a rebuild.

**Cilium's kube-proxy replacement.** Not enabled. kube-proxy is left in
place. That is a separate change with its own failure modes and should be
evaluated on its own, not bundled into the CNI migration.

## Consequences

- Cilium's version lives in a script rather than a reconciled manifest.
  It is still pinned and still in Git, but Flux will not correct drift if
  someone upgrades Cilium by hand on a running cluster. On a disposable
  `kind` cluster the answer to drift is to rebuild.
- Rebuilds are three commands instead of two.
- Rollback is a rebuild: `cluster-down.sh` then the three bootstrap steps.
  Because the cluster is disposable and all state comes from Git plus the
  age key, this is cheap and does not depend on Cilium being healthy — the
  property the rejected alternative would have given up.
- This decision is scoped to `dev-kind`. A persistent cluster, where
  rebuilding is not cheap, will need this revisited rather than copied.

## Addendum: when a Cilium-specific policy is allowed

Choosing Cilium also means choosing what to do when its behaviour is not
expressible in portable APIs. The rule adopted here:

**Use `networking.k8s.io/v1` NetworkPolicy by default. Use
`CiliumNetworkPolicy` only where a required peer or capability cannot be
expressed portably, and record the specific reason next to the policy.**

There is exactly one such exception today. Cilium's Gateway proxies through
Envoy, and Envoy opens the backend connection under the `reserved:ingress`
identity rather than as a pod. That identity is assigned by the proxy
datapath, so no `podSelector`, `namespaceSelector` or `ipBlock` matches it —
an `ipBlock` for the observed source address was tested and the traffic was
still dropped. Without a rule for it, `auth.aegis.test` returned 503 while
Envoy's SYNs were dropped; `fromEntities: [ingress]` in
`security/authentik/ciliumnetworkpolicy-server-gateway.yaml` resolved it,
and removing the policy reproduced the 503.

The portable server policy was deliberately kept rather than folded into the
Cilium one, so the vendor-specific surface stays one rule for one peer and
the readable policy stays portable. The cost is real: this policy will not
survive a move to another CNI, and that is the trade accepted for using
Cilium's own Gateway rather than adding a second ingress implementation.
