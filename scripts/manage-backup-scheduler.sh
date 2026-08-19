#!/usr/bin/env bash
# Installs, removes, or reports on the four backup LaunchAgents —
# stateful-lab and Authentik, each with a backup agent and a
# restore-verify agent. Generates user-specific plists from the
# committed templates in ops/launchd/ (substituting this machine's
# actual paths — the templates themselves stay username-independent)
# into ~/Library/LaunchAgents/, never into the repository.
#
# Uses the current launchctl domain-target workflow (bootstrap/bootout/
# kickstart), not the legacy load/unload/start, which silently no-ops
# on a broken plist instead of reporting an error.
#
# Usage:
#   scripts/manage-backup-scheduler.sh install
#   scripts/manage-backup-scheduler.sh uninstall
#   scripts/manage-backup-scheduler.sh status
#   scripts/manage-backup-scheduler.sh run-now <stateful-lab|authentik> <backup|verify>
#
# See docs/runbooks/stateful-lab-postgresql-backup-restore.md and
# docs/runbooks/home-k3s-authentik.md.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMPLATE_DIR="${REPO_ROOT}/ops/launchd"
AGENT_DIR="${HOME}/Library/LaunchAgents"
DOMAIN="gui/$(id -u)"

LABELS=(
  com.aegis.stateful-lab-backup
  com.aegis.stateful-lab-restore-verify
  com.aegis.authentik-backup
  com.aegis.authentik-restore-verify
)

usage() {
  echo "usage: $0 install|uninstall|status|run-now <stateful-lab|authentik> <backup|verify>" >&2
  exit 1
}

generate_plist() {
  local label="$1"
  local template="${TEMPLATE_DIR}/${label}.plist.template"
  local dest="${AGENT_DIR}/${label}.plist"
  if [ ! -f "${template}" ]; then
    echo "error: template not found: ${template}" >&2
    exit 1
  fi
  sed -e "s#__REPO_ROOT__#${REPO_ROOT}#g" -e "s#__HOME__#${HOME}#g" "${template}" > "${dest}"
  echo "${dest}"
}

cmd_install() {
  mkdir -p "${AGENT_DIR}" "${HOME}/.local/state/aegis/logs"
  for label in "${LABELS[@]}"; do
    dest="$(generate_plist "${label}")"
    plutil -lint "${dest}" >/dev/null
    launchctl bootout "${DOMAIN}/${label}" >/dev/null 2>&1 || true
    launchctl bootstrap "${DOMAIN}" "${dest}"
    echo "installed: ${label} (${dest})"
  done
  echo "Both LaunchAgents installed. Verify with: $0 status"
}

cmd_uninstall() {
  for label in "${LABELS[@]}"; do
    launchctl bootout "${DOMAIN}/${label}" >/dev/null 2>&1 || true
    rm -f "${AGENT_DIR}/${label}.plist"
    echo "removed: ${label}"
  done
  echo "Scheduler uninstalled. Existing backups were not touched."
}

cmd_status() {
  for label in "${LABELS[@]}"; do
    echo "=== ${label} ==="
    if launchctl print "${DOMAIN}/${label}" >/dev/null 2>&1; then
      launchctl print "${DOMAIN}/${label}" | grep -E "state|last exit code" || true
    else
      echo "not loaded"
    fi
  done
}

cmd_run_now() {
  local target="${1:-}" which="${2:-}"
  local label
  case "${target}-${which}" in
    stateful-lab-backup) label="com.aegis.stateful-lab-backup" ;;
    stateful-lab-verify) label="com.aegis.stateful-lab-restore-verify" ;;
    authentik-backup) label="com.aegis.authentik-backup" ;;
    authentik-verify) label="com.aegis.authentik-restore-verify" ;;
    *) usage ;;
  esac
  echo "==> forcing an immediate launchd-triggered run of ${label}"
  launchctl kickstart -k "${DOMAIN}/${label}"
}

case "${1:-}" in
  install) cmd_install ;;
  uninstall) cmd_uninstall ;;
  status) cmd_status ;;
  run-now) cmd_run_now "${2:-}" "${3:-}" ;;
  *) usage ;;
esac
