#!/usr/bin/env bash
# Prints the current backup operational status for both database
# families (stateful-lab, Authentik) and exits non-zero if either
# target's backup or restore-verification is stale — useful for a
# quick check without parsing filenames or logs by hand.
#
# See docs/runbooks/stateful-lab-postgresql-backup-restore.md and
# docs/runbooks/home-k3s-authentik.md.
set -euo pipefail

BACKUP_OBJECTIVE_SECONDS="${AEGIS_BACKUP_OBJECTIVE_SECONDS:-21600}"   # 6h
VERIFY_OBJECTIVE_SECONDS="${AEGIS_VERIFY_OBJECTIVE_SECONDS:-86400}"   # 24h

now_epoch="$(date -u +%s)"
age_seconds() {
  local iso="$1"
  [ -z "${iso}" ] && { echo -1; return; }
  local epoch
  epoch="$(date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "${iso}" +%s 2>/dev/null || echo -1)"
  [ "${epoch}" -lt 0 ] && { echo -1; return; }
  echo $((now_epoch - epoch))
}

field() {
  # $1=status file $2=key
  grep "^$2:" "$1" 2>/dev/null | cut -d' ' -f2- || true
}

# Checks one target's status file and prints its block. Returns 1 if
# stale, 0 if healthy — same logic run twice with different paths, not
# a generic multi-target framework.
check_target() {
  local name="$1" status_file="$2"
  local target_ok=0

  echo "=== ${name} backup status ==="
  if [ ! -f "${status_file}" ]; then
    echo "STALE: no backup has ever run (${status_file} does not exist)"
    echo
    return 1
  fi

  local last_attempt last_success last_success_backup last_verification last_verification_backup last_error
  last_attempt="$(field "${status_file}" last_attempt_at)"
  last_success="$(field "${status_file}" last_success_at)"
  last_success_backup="$(field "${status_file}" last_success_backup)"
  last_verification="$(field "${status_file}" last_verification_at)"
  last_verification_backup="$(field "${status_file}" last_verification_backup)"
  last_error="$(field "${status_file}" last_error_summary)"

  local backup_age verify_age
  backup_age="$(age_seconds "${last_success}")"
  verify_age="$(age_seconds "${last_verification}")"

  echo "last attempt:            ${last_attempt:-never}"
  echo "last successful backup:  ${last_success:-never} (${last_success_backup:-none})"
  if [ "${backup_age}" -lt 0 ]; then
    echo "  -> STALE: no successful backup on record"
    target_ok=1
  elif [ "${backup_age}" -gt "${BACKUP_OBJECTIVE_SECONDS}" ]; then
    echo "  -> STALE: $((backup_age / 3600))h since last success, objective is $((BACKUP_OBJECTIVE_SECONDS / 3600))h"
    target_ok=1
  else
    echo "  -> HEALTHY: $((backup_age / 60))m since last success, within $((BACKUP_OBJECTIVE_SECONDS / 3600))h objective"
  fi

  echo "last restore verification: ${last_verification:-never} (${last_verification_backup:-none})"
  if [ "${verify_age}" -lt 0 ]; then
    echo "  -> STALE: no successful restore verification on record"
    target_ok=1
  elif [ "${verify_age}" -gt "${VERIFY_OBJECTIVE_SECONDS}" ]; then
    echo "  -> STALE: $((verify_age / 3600))h since last verification, objective is $((VERIFY_OBJECTIVE_SECONDS / 3600))h"
    target_ok=1
  else
    echo "  -> HEALTHY: $((verify_age / 3600))h since last verification, within $((VERIFY_OBJECTIVE_SECONDS / 3600))h objective"
  fi

  if [ -n "${last_error}" ] && [ "${last_error}" != "none" ]; then
    echo "last error: ${last_error}"
  fi

  if [ "${target_ok}" -eq 0 ]; then
    echo "=== ${name}: HEALTHY ==="
  else
    echo "=== ${name}: STALE ==="
  fi
  echo
  return "${target_ok}"
}

overall_ok=0

check_target "stateful-lab" \
  "${AEGIS_BACKUP_STATE_DIR:-${HOME}/.local/state/aegis/backups/stateful-lab}/status.txt" \
  || overall_ok=1

check_target "authentik" \
  "${AEGIS_AUTHENTIK_BACKUP_STATE_DIR:-${HOME}/.local/state/aegis/backups/authentik}/status.txt" \
  || overall_ok=1

exit "${overall_ok}"
