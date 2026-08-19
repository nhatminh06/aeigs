# Runbook: home-k3s nginx TLS certificate reload

Applies to `infrastructure/ingress/home-k3s/` (`ingress-nginx` Deployment).

## The finding

`cert-manager` updates the `api-tls`/`grafana-tls`/`auth-tls` Secrets
automatically on renewal. Those Secrets are mounted into the nginx Pod as
volumes, and Kubernetes' own secret-volume sync updates the files on disk
within roughly a minute of the Secret changing — no action needed for
that part. What does **not** happen automatically: nginx's worker
processes read each certificate file once at startup (or at an explicit
`nginx -s reload`) and keep it in memory. A changed file on disk does not
make a running nginx process start serving the new certificate; it keeps
serving the old one until reloaded or restarted.

Confirmed live (2026-08-19): TLS Secret cert serial and the serial nginx
actually serves matched exactly at check time (no drift, since nothing
had reissued recently) — this documents the *mechanism*, not a live
incident.

## Decision: accept manual reload, do not add a sidecar

Evaluated one credential-free automatic option: a `shareProcessNamespace:
true` sidecar container in the same Pod that watches the mounted Secret
volumes (`inotifywait` or a poll loop) and signals the nginx process to
reload. This genuinely needs no Kubernetes API access, no ServiceAccount
token, no RBAC grant — the file already updates via the ordinary secret
volume sync; the sidecar only needs to see and signal a process in the
same Pod.

**Not implemented**, for these reasons:

- `shareProcessNamespace: true` weakens the process-level isolation
  between the nginx container and the sidecar within the Pod — each can
  see and signal the other's processes. This is a real, if modest,
  security tradeoff, not a free win.
- The problem it solves is rare: cert-manager renews well before
  expiry, not continuously, and this is a single-operator development
  environment where a reissue is a deliberate, infrequent event, not
  something that needs zero-touch handling.
- The manual fix is simple, fast, and already uses a clean mechanism (a
  Deployment rollout, not a raw Pod delete — see below).

This matches the milestone's own default bias: don't add infrastructure
to eliminate a rare, development-only manual step when a simple safe
solution isn't genuinely free.

## Manual reload procedure

```
kubectl -n ingress-system rollout restart deployment/ingress-nginx
kubectl -n ingress-system rollout status deployment/ingress-nginx
```

`rollout restart`, not `kubectl delete pod` — it goes through the
Deployment controller's normal rolling-update path (create new Pod, wait
for readiness, terminate old Pod), which is safer and more predictable
than deleting the single replica directly and hoping the replacement
comes up cleanly. With `replicas: 1` there is a brief gap in service
while the new Pod becomes ready — this is a real, accepted downtime
window, not eliminated by this procedure.

After reload, confirm the new certificate is actually being served:

```
echo | openssl s_client -connect <node-ip>:30443 -servername auth.aegis.home.arpa 2>/dev/null | openssl x509 -noout -serial
```

Compare against the Secret's own serial
(`kubectl -n ingress-system get secret auth-tls -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -noout -serial`)
— they should match after the reload; they may not before it.

## When to revisit this decision

If nginx ever needs a real availability requirement (more than one
replica, expectation of zero-touch operation), or if manual reloads are
missed often enough to cause real expired-cert incidents, that's new
evidence — revisit then, not preemptively.
