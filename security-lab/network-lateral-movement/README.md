# Lab: network lateral movement

## Objective

Confirm an unrelated workload cannot reach the Authentik PostgreSQL
database, server, or worker, while the components that legitimately need
them still can.

## Threat

Before this control, the cluster network was flat: any pod in any
namespace could open a TCP connection to the identity database. A single
compromised workload — a vulnerable dependency in an unrelated app, a
malicious image — could attempt to reach the credential store directly,
without touching Authentik itself.

## Control

Two `networking.k8s.io/v1` NetworkPolicies, enforced by Cilium:

- `security/authentik/networkpolicy-postgresql.yaml` — PostgreSQL accepts
  5432/TCP only from the Authentik server and worker.
- `security/authentik/networkpolicy-server.yaml` — the server accepts
  9000/TCP only from the Grafana pod, which makes the OIDC `token_url` and
  `api_url` calls.
- `security/authentik/networkpolicy-worker.yaml` — the worker accepts no
  ingress at all; nothing in the platform connects to it.

One detail matters more than the policy itself: the Bitnami PostgreSQL
subchart ships its **own** NetworkPolicy that allows 5432 `From: <any>`.
NetworkPolicies are additive — the union of all matching policies is
allowed — so that permissive policy silently cancelled this one out. It is
disabled via `postgresql.networkPolicy.enabled: false` in the HelmRelease.
Adding a restrictive policy is not enough if something else already allows
the traffic.

## Test procedure

```
./security-lab/network-lateral-movement/test.sh
```

The script starts short-lived `busybox` pods in `demo-app` and attempts
`nc -z` against the database and server Service DNS names, plus the worker
by pod IP — no Service selects the worker, so its IP is resolved by label
selector at runtime rather than hard-coded. `nc` exits non-zero when the
connection is refused or times out, so the check is inverted: a
*successful* connection is the failure case. The probe is removed by a
`trap ... EXIT`.

Only the attacker paths are automated. Verifying the legitimate flows
automatically would mean putting database credentials and a valid OAuth
code into a probe pod; those are instead confirmed from real application
traffic in Hubble, recorded below.

## Expected result

The probe cannot connect, and Hubble records the drop as a policy verdict
rather than a timeout.

## Observed result

Run on 2026-08-16, Cilium 1.20.0.

Attacker path, before the policy:

```
demo-app/pgprobe:34883 -> authentik/authentik-postgresql-0:5432
  policy-verdict:L4-Only INGRESS ALLOWED (TCP Flags: SYN)
```

Attacker path, after the policy:

```
demo-app/pgdrop:32953 <> authentik/authentik-postgresql-0:5432
  policy-verdict:none INGRESS DENIED / Policy denied DROPPED

demo-app/srvdrop:45772 <> authentik/authentik-server-...:9000
  policy-verdict:none INGRESS DENIED / Policy denied DROPPED

demo-app/wdrop:33113 <> authentik/authentik-worker-...:9000
  policy-verdict:none INGRESS DENIED / Policy denied DROPPED
```

The worker is worth testing precisely because it looks unreachable: it has
no Service. It nonetheless listens on 9000 and 9300, and pod IPs are
routable, so `demo-app` reached both before the policy existed.

Grafana, the one permitted server source, is explicitly allowed:

```
observability/kube-prometheus-stack-grafana-...:39010 -> authentik/authentik-server-...:9000
  policy-verdict:L3-L4 INGRESS ALLOWED
```

Legitimate paths, after the policy — both still forwarded, and Authentik's
DB-backed readiness endpoint returns HTTP 200:

```
authentik/authentik-server-... -> authentik/authentik-postgresql-0:5432 to-endpoint FORWARDED
authentik/authentik-worker-... -> authentik/authentik-postgresql-0:5432 to-endpoint FORWARDED
```

The lab was also run with each policy deleted in turn. With the server
policy removed it reported `FAIL: demo-app reached
authentik-server.authentik.svc.cluster.local:80` and exited 1; with the
policy restored it exited 0. It detects the control disappearing, not just
its own logic.

## Limitation

This covers three ingress paths: PostgreSQL:5432, server:9000 and
worker:9000. It does not cover egress from any of them, and it checks only
one of the worker's two listening ports (9300 is blocked by the same
deny-all rule, verified manually).

It also cannot test user access. Cilium does not apply pod ingress policy
to traffic from the node, so `kubectl port-forward` still reaches the
server after enforcement — that is expected, and it means these policies
govern pod-to-pod reachability, not who can log in.

It also tests L3/L4 reachability only. It says nothing about whether a
workload that *is* allowed to reach the database is authorised to read
anything from it.
