#!/usr/bin/env bash
# Restores an encrypted stateful-lab PostgreSQL backup (produced by
# scripts/backup-stateful-lab-postgres.sh) into a target database on
# home-k3s. Decrypts on the operator's own machine and streams the
# restore into the cluster — the backup private key never needs to exist
# on K3s.
#
# Usage:
#   scripts/restore-stateful-lab-postgres.sh <path-to-.dump.age> <target-db> [--replace-existing]
#
# Without --replace-existing, pg_restore fails loudly if objects already
# exist in <target-db> rather than silently overwriting them. Pass it
# only when you specifically intend to replace existing objects
# (--clean --if-exists is added in that case).
#
# See docs/runbooks/stateful-lab-postgresql-backup-restore.md.
#
# AEGIS_HOME_K3S_CONTEXT: same purpose as in
# scripts/bootstrap-cilium-home-k3s.sh — lets this script safely target a
# replacement-host reconstruction test. Unset, behavior is unchanged.
set -euo pipefail

EXPECTED_CONTEXT="${AEGIS_HOME_K3S_CONTEXT:-home-k3s}"
NAMESPACE="stateful-lab"
POD="postgresql-0"
DB_USER="aegis"
BACKUP_KEY_FILE="${AEGIS_BACKUP_AGE_KEY_FILE:-${HOME}/.config/aegis/backup/age/keys.txt}"

if [ "$#" -lt 2 ]; then
  echo "usage: $0 <path-to-.dump.age> <target-db> [--replace-existing]" >&2
  exit 1
fi
BACKUP_PATH="$1"
TARGET_DB="$2"
REPLACE_EXISTING="${3:-}"

for cmd in kubectl age sha256sum; do
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    echo "error: required command '${cmd}' not found on PATH" >&2
    exit 1
  fi
done

current_context="$(kubectl config current-context 2>/dev/null || true)"
if [ "${current_context}" != "${EXPECTED_CONTEXT}" ]; then
  echo "error: kubectl context is '${current_context}', expected '${EXPECTED_CONTEXT}'" >&2
  echo "       refusing to restore into a database on the wrong cluster" >&2
  exit 1
fi

if [ ! -f "${BACKUP_PATH}" ]; then
  echo "error: backup file not found: ${BACKUP_PATH}" >&2
  exit 1
fi
if [ ! -f "${BACKUP_KEY_FILE}" ]; then
  echo "error: backup age key not found at '${BACKUP_KEY_FILE}'" >&2
  exit 1
fi

metadata_path="${BACKUP_PATH%.dump.age}.metadata.txt"
if [ -f "${metadata_path}" ]; then
  expected_sha256="$(grep '^encrypted_sha256:' "${metadata_path}" | cut -d' ' -f2)"
  actual_sha256="$(sha256sum "${BACKUP_PATH}" | cut -d' ' -f1)"
  if [ -n "${expected_sha256}" ] && [ "${expected_sha256}" != "${actual_sha256}" ]; then
    echo "error: checksum mismatch for ${BACKUP_PATH}" >&2
    echo "       expected: ${expected_sha256}" >&2
    echo "       actual:   ${actual_sha256}" >&2
    exit 1
  fi
  echo "==> checksum verified against ${metadata_path}"
else
  echo "warning: no metadata file at ${metadata_path}; skipping checksum verification" >&2
fi

plaintext_dump="$(mktemp)"
cleanup() {
  rm -f "${plaintext_dump}"
}
trap cleanup EXIT

echo "==> decrypting"
if ! age -d -i "${BACKUP_KEY_FILE}" -o "${plaintext_dump}" "${BACKUP_PATH}"; then
  echo "error: decryption failed — wrong key, or the backup file is not valid age ciphertext" >&2
  exit 1
fi

echo "==> verifying archive structure (pg_restore --list)"
kubectl -n "${NAMESPACE}" exec -i "${POD}" -- pg_restore --list < "${plaintext_dump}" | head -20

echo "==> ensuring target database '${TARGET_DB}' exists"
kubectl -n "${NAMESPACE}" exec "${POD}" -- \
  psql -U "${DB_USER}" -d postgres -tAc \
  "SELECT 1 FROM pg_database WHERE datname = '${TARGET_DB}'" | grep -q 1 || \
  kubectl -n "${NAMESPACE}" exec "${POD}" -- \
    createdb -U "${DB_USER}" "${TARGET_DB}"

restore_flags=(--no-owner --no-privileges -U "${DB_USER}" -d "${TARGET_DB}")
if [ "${REPLACE_EXISTING}" = "--replace-existing" ]; then
  echo "==> --replace-existing: restore will drop conflicting objects first"
  restore_flags+=(--clean --if-exists)
fi

echo "==> restoring into ${NAMESPACE}/${TARGET_DB}"
restore_status=0
kubectl -n "${NAMESPACE}" exec -i "${POD}" -- pg_restore "${restore_flags[@]}" < "${plaintext_dump}" || restore_status=$?

rm -f "${plaintext_dump}"
trap - EXIT

if [ "${restore_status}" -ne 0 ]; then
  echo "error: pg_restore exited ${restore_status}" >&2
  exit "${restore_status}"
fi

echo
echo "Restore complete into ${NAMESPACE}/${TARGET_DB}."
