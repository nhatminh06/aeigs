#!/usr/bin/env bash
# Serves this repo to the dev-kind cluster over HTTP so Flux's GitRepository
# can clone it without a GitHub remote. This is a local-development-only
# bridge: replace it with a real remote and `flux bootstrap` once one
# exists (see clusters/dev-kind/flux-system/gotk-sync.yaml).
#
# Runs `git http-backend` as CGI under Python's http.server, bound to
# 127.0.0.1. The kind node reaches it via host.docker.internal.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BRIDGE_DIR="${REPO_ROOT}/.git-bridge"
PID_FILE="/tmp/aegis-git-bridge.pid"
PORT=8099

for cmd in git python3; do
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    echo "error: required command '${cmd}' not found on PATH" >&2
    exit 1
  fi
done

if [ -f "${PID_FILE}" ] && kill -0 "$(cat "${PID_FILE}")" 2>/dev/null; then
  echo "git bridge already running (pid $(cat "${PID_FILE}")), skipping"
  exit 0
fi

mkdir -p "${BRIDGE_DIR}/cgi-bin"
cat > "${BRIDGE_DIR}/cgi-bin/git-http-backend" <<EOF
#!/bin/sh
export GIT_PROJECT_ROOT="$(dirname "${REPO_ROOT}")"
export GIT_HTTP_EXPORT_ALL=1
exec git http-backend
EOF
chmod +x "${BRIDGE_DIR}/cgi-bin/git-http-backend"

git -C "${REPO_ROOT}" update-server-info

(cd "${BRIDGE_DIR}" && nohup python3 -m http.server --bind 127.0.0.1 --cgi "${PORT}" \
  > /tmp/aegis-git-bridge.log 2>&1 &)

sleep 1
# $! is unreliable here: some python3 installs are shims that fork into a
# child with a different pid, so resolve the pid actually bound to the
# port instead of trusting the backgrounded job's pid.
LISTENER_PID="$(lsof -ti "tcp:${PORT}" -sTCP:LISTEN 2>/dev/null || true)"
if [ -z "${LISTENER_PID}" ]; then
  echo "error: git bridge failed to start, see /tmp/aegis-git-bridge.log" >&2
  exit 1
fi
echo "${LISTENER_PID}" > "${PID_FILE}"

echo "git bridge running on 127.0.0.1:${PORT} (pid $(cat "${PID_FILE}"))"
echo "GitRepository URL: http://host.docker.internal:${PORT}/cgi-bin/git-http-backend/$(basename "${REPO_ROOT}")"
