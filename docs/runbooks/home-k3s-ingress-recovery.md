# Runbook: home-k3s ingress recovery

Applies to the permanent nginx ingress on `home-k3s`
(`infrastructure/ingress/home-k3s/`) — see
`docs/decisions/0015-home-k3s-nginx-ingress.md` for why it exists and
`docs/decisions/0014-home-k3s-gateway-blocked-by-cilium-ingress-identity-bug.md`
for why Cilium's Gateway API is not used instead.

## DNS

No DNS platform is installed. `api.aegis.home.arpa` and
`grafana.aegis.home.arpa` resolve only via a client-side override —
either `curl --resolve <host>:<port>:<node-IP>` (used throughout
testing, no `/etc/hosts` edit needed) or an explicit `/etc/hosts` entry
an operator adds themselves:

```
192.168.1.16   api.aegis.home.arpa grafana.aegis.home.arpa
```

Reachable at the node's LAN IP (`192.168.1.16` at the time of writing —
`kubectl get nodes -o wide`) on ports `30080` (HTTP, redirects) and
`30443` (HTTPS).

## Health checks, in order

1. **Deployment**: `kubectl -n ingress-system get pods` — `1/1
   Running`.
2. **Service/NodePort**: `kubectl -n ingress-system get svc
   ingress-nginx` — ports `8080:30080/TCP,8443:30443/TCP`.
3. **cert-manager**: `kubectl -n ingress-system get issuer,certificate`
   — `aegis-dev-ca` Issuer `Ready`, `api-tls`/`grafana-tls`
   Certificates `Ready`.
4. **HTTP**: `curl -H "Host: api.aegis.home.arpa"
   http://<node-IP>:30080/healthz` → `301` to HTTPS.
5. **HTTPS**: `curl -k -H "Host: api.aegis.home.arpa"
   https://<node-IP>:30443/healthz` → `200`. Add `--cacert
   ~/.config/aegis/pki/ca.crt` (drop `-k`) to verify trust, not just
   reachability.
6. **Unknown host**: any other `Host` header → `404` (the
   `default_server` block in `configmap.yaml`).
7. **`/metrics`**: must return `404` externally — it is not routed.
   Prometheus reaches it directly via the Service, checked separately.

## Common situations

**Certificates show `Ready` but the ingress serves an old/expired
one.** nginx does not reload its in-memory certificate when
cert-manager rotates the Secret — the mounted file updates, but nginx
keeps using what it loaded at startup. Reload it:

```
kubectl -n ingress-system exec deploy/ingress-nginx -- nginx -s reload
```

or `kubectl -n ingress-system rollout restart deployment/ingress-nginx`
for a full pod restart. This is expected behavior, not a bug — see the
ADR's "Consequences" section.

**Grafana or aegis-api route 404s but the Certificate/Issuer are
healthy.** The route lives in `configmap.yaml`, not a CRD — check the
ConfigMap actually contains the expected `server_name` block
(`kubectl -n ingress-system get cm ingress-nginx-conf -o yaml`) and
that the pod picked it up (a ConfigMap change alone does **not**
restart the pod — same gotcha as Cilium's own ConfigMap, see ADR
0013's addendum; only a Deployment spec change or manual restart makes
nginx reread it).

**`kubectl create secret ... --cacert` restore needed after empty-host
reconstruction.** Run `scripts/bootstrap-pki-home-k3s.sh` before
expecting the Issuer to reach `Ready` — it restores the *existing*
development CA from `~/.config/aegis/pki/`, never generates a new one.
See `docs/runbooks/home-k3s-recovery.md` for the full reconstruction
sequence this fits into.

**NetworkPolicy denies the ingress itself.**
`apps/aegis-api/home-k3s/networkpolicy.yaml` allows exactly two
sources on port 8080: `ingress-system/ingress-nginx` (by pod label
`app: ingress-nginx`) and `observability`'s Prometheus (by pod label
`app.kubernetes.io/name: prometheus`). Anything else — including a
future Grafana-to-aegis-api path, if one is ever added — needs an
explicit policy change, not silent traffic.

## What NOT to do

- Don't reintroduce Cilium's `Gateway`/`HTTPRoute` objects for
  `aegis-api` without first re-running `ingress-lab/` against whatever
  Cilium version is in use — that broken path is exactly what this
  ingress replaced.
- Don't add MetalLB/ingress-nginx-as-a-controller/Traefik "to fix a
  routing quirk" — a ConfigMap edit handles it; see ADR 0015 for why an
  ingress controller was deliberately not adopted here.
- Don't hand-edit the live ConfigMap or Deployment with `kubectl
  edit`/`patch` for anything meant to persist — Flux prunes it back on
  the next reconcile (interval `1m`). Change the file in Git.
