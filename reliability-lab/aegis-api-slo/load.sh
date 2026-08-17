#!/usr/bin/env bash
# Bounded, repeatable workload against aegis-api, used to compare the
# same request pattern across releases (see reliability-lab/aegis-api-slo/README.md).
# Not a stress test: fixed rate, fixed duration, fixed request mix.
set -euo pipefail

BASE_URL="${BASE_URL:-https://api.aegis.test}"
RATE_HZ="${RATE_HZ:-10}"          # requests per second, split across both endpoints
DURATION_SEC="${DURATION_SEC:-180}"
WORK_VALUE="${WORK_VALUE:-10}"    # value= for /api/v1/work

if ! command -v curl >/dev/null 2>&1; then
  echo "error: required command 'curl' not found on PATH" >&2
  exit 1
fi

interval=$(awk -v r="${RATE_HZ}" 'BEGIN { printf "%.4f", 1.0 / r }')
total=$(( RATE_HZ * DURATION_SEC ))

echo "start: $(date -u +%FT%TZ)"
echo "target: ${BASE_URL} rate=${RATE_HZ}/s duration=${DURATION_SEC}s total_requests=${total} work_value=${WORK_VALUE}"

count=0
end=$(( $(date +%s) + DURATION_SEC ))
while [ "$(date +%s)" -lt "${end}" ]; do
  if [ $(( count % 2 )) -eq 0 ]; then
    curl -s -o /dev/null "${BASE_URL}/api/v1/info" &
  else
    curl -s -o /dev/null "${BASE_URL}/api/v1/work?value=${WORK_VALUE}" &
  fi
  count=$(( count + 1 ))
  sleep "${interval}"
done
wait

echo "end: $(date -u +%FT%TZ)"
echo "requests_issued: ${count}"
