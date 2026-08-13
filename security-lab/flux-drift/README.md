# Lab: GitOps drift correction

## Objective

Confirm that a manual, out-of-band change to a Flux-managed resource is
actually reverted automatically, and measure how long that takes in
practice.

## Threat

Kubernetes doesn't stop an operator (or an attacker with cluster access)
from running `kubectl scale`, `kubectl edit`, or `kubectl delete` directly
against a resource Git is supposed to own. If nothing reverts that, the
cluster's real state silently diverges from Git — the audit trail in Git
stops being trustworthy, and "what's actually running" becomes something
only `kubectl` can answer, not the repository.

## Vulnerable-state example

None needed — this isn't something a policy blocks (a cluster operator
legitimately needs `kubectl` access for debugging per `CLAUDE.md`'s
"manual kubectl changes are temporary debugging actions only"). The
control here is Flux reverting the change, not preventing the command.

## Expected defense

The `apps` `Kustomization` (`clusters/dev-kind/apps.yaml`, `prune: true`,
`interval: 1m`) should detect that `apps/demo-app/deployment.yaml`'s
`replicas: 1` no longer matches the live cluster state and reapply it.

## Test procedure

```
kubectl -n demo-app get deployment podinfo -o jsonpath='{.spec.replicas}'
kubectl -n demo-app scale deployment/podinfo --replicas=5
# poll until spec.replicas returns to 1
watch kubectl -n demo-app get deployment podinfo
```

## Observed result

Run against `dev-kind`:

| Timestamp (UTC)       | Event                                    |
|------------------------|-------------------------------------------|
| 2026-08-13T18:47:42Z | `kubectl scale --replicas=5` applied      |
| 2026-08-13T18:47:48Z | still 5/5 (drift persists, mid-interval)  |
| 2026-08-13T18:47:58Z | back to `spec.replicas: 1` (corrected)    |

Corrected in **16 seconds** this run. A separate run during PR 4
validation took closer to 40 seconds for the same kind of drift — both
consistent with a 1-minute poll interval and where in that window the
drift happened to land, not a fixed SLA. There's no guarantee of
sub-minute correction; only that it happens within roughly one interval.

## Remediation / what stops this

Already in place: Flux's continuous reconciliation with `prune: true`
reverts spec-level drift automatically, no human needed.

Not yet covered: this only proves reversion, not detection/alerting —
nothing currently pages anyone when drift happens, it's silently and
automatically fixed. If drift indicates something worth investigating
(e.g., a compromised credential being used to scale up a workload for
resource abuse), that's invisible today. An Alertmanager rule on
Kustomization drift events is a natural fit once Alertmanager is enabled
(currently disabled, see `docs/decisions/0004-use-helm-for-observability.md`).
