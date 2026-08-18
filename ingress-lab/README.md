# Ingress datapath isolation lab

A regression lab, not production infrastructure — it exists to cheaply
re-run one comparison: does an ordinary reverse-proxy workload reach
`aegis-api` on `home-k3s` when Cilium's Gateway API cannot? See
`docs/decisions/0014-home-k3s-gateway-blocked-by-cilium-ingress-identity-bug.md`'s
addendum for the full result and the traffic comparison table.

## What it proves

`home-k3s`'s Cilium Gateway times out every request
(`docs/decisions/0014-...md`): connections tagged with Cilium's
`reserved:ingress` identity get a SYN-ACK back from the backend pod but
never complete the TCP handshake. This lab answers whether that's
specific to the Gateway/`reserved:ingress` datapath, or a more general
same-node/NodePort forwarding problem on this host — by proxying the
same paths (`/healthz`, `/readyz`, `/api/v1/`) through an ordinary
`nginx` Deployment instead, first pod-to-pod, then via a plain K3s
`NodePort`.

Deliberately excluded, so a positive result doesn't get mistaken for a
finished ingress solution: no TLS, no cert-manager, no
Prometheus/Grafana, no Authentik, no MetalLB/Traefik/ingress-nginx.
Adopting any of those as `home-k3s`'s real ingress mechanism is a
separate architecture decision this lab does not make.

## Running it

```
export AEGIS_HOME_K3S_KUBECONFIG=~/.kube/home-k3s.yaml   # defaults shown
export AEGIS_HOME_K3S_CONTEXT=home-k3s
./test.sh          # applies, tests pod-to-pod, patches to NodePort, tears down
./test.sh --keep   # leaves ingress-lab live for manual external testing
```

The script prints the assigned `NodePort` and a sample `curl` command
for the external-exposure check; that part is manual since it needs to
run from wherever "external" means for the check being done (an SSH
session on `cachyos` itself, another LAN host, etc.), not from the
machine driving the script.

Capturing the Cilium identity/handshake evidence (the actual point of
this lab) is not scripted — it's a short, interactive
`cilium-dbg monitor --type trace` capture run alongside a test request,
same as `docs/decisions/0014-...md`'s own investigation. See that
document for the exact commands used and their output.

## Cleanup

`./test.sh` (without `--keep`) tears down everything itself via a
`trap ... EXIT`, including the `ingress-lab` namespace. If a previous
run was left with `--keep`, remove it manually:

```
kubectl delete -k manifests/
```

Verify with `kubectl get all -n ingress-lab` (expect: nothing) and
`kubectl get ns ingress-lab` (expect: not found).
