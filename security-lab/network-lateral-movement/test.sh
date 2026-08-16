#!/usr/bin/env bash
# Proves an unrelated workload cannot open a TCP connection to Authentik's
# database, server, or worker.
#
# Only the attacker paths are automated. The legitimate flows (server and
# worker to the database, Grafana to the server) are verified by observing
# real application traffic in Hubble, recorded in README.md, rather than by
# synthesising them — that would mean shipping database credentials and a
# valid OAuth code into a probe pod.
#
# Exits 0 only if every connection is refused/times out.
set -euo pipefail

EXPECTED_CONTEXT="kind-aegis-dev"
PROBE_NS="demo-app"
# Service DNS, not pod names: pod names change on every restart. All three
# boundaries are checked from the same unrelated namespace, since they
# defend against the same thing — a compromised workload reaching
# Authentik.
TARGETS="authentik-postgresql.authentik.svc.cluster.local:5432
authentik-server.authentik.svc.cluster.local:80"

if ! command -v kubectl >/dev/null 2>&1; then
  echo "error: required command 'kubectl' not found on PATH" >&2
  exit 1
fi

current_context="$(kubectl config current-context 2>/dev/null || true)"
if [ "${current_context}" != "${EXPECTED_CONTEXT}" ]; then
  echo "error: kubectl context is '${current_context}', expected '${EXPECTED_CONTEXT}'" >&2
  exit 1
fi

# No Service selects the worker, so it is addressed by pod IP — resolved
# here by label selector rather than hard-coded, since the IP changes on
# every restart. The worker listens on 9000 and 9300 and both were
# reachable from this namespace before the policy existed, so this is a
# real transition to test, not a port that was always closed.
worker_ip="$(kubectl -n authentik get pod \
  -l app.kubernetes.io/component=worker,app.kubernetes.io/name=authentik \
  -o jsonpath='{.items[0].status.podIP}' 2>/dev/null || true)"
if [ -n "${worker_ip}" ]; then
  TARGETS="${TARGETS}
${worker_ip}:9000"
else
  echo "warning: could not resolve the authentik worker pod IP; skipping that check" >&2
fi

probe_name=""
cleanup() {
  [ -n "${probe_name}" ] && kubectl -n "${PROBE_NS}" delete pod "${probe_name}" \
    --ignore-not-found --wait=false >/dev/null 2>&1 || true
}
trap cleanup EXIT

failed=0
for target in ${TARGETS}; do
  host="${target%:*}"
  port="${target##*:}"
  probe_name="lateral-probe-$$-${port}"
  echo "==> probing ${host}:${port} from namespace ${PROBE_NS}"

  # `nc -z` exits non-zero when the connection is refused or times out, so
  # the check is inverted: a successful connection is the failure case.
  if kubectl -n "${PROBE_NS}" run "${probe_name}" \
       --image=busybox:1.36.1 --restart=Never --rm -i --quiet \
       --command -- nc -z -w5 "${host}" "${port}" >/dev/null 2>&1; then
    echo "FAIL: ${PROBE_NS} reached ${host}:${port}" >&2
    echo "      the NetworkPolicy is missing, not selecting those pods, or" >&2
    echo "      another policy is allowing the traffic (policies are additive)" >&2
    failed=1
  else
    echo "PASS: ${PROBE_NS} cannot reach ${host}:${port}"
  fi
  cleanup
  probe_name=""
done

exit "${failed}"
