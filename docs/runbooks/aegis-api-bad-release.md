# Runbook: aegis-api signed-but-bad release

Applies when a new `aegis-api` release has passed the full supply chain
(tests, Trivy, SBOM, Cosign, Kyverno) and been automatically deployed by
Flux Image Automation, but the application itself is misbehaving. This is
the scenario `v0.1.4` was deliberately built to exercise — see
`reliability-lab/aegis-api-slo/README.md` for the lab this runbook backs.

**Core lesson: Cosign + Kyverno prove an artifact's provenance and
identity. They prove nothing about whether the code inside it is
correct.** A image can be genuinely, verifiably built by this project's
own pipeline and still be a bad release.

## Symptoms

- `AegisApiLowSuccessRatio`, `AegisApiHighErrorRate`, or
  `AegisApiHighLatency` firing (`apps/aegis-api/prometheusrule.yaml`).
- Kubernetes-level signals (Pod `Ready`, restart count, Gateway status,
  Prometheus scrape target) can all be perfectly healthy at the same time
  — infrastructure health and application correctness are different
  claims. Do not treat a green `kubectl get pods` as "nothing is wrong."

## Detection

1. Check alert state directly against Prometheus, not just Grafana/`kubectl`:
   ```
   curl -s 'http://localhost:9090/api/v1/rules?type=alert' | jq '.data.groups[] | select(.name | startswith("aegis-api"))'
   ```
2. Confirm which SLI breached (availability / 5xx / latency) — this
   narrows the failure class immediately. A latency-only breach with
   healthy availability/5xx points at expensive application logic, not a
   crash or dependency failure.

## Confirm current release

```
curl -s https://api.aegis.test/api/v1/info
kubectl -n aegis-api get deployment aegis-api -o jsonpath='{.spec.template.spec.containers[0].image}'
kubectl -n aegis-api get pod -l app=aegis-api -o jsonpath='{.items[0].status.containerStatuses[0].imageID}'
```
All three should agree on the same version/digest. If they don't, that's
a separate incident (Git/cluster drift) — `security-lab/image-automation/test.sh`
checks exactly this invariant.

## Confirm supply-chain trust (rule out a compromise)

Before assuming "it's just a bad release," rule out the alternative
explanation — a genuinely malicious or tampered artifact:

```
cosign verify "ghcr.io/nhatminh06/aegis-api@<digest>" \
  --certificate-identity-regexp "^https://github.com/nhatminh06/aegis-api/.github/workflows/release.yml@refs/tags/v.*$" \
  --certificate-oidc-issuer "https://token.actions.githubusercontent.com"
kubectl apply --dry-run=server -f - <<EOF
apiVersion: v1
kind: Pod
metadata: {name: dryrun, namespace: aegis-api, labels: {app: aegis-api}}
spec: {containers: [{name: aegis-api, image: "ghcr.io/nhatminh06/aegis-api@<digest>"}]}
EOF
```
If Cosign verifies and Kyverno's dry-run allows it, the artifact is
authentic and correctly signed by this project's own pipeline — the
defect is in the application, not the supply chain.

## Distinguish network failure from application regression

```
kubectl -n kube-system exec <a-cilium-pod> -c cilium-agent -- \
  hubble observe --namespace aegis-api --verdict DROPPED --last 50
```
No dropped flows + Gateway→aegis-api traffic shown as `FORWARDED` rules
out NetworkPolicy/Cilium/Gateway as the cause. Hubble answers "was it
allowed to reach the pod at all?" — Prometheus answers "did the
application perform once it got there?" These are different questions;
don't substitute one for the other.

## Emergency response: suspend automation, then roll back through Git

**Do this as a single Git commit, not two.** If automation is only
suspended first and the deployment rollback lands in a separate step,
there is a live window where automation is still capable of re-selecting
the bad release; if the deployment is rolled back first while automation
stays enabled, the very next reconcile (up to `interval: 5m` away) writes
the bad digest straight back. Change both `imageupdateautomation.yaml`
(`spec.suspend: true`) and `deployment.yaml` (image line back to the last
known-good `tag@digest`) in the same commit.

Before committing: `git fetch origin` and confirm no concurrent
Flux-authored commit landed since you last checked — automation writes to
`main` too. If one has, rebase and retry; never force-push.

```
cd ~/aegis
git fetch origin
# edit apps/aegis-api/imageupdateautomation.yaml: suspend: true
# edit apps/aegis-api/deployment.yaml: image back to known-good tag@digest
git add apps/aegis-api/deployment.yaml apps/aegis-api/imageupdateautomation.yaml
git commit -m "..."
git push origin main
```

Do **not** use `kubectl set image`, `kubectl rollout undo`, or any other
live patch as the final fix — Flux would just revert it back to whatever
Git says on the next reconcile. Git is the only place the fix is allowed
to live.

## Validation

```
flux reconcile source git flux-system
flux reconcile kustomization aegis-api
kubectl -n aegis-api get imageupdateautomation aegis-api -o jsonpath='{.spec.suspend}'   # true
kubectl -n aegis-api get deployment aegis-api -o jsonpath='{.spec.template.spec.containers[0].image}'  # known-good digest
kubectl -n aegis-api get pods   # new pod Running, old pod Terminating/gone
curl -s https://api.aegis.test/api/v1/info   # known-good version
```

## Recovery

Re-run the same load pattern used to detect the incident
(`reliability-lab/aegis-api-slo/load.sh`, same rate/duration/paths) and
confirm via direct Prometheus queries — not just "traffic looks fine" —
that the breached SLI returns to its objective and the alert transitions
`firing → inactive`.

## Resume criteria

Do not flip `imageupdateautomation.yaml`'s `suspend` back to `false`
until:
1. A root-caused, tested fix has shipped as a new immutable release.
2. That release independently passes Trivy, SBOM generation, Cosign
   verification, and a Kyverno dry-run — checked before touching
   automation, not assumed.
3. You've confirmed `ImagePolicy` may already be selecting the new
   release (registry-side selection is independent of what's actually
   deployed while automation is suspended — this is expected and fine,
   not a sign something is wrong).

Resume by committing `suspend: false` through Git, the same way it was
suspended. Let `ImageUpdateAutomation` generate its own commit moving to
the fixed release — do not hand-edit the deployment to the new version;
letting automation do it is what proves normal recovery from suspended
incident mode.

The bad release's tag, image, and signature are never deleted or moved.
It stays available as incident evidence.

## Incident timeline: v0.1.4 (2026-08-17)

All timestamps UTC, drawn from Git commit timestamps, `flux get` output,
and Prometheus query results captured during the incident — not
reconstructed after the fact.

| T | Event | Time |
|---|---|---|
| T0 | `v0.1.4` tag pushed; `release.yml` starts | 13:38:12 |
| — | `release.yml` completes (tests, Trivy, SBOM, Cosign, promotion all pass) | ~13:44 |
| T1 | `ImagePolicy/aegis-api` selects `v0.1.4` | 13:45:52 |
| T2 | `ImageUpdateAutomation` commits `v0.1.3 → v0.1.4` (`1f58bf1`) | 13:45:53 |
| T3 | New pod `Running`, `1/1 Ready`, 0 restarts, Kyverno admitted | ~13:46:10 |
| T4 | Regression load starts (`WORK_VALUE=34`, 10 req/s, 180s) | 13:56:16 |
| T5 | `AegisApiHighLatency` → `pending` | ~13:56:20 |
| T6 | `AegisApiHighLatency` → `firing` (`for: 2m` elapsed) | ~13:58:15 |
| T7 | Operator confirms: availability/5xx healthy, p95=237ms/p99=425ms, Kubernetes/Kyverno/Hubble all clean → isolates application latency as the cause | ~13:59–14:00 |
| T8 | Remediation commit pushed (`451e3de`: suspend automation + roll back digest) | 14:01:23 |
| T9 | Known-good pod `Running`/`Ready` (`v0.1.3`, `imageID` matches) | ~14:01:45 |
| T10 | Recovery load run; `AegisApiHighLatency` → `inactive` | 14:05:30 |

**Detection latency** (load start → firing): ~1m59s — matches the
configured `for: 2m` almost exactly, as expected. Note this is the
detection latency *given traffic exists*; between T3 and T4 the service
was idle and the recording rules evaluate to no data, so a regression
with no traffic against it cannot be detected by these SLIs alone — a
real, current limitation, not a false negative.

**Remediation latency** (firing → commit pushed): ~3m. **Rollout
latency** (commit pushed → known-good pod ready): ~22s (fast because
`flux reconcile` was forced rather than waiting for the default interval).
**Full recovery** (known-good pod ready → alert inactive): ~3m45s,
mostly bounded by the deliberately-chosen 3-minute verification load
run, not an inherent system limit.

## Known secondary finding: CPU-limit interaction (not part of the intended lab)

An earlier, uncalibrated load attempt against `v0.1.4` (`WORK_VALUE=40`
at 10 req/s, unconstrained concurrency) caused the pod to restart 3
times — not from the recursive computation itself, but from the
Deployment's `100m` CPU limit being exhausted by overlapping recursive
calls, starving the liveness probe until kubelet killed the container
(`readiness probe failed: connection refused`, container logs show
`received terminated` / `graceful shutdown failed: context deadline
exceeded`). This is a distinct, real failure mode from the latency
regression the lab targets, and was avoided in the final measurement by
choosing `WORK_VALUE=34` (single-request latency ~180ms measured
sequentially, safe under concurrent load at the same rate as baseline).
Worth a future look: this Deployment's CPU limit is tight enough that a
sufficiently expensive handler can turn a latency problem into an
availability problem — a real, if incidental, finding from this exercise.
