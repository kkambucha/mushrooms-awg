#!/usr/bin/env bash
# Mushrooms-AWG — interactive installer for AmneziaWG on Ubuntu
# Target: Ubuntu 20.04+ (Debian-compatible)
# Usage: sudo bash install.sh
#
# Domain required. Same server.json + same domain → same clients keep working.
# Always prefer a clean server for the first install.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_DIR="${DEPLOY_DIR:-/opt/mushrooms-awg}"

# shellcheck source=lib/common.sh
source "${REPO_DIR}/lib/common.sh"
# shellcheck source=lib/ask.sh
source "${REPO_DIR}/lib/ask.sh"
# shellcheck source=lib/deps.sh
source "${REPO_DIR}/lib/deps.sh"
# shellcheck source=lib/state.sh
source "${REPO_DIR}/lib/state.sh"
# shellcheck source=lib/routes.sh
source "${REPO_DIR}/lib/routes.sh"
# shellcheck source=lib/awg.sh
source "${REPO_DIR}/lib/awg.sh"
# shellcheck source=lib/compose.sh
source "${REPO_DIR}/lib/compose.sh"
# shellcheck source=lib/summary.sh
source "${REPO_DIR}/lib/summary.sh"

main() {
  require_root
  check_ubuntu
  check_cpu_arch

  echo
  echo "╔══════════════════════════════════════════════╗"
  echo "║  Mushrooms-AWG installer — AmneziaWG         ║"
  echo "╚══════════════════════════════════════════════╝"
  echo
  echo "Source (this script): ${REPO_DIR}"
  echo "Runtime (after success): ${DEPLOY_DIR}"
  echo "  → ${DEPLOY_DIR} is created only after dependencies succeed."
  echo

  ensure_jq
  ask_config
  install_deps
  configure_sysctl

  if [[ "$RESTORE_MODE" == "true" ]]; then
    load_state_file "$STATE_SOURCE"
    add_clients_to_state "$ADD_CLIENTS"
    if [[ -n "${STATE_PASTE_TEMP:-}" && -f "${STATE_PASTE_TEMP}" ]]; then
      rm -f "${STATE_PASTE_TEMP}"
      STATE_PASTE_TEMP=""
    fi
  else
    create_new_state "$CLIENT_COUNT"
  fi

  apply_wizard_port
  validate_state_json "$STATE_JSON"
  export_state_vars

  prepare_deploy_dir
  write_state_file
  build_allowed_ips
  render_awg0_conf
  render_client_configs

  compose_up
  wait_for_awg
  configure_ufw "$AWG_PORT" "$AWG_SUBNET"
  if [[ "${UFW_RELOADED:-}" == "true" ]]; then
    log "Restarting tunnel so firewall rules apply"
    docker restart mushrooms_awg >/dev/null
    wait_for_awg
  fi
  write_summary

  log "Done. Deploy directory: ${DEPLOY_DIR}"
  log "Next: cd ${DEPLOY_DIR} && docker compose ps"
}

main "$@"
