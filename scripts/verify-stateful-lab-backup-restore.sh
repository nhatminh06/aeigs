#!/usr/bin/env bash
# Full scratch-restore verification: proves a backup's DATA is
# recoverable, not just that its archive structure looks valid
# (that cheaper check already runs on every backup in
# scripts/run-stateful-lab-backup.sh). Restores into a throwaway
# database, computes the canonical fingerprint, and compares it against
# the fingerprint recorded in THAT BACKUP'S OWN metadata — never a
# hardcoded value, since the lab's data may legitimately change over
# time. Never touches aegis_state.
#
# Usage: scripts/verify-stateful-lab-backup-restore.sh [path-to-.dump.age]
# With no argument, selects the newest backup that has a .verified.txt
# sidecar (i.e. already passed archive verification).
#
# See docs/runbooks/stateful-lab-postgresql-backup-restore.md.
set -euo pipefail

EXPECTED_CONTEXT="${AEGIS_HOME_K3S_CONTEXT:-home-k3s}"
NAMESPACE="stateful-lab"
POD="postgresql-0"
DB_USER="aegis"
BACKUP_KEY_FILE="${AEGIS_BACKUP_AGE_KEY_FILE:-${HOME}/.config/aegis/backup/age/keys.txt}"
BACKUP_ROOT="${AEGIS_BACKUP_DIR:-${HOME}/.local/share/aegis/backups/stateful-lab/postgresql}"
STATE_DIR="${AEGIS_BACKUP_STATE_DIR:-${HOME}/.local/state/aegis/backups/stateful-lab}"
LOG_DIR="${AEGIS_BACKUP_LOG_DIR:-${HOME}/.local/state/aegis/logs}"
STATUS_FILE="${STATE_DIR}/status.txt"
LOG_FILE="${LOG_DIR}/stateful-lab-restore-verify.log"

mkdir -p "${STATE_DIR}" "${LOG_DIR}"
if [ -f "${LOG_FILE}" ] && [ "$(wc -c < "${LOG_FILE}" | tr -d ' ')" -gt 1048576 ]; then
  tail -n 500 "${LOG_FILE}" > "${LOG_FILE}.tmp" && mv "${LOG_FILE}.tmp" "${LOG_FILE}"
fi
log() { echo "$(date -u +%FT%TZ) $*" | tee -a "${LOG_FILE}"; }
now_iso() { date -u +%FT%TZ; }
write_status() {
  local key="$1" value="$2"
  touch "${STATUS_FILE}"
  if grep -q "^${key}:" "${STATUS_FILE}" 2>/dev/null; then
    sed -i '' "s#^${key}:.*#${key}: ${value}#" "${STATUS_FILE}"
  else
    echo "${key}: ${value}" >> "${STATUS_FILE}"
  fi
}

for cmd in kubectl age sha256sum; do
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    echo "error: required command '${cmd}' not found on PATH" >&2
    exit 1
  fi
done

current_context="$(kubectl config current-context 2>/dev/null || true)"
if [ "${current_context}" != "${EXPECTED_CONTEXT}" ]; then
  log "REFUSED: kubectl context is '${current_context}', expected '${EXPECTED_CONTEXT}'"
  exit 1
fi

BACKUP_PATH="${1:-}"
if [ -z "${BACKUP_PATH}" ]; then
  BACKUP_PATH="$(find "${BACKUP_ROOT}" -name '*.verified.txt' -print0 2>/dev/null \
    | xargs -0 -I{} dirname {} \
    | sort -r | head -1)"
  if [ -n "${BACKUP_PATH}" ]; then
    ts="$(basename "${BACKUP_PATH}")"
    BACKUP_PATH="${BACKUP_PATH}/stateful-lab-postgresql-${ts}.dump.age"
  fi
fi
if [ -z "${BACKUP_PATH}" ] || [ ! -f "${BACKUP_PATH}" ]; then
  log "FAILED: no verified backup found to restore-test"
  exit 1
fi

metadata_path="${BACKUP_PATH%.dump.age}.metadata.txt"
if [ ! -f "${metadata_path}" ]; then
  log "FAILED: metadata missing for ${BACKUP_PATH}"
  exit 1
fi

log "==> scratch-restore verification of $(basename "${BACKUP_PATH}")"

expected_sha256="$(grep '^encrypted_sha256:' "${metadata_path}" | cut -d' ' -f2)"
actual_sha256="$(sha256sum "${BACKUP_PATH}" | cut -d' ' -f1)"
if [ "${expected_sha256}" != "${actual_sha256}" ]; then
  log "FAILED: checksum mismatch for ${BACKUP_PATH}"
  write_status "last_error_summary" "restore-verify checksum mismatch at $(now_iso)"
  exit 1
fi

expected_fingerprint="$(grep '^pre_backup_fingerprint_sha256:' "${metadata_path}" | cut -d' ' -f2)"
if [ -z "${expected_fingerprint}" ]; then
  log "FAILED: no pre_backup_fingerprint_sha256 recorded in ${metadata_path}"
  exit 1
fi

# Collision-safe, validated scratch DB name — never the production
# database, whatever PID this happens to run under.
scratch_db="aegis_restore_verify_$$"
case "${scratch_db}" in
  aegis_restore_verify_*) ;;
  *)
    log "FAILED: scratch database name failed validation: ${scratch_db}"
    exit 1
    ;;
esac

plaintext_dump="$(mktemp)"
cleanup() {
  rm -f "${plaintext_dump}"
  kubectl -n "${NAMESPACE}" exec "${POD}" -- \
    psql -U "${DB_USER}" -d postgres -c "DROP DATABASE IF EXISTS ${scratch_db};" >/dev/null 2>&1 || true
}
trap cleanup EXIT

if ! age -d -i "${BACKUP_KEY_FILE}" -o "${plaintext_dump}" "${BACKUP_PATH}" 2>>"${LOG_FILE}"; then
  log "FAILED: decryption failed"
  write_status "last_error_summary" "restore-verify decryption failed at $(now_iso)"
  exit 1
fi

log "==> creating scratch database ${scratch_db}"
kubectl -n "${NAMESPACE}" exec "${POD}" -- \
  psql -U "${DB_USER}" -d postgres -c "CREATE DATABASE ${scratch_db};" >>"${LOG_FILE}" 2>&1

log "==> restoring into scratch database"
if ! kubectl -n "${NAMESPACE}" exec -i "${POD}" -- \
  pg_restore --no-owner --no-privileges -U "${DB_USER}" -d "${scratch_db}" < "${plaintext_dump}" >>"${LOG_FILE}" 2>&1; then
  log "FAILED: pg_restore into scratch database failed"
  write_status "last_error_summary" "restore-verify pg_restore failed at $(now_iso)"
  exit 1
fi

# Same canonical query as scripts/backup-stateful-lab-postgres.sh's
# pre-backup fingerprint — kept identical deliberately, not abstracted
# into a shared file for one query.
restored_fingerprint="$(kubectl -n "${NAMESPACE}" exec "${POD}" -- \
  psql -U "${DB_USER}" -d "${scratch_db}" -t -A -F',' \
  -c "SELECT id, value FROM persistence_proof ORDER BY id;" \
  | sha256sum | cut -d' ' -f1)"

log "==> expected fingerprint (from backup metadata): ${expected_fingerprint}"
log "==> restored fingerprint:                        ${restored_fingerprint}"

if [ "${restored_fingerprint}" != "${expected_fingerprint}" ]; then
  log "FAILED: fingerprint mismatch"
  write_status "last_error_summary" "restore-verify fingerprint mismatch at $(now_iso)"
  exit 1
fi

log "==> PASS: restored data matches this backup's own recorded fingerprint"
write_status "last_verification_at" "$(now_iso)"
write_status "last_verification_backup" "$(basename "${BACKUP_PATH}")"
write_status "last_error_summary" "none"
