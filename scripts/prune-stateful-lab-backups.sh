#!/usr/bin/env bash
# Retention for stateful-lab PostgreSQL backups. Operates only on backup
# sets that completed archive verification (carry a `.verified.txt`
# sidecar written by scripts/run-stateful-lab-backup.sh) — a failed or
# partial run is never retention-eligible, it just sits there until a
# human looks at it. Always keeps the latest N verified sets and
# anything carrying a `PROTECTED` marker file, regardless of age.
#
# Usage: scripts/prune-stateful-lab-backups.sh [--dry-run|--apply]
# Defaults to --dry-run — real deletion requires the explicit flag.
#
# See docs/runbooks/stateful-lab-postgresql-backup-restore.md.
set -euo pipefail

BACKUP_ROOT="${AEGIS_BACKUP_DIR:-${HOME}/.local/share/aegis/backups/stateful-lab/postgresql}"
KEEP_LATEST="${AEGIS_BACKUP_RETENTION_COUNT:-14}"
MODE="--dry-run"

for arg in "$@"; do
  case "${arg}" in
    --dry-run) MODE="--dry-run" ;;
    --apply) MODE="--apply" ;;
    *)
      echo "usage: $0 [--dry-run|--apply]" >&2
      exit 1
      ;;
  esac
done

# --- path safety: this is the most destructive script in the milestone ---
resolved_root="$(cd "${BACKUP_ROOT}" 2>/dev/null && pwd || true)"
if [ -z "${resolved_root}" ]; then
  echo "error: backup root '${BACKUP_ROOT}' does not exist or is not a directory" >&2
  exit 1
fi
case "${resolved_root}" in
  "" | "/" | "${HOME}")
    echo "error: refusing to operate on an unsafe backup root: '${resolved_root}'" >&2
    exit 1
    ;;
esac
case "${resolved_root}" in
  */aegis/backups/stateful-lab/postgresql) ;;
  *)
    echo "error: backup root '${resolved_root}' does not look like a stateful-lab postgresql backup directory" >&2
    echo "       expected a path ending in aegis/backups/stateful-lab/postgresql" >&2
    exit 1
    ;;
esac

echo "==> backup root: ${resolved_root} (${MODE})"

# --- collect verified backup sets, sorted oldest-first by timestamp directory name ---
verified_dirs=()
while IFS= read -r dir; do
  [ -n "${dir}" ] && verified_dirs+=("${dir}")
done < <(find "${resolved_root}" -mindepth 1 -maxdepth 1 -type d | sort)

eligible=()
protected=()
for dir in "${verified_dirs[@]}"; do
  ts="$(basename "${dir}")"
  sidecar="${dir}/stateful-lab-postgresql-${ts}.verified.txt"
  if [ -f "${dir}/PROTECTED" ]; then
    protected+=("${dir}")
    continue
  fi
  if [ -f "${sidecar}" ]; then
    eligible+=("${dir}")
  fi
  # Directories with neither PROTECTED nor a .verified.txt sidecar are
  # left alone entirely — an incomplete/failed run, not ours to touch.
done

total_eligible="${#eligible[@]}"
echo "==> ${#protected[@]} protected, ${total_eligible} verified-eligible backup set(s)"

if [ "${total_eligible}" -le "${KEEP_LATEST}" ]; then
  echo "==> nothing to prune (${total_eligible} <= keep-latest ${KEEP_LATEST})"
  exit 0
fi

to_delete_count=$((total_eligible - KEEP_LATEST))
to_delete=("${eligible[@]:0:${to_delete_count}}")
to_keep=("${eligible[@]:${to_delete_count}}")

echo "==> would keep ${#to_keep[@]} verified set(s), delete ${#to_delete[@]}:"
for dir in "${to_delete[@]}"; do
  echo "    $(basename "${dir}")"
done

if [ "${MODE}" = "--dry-run" ]; then
  echo "==> dry-run: no files removed"
  exit 0
fi

for dir in "${to_delete[@]}"; do
  case "${dir}" in
    "${resolved_root}"/*) ;;
    *)
      echo "error: refusing to delete a path outside the backup root: ${dir}" >&2
      exit 1
      ;;
  esac
  echo "==> deleting $(basename "${dir}")"
  rm -rf -- "${dir}"
done

echo "==> retention applied: removed ${#to_delete[@]} backup set(s)"
