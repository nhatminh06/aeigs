#!/usr/bin/env bash
# Stops the local git-http bridge started by git-bridge-up.sh.
set -euo pipefail

PID_FILE="/tmp/aegis-git-bridge.pid"

if [ ! -f "${PID_FILE}" ] || ! kill -0 "$(cat "${PID_FILE}")" 2>/dev/null; then
  echo "git bridge not running, nothing to do"
  rm -f "${PID_FILE}"
  exit 0
fi

kill "$(cat "${PID_FILE}")"
rm -f "${PID_FILE}"
echo "git bridge stopped"
