#!/usr/bin/env bash
# Operational wrapper around scripts/backup-stateful-lab-postgres.sh
# (unchanged, proven — this script never duplicates its pg_dump/
# encryption logic). Adds exactly what a scheduled, unattended run
# needs and a manual one-off doesn't: overlap locking, verification
# BEFORE the backup counts as successful, status tracking, and
# retention run only after a verified success.
#
# Designed to run under launchd (see ops/launchd/) with no interactive
# shell, no TTY, and a minimal inherited environment — every path is
# resolved explicitly, nothing depends on PATH beyond what's set here.
#
# See docs/runbooks/stateful-lab-postgresql-backup-restore.md.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BACKUP_SCRIPT="${REPO_ROOT}/scripts/backup-stateful-lab-postgres.sh"
PRUNE_SCRIPT="${REPO_ROOT}/scripts/prune-stateful-lab-backups.sh"

EXPECTED_CONTEXT="${AEGIS_HOME_K3S_CONTEXT:-home-k3s}"
NAMESPACE="stateful-lab"
POD="postgresql-0"
BACKUP_KEY_FILE="${AEGIS_BACKUP_AGE_KEY_FILE:-${HOME}/.config/aegis/backup/age/keys.txt}"
BACKUP_ROOT="${AEGIS_BACKUP_DIR:-${HOME}/.local/share/aegis/backups/stateful-lab/postgresql}"
STATE_DIR="${AEGIS_BACKUP_STATE_DIR:-${HOME}/.local/state/aegis/backups/stateful-lab}"
LOG_DIR="${AEGIS_BACKUP_LOG_DIR:-${HOME}/.local/state/aegis/logs}"
LOCK_DIR="${STATE_DIR}/.run.lock"
STATUS_FILE="${STATE_DIR}/status.txt"
LOG_FILE="${LOG_DIR}/stateful-lab-backup.log"

mkdir -p "${STATE_DIR}" "${LOG_DIR}"

# Simple size-based truncation instead of a rotation system — keeps the
# last ~500 lines when the log grows past ~1MB.
if [ -f "${LOG_FILE}" ] && [ "$(wc -c < "${LOG_FILE}" | tr -d ' ')" -gt 1048576 ]; then
  tail -n 500 "${LOG_FILE}" > "${LOG_FILE}.tmp" && mv "${LOG_FILE}.tmp" "${LOG_FILE}"
fi

log() {
  echo "$(date -u +%FT%TZ) $*" | tee -a "${LOG_FILE}"
}

now_iso() { date -u +%FT%TZ; }

write_status() {
  # $1=key $2=value — updates or appends one field, preserving the rest.
  local key="$1" value="$2"
  touch "${STATUS_FILE}"
  if grep -q "^${key}:" "${STATUS_FILE}" 2>/dev/null; then
    sed -i '' "s#^${key}:.*#${key}: ${value}#" "${STATUS_FILE}"
  else
    echo "${key}: ${value}" >> "${STATUS_FILE}"
  fi
}

# --- overlap lock: mkdir is atomic on POSIX filesystems; no flock on macOS ---
if ! mkdir "${LOCK_DIR}" 2>/dev/null; then
  log "REFUSED: another backup run is already in progress (${LOCK_DIR} exists)"
  exit 1
fi
cleanup_lock() {
  rmdir "${LOCK_DIR}" 2>/dev/null || true
}
trap cleanup_lock EXIT

log "==> backup run starting (context=${EXPECTED_CONTEXT})"
write_status "last_attempt_at" "$(now_iso)"

# --- run the proven backup script, capturing its output for the log ---
backup_output="$(mktemp)"
backup_status=0
AEGIS_HOME_K3S_CONTEXT="${EXPECTED_CONTEXT}" AEGIS_BACKUP_AGE_KEY_FILE="${BACKUP_KEY_FILE}" AEGIS_BACKUP_DIR="${BACKUP_ROOT}" \
  "${BACKUP_SCRIPT}" > "${backup_output}" 2>&1 || backup_status=$?
cat "${backup_output}" >> "${LOG_FILE}"

if [ "${backup_status}" -ne 0 ]; then
  log "FAILED: backup-stateful-lab-postgres.sh exited ${backup_status}"
  write_status "last_error_summary" "backup script exited ${backup_status} at $(now_iso)"
  rm -f "${backup_output}"
  exit "${backup_status}"
fi

artifact_path="$(grep '^  artifact:' "${backup_output}" | awk '{print $2}')"
rm -f "${backup_output}"
if [ -z "${artifact_path}" ] || [ ! -f "${artifact_path}" ]; then
  log "FAILED: could not determine the produced artifact path"
  write_status "last_error_summary" "artifact path not found after backup at $(now_iso)"
  exit 1
fi
metadata_path="${artifact_path%.dump.age}.metadata.txt"
if [ ! -f "${metadata_path}" ]; then
  log "FAILED: metadata file missing for ${artifact_path}"
  write_status "last_error_summary" "metadata missing after backup at $(now_iso)"
  exit 1
fi

log "==> archive verification: ${artifact_path}"

# --- checksum re-verification (independent of the backup script's own) ---
expected_sha256="$(grep '^encrypted_sha256:' "${metadata_path}" | cut -d' ' -f2)"
actual_sha256="$(sha256sum "${artifact_path}" | cut -d' ' -f1)"
if [ "${expected_sha256}" != "${actual_sha256}" ]; then
  log "FAILED: checksum mismatch immediately after backup — expected ${expected_sha256}, got ${actual_sha256}"
  write_status "last_error_summary" "checksum mismatch after backup at $(now_iso)"
  exit 1
fi

# --- decrypt + pg_restore --list, exactly what restore-stateful-lab-postgres.sh does ---
plaintext_check="$(mktemp)"
cleanup_plaintext() {
  rm -f "${plaintext_check}"
}
trap 'cleanup_plaintext; cleanup_lock' EXIT

if ! age -d -i "${BACKUP_KEY_FILE}" -o "${plaintext_check}" "${artifact_path}" 2>>"${LOG_FILE}"; then
  log "FAILED: archive did not decrypt with the backup key"
  write_status "last_error_summary" "decryption failed during verification at $(now_iso)"
  exit 1
fi

if ! kubectl -n "${NAMESPACE}" exec -i "${POD}" -- pg_restore --list < "${plaintext_check}" >>"${LOG_FILE}" 2>&1; then
  log "FAILED: pg_restore --list rejected the archive"
  write_status "last_error_summary" "pg_restore --list failed during verification at $(now_iso)"
  exit 1
fi

cleanup_plaintext
trap cleanup_lock EXIT

verification_timestamp="$(now_iso)"
verified_sidecar="${artifact_path%.dump.age}.verified.txt"
cat > "${verified_sidecar}" <<EOF
verification_status: PASS
verification_timestamp: ${verification_timestamp}
verification_checks: checksum, age-decrypt, pg_restore --list
EOF

log "==> verification PASS"
backup_name="$(basename "${artifact_path}")"
write_status "last_success_at" "${verification_timestamp}"
write_status "last_success_backup" "${backup_name}"
write_status "last_error_summary" "none"

log "==> running retention"
if "${PRUNE_SCRIPT}" --apply >>"${LOG_FILE}" 2>&1; then
  log "==> retention completed"
else
  # Retention failing does not undo an already-verified successful backup.
  log "WARNING: retention run failed — see ${LOG_FILE}; last_success is still valid"
fi

log "==> backup run complete: ${backup_name}"
