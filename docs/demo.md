# Demo: a 5–10 minute walkthrough

A deterministic, **read-only** walkthrough of the live home-k3s
environment. Nothing here mutates cluster state, deletes anything, prints
a secret, or requires a long wait. For the deeper destructive-recovery
proofs (PVC/PV destruction, host reboot, K3s rollback), read the linked
runbooks instead of re-running them live — those are one-way experiments,
not demo material.

Assumes `KUBECONFIG` points at `home-k3s` and you're on the same network
(or over the Tailscale path this project uses).

## 1. Flux health

```
export KUBECONFIG=~/.kube/home-k3s.yaml
flux get kustomizations
```

Expect all 9 Kustomizations `Ready=True`, all at the same Git revision —
proof that every layer (Authentik, cert-manager, ingress, Kyverno,
observability, stateful-lab, aegis-api) is reconciled from the same
commit.

## 2. HTTPS aegis-api

```
curl -sk -H "Host: api.aegis.home.arpa" https://<node-ip>:30443/healthz
curl -sk -H "Host: api.aegis.home.arpa" https://<node-ip>:30443/api/v1/info
```

Expect `200` and a small JSON body. Add `--cacert
~/.config/aegis/pki/ca.crt` (drop `-k`) to show the connection is
genuinely trust-verified against the development CA, not just
`-k`-ignored.

## 3. Grafana

Open `https://grafana.aegis.home.arpa:30443` in a browser (import the
development CA first, or accept the browser warning). Show the
dashboards under kube-prometheus-stack — node/pod resource usage and, if
still present, the `aegis-api` SLO panels from the reliability-lab
experiment.

## 4. Authentik login

From Grafana's login page, click "Sign in with Authentik" and complete
the OIDC flow. This demonstrates the identity stack live — Authentik
issuing a token, Grafana accepting it — without touching credentials in
the terminal.

## 5. Signed image admission

```
kubectl apply --dry-run=server -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: demo-signed-check
  namespace: aegis-api
  labels:
    app: aegis-api
spec:
  containers:
    - name: aegis-api
      image: ghcr.io/nhatminh06/aegis-api:v0.1.5@sha256:71404813fa3521ebbb1ff25ae2e8ab67613ab40f6939612c9af775db3c044e77
EOF
```

Expect `pod/demo-signed-check created (server dry run)` — the real,
currently-running signed digest is admitted. To show a denial instead,
substitute any digest under the same image path that was never signed —
Kyverno's error names the exact Sigstore verification failure.

## 6. NetworkPolicy attacker test

```
kubectl -n aegis-api run demo-attacker -i --rm --restart=Never \
  --image=busybox:1.36 --command --timeout=10s -- \
  sh -c 'nc -zv -w3 authentik-postgresql.authentik.svc.cluster.local 5432; echo EXIT:$?'
```

Expect a connection timeout and `EXIT:1` — an unrelated workload cannot
reach Authentik's database, enforced by NetworkPolicy, not assumed from
the YAML.

## 7. Backup status

```
./scripts/backup-status.sh
```

Expect `stateful-lab: HEALTHY` and `authentik: HEALTHY`, each reporting
its own last-backup and last-restore-verification age independently —
one family's health never hides the other's.

## 8. Recovery evidence

Point to, rather than re-run:

- [`docs/runbooks/home-k3s-authentik.md`](runbooks/home-k3s-authentik.md#destructive-identity-recovery)
  — destructive PostgreSQL restore with the same identity UUID returned
- [`docs/decisions/0014-home-k3s-gateway-blocked-by-cilium-ingress-identity-bug.md`](decisions/0014-home-k3s-gateway-blocked-by-cilium-ingress-identity-bug.md)
  — the Cilium Gateway datapath investigation, with live `cilium-dbg`
  capture evidence
- [`docs/runbooks/aegis-api-bad-release.md`](runbooks/aegis-api-bad-release.md)
  — the signed-but-bad release incident timeline

## Notes for whoever is watching

- Every step above is safe to re-run; nothing here is destroyed or
  rebuilt.
- If asked "what happens if you actually destroy the database" — that's
  the [identity recovery story](../README.md#the-identity-recovery-story)
  in the README, proven once, deliberately not repeated live in a demo.
