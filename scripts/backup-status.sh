#!/usr/bin/env bash
# Prints the current stateful-lab backup operational status and exits
# non-zero if either the backup or the restore-verification is stale —
# useful for a quick check without parsing filenames or logs by hand.
#
# See docs/runbooks/stateful-lab-postgresql-backup-restore.md.
set -euo pipefail

STATE_DIR="${AEGIS_BACKUP_STATE_DIR:-${HOME}/.local/state/aegis/backups/stateful-lab}"
STATUS_FILE="${STATE_DIR}/status.txt"
BACKUP_OBJECTIVE_SECONDS="${AEGIS_BACKUP_OBJECTIVE_SECONDS:-21600}"   # 6h
VERIFY_OBJECTIVE_SECONDS="${AEGIS_VERIFY_OBJECTIVE_SECONDS:-86400}"   # 24h

field() {
  grep "^$1:" "${STATUS_FILE}" 2>/dev/null | cut -d' ' -f2- || true
}

if [ ! -f "${STATUS_FILE}" ]; then
  echo "STALE: no backup has ever run (${STATUS_FILE} does not exist)"
  exit 1
fi

last_attempt="$(field last_attempt_at)"
last_success="$(field last_success_at)"
last_success_backup="$(field last_success_backup)"
last_verification="$(field last_verification_at)"
last_verification_backup="$(field last_verification_backup)"
last_error="$(field last_error_summary)"

now_epoch="$(date -u +%s)"
age_seconds() {
  local iso="$1"
  [ -z "${iso}" ] && { echo -1; return; }
  local epoch
  epoch="$(date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "${iso}" +%s 2>/dev/null || echo -1)"
  [ "${epoch}" -lt 0 ] && { echo -1; return; }
  echo $((now_epoch - epoch))
}

backup_age="$(age_seconds "${last_success}")"
verify_age="$(age_seconds "${last_verification}")"

status_ok=0

echo "=== stateful-lab backup status ==="
echo "last attempt:            ${last_attempt:-never}"
echo "last successful backup:  ${last_success:-never} (${last_success_backup:-none})"
if [ "${backup_age}" -lt 0 ]; then
  echo "  -> STALE: no successful backup on record"
  status_ok=1
elif [ "${backup_age}" -gt "${BACKUP_OBJECTIVE_SECONDS}" ]; then
  echo "  -> STALE: $((backup_age / 3600))h since last success, objective is $((BACKUP_OBJECTIVE_SECONDS / 3600))h"
  status_ok=1
else
  echo "  -> HEALTHY: $((backup_age / 60))m since last success, within $((BACKUP_OBJECTIVE_SECONDS / 3600))h objective"
fi

echo "last restore verification: ${last_verification:-never} (${last_verification_backup:-none})"
if [ "${verify_age}" -lt 0 ]; then
  echo "  -> STALE: no successful restore verification on record"
  status_ok=1
elif [ "${verify_age}" -gt "${VERIFY_OBJECTIVE_SECONDS}" ]; then
  echo "  -> STALE: $((verify_age / 3600))h since last verification, objective is $((VERIFY_OBJECTIVE_SECONDS / 3600))h"
  status_ok=1
else
  echo "  -> HEALTHY: $((verify_age / 3600))h since last verification, within $((VERIFY_OBJECTIVE_SECONDS / 3600))h objective"
fi

if [ -n "${last_error}" ] && [ "${last_error}" != "none" ]; then
  echo "last error: ${last_error}"
fi

if [ "${status_ok}" -eq 0 ]; then
  echo "=== overall: HEALTHY ==="
else
  echo "=== overall: STALE ==="
fi
exit "${status_ok}"
