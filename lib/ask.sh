#!/usr/bin/env bash
# Interactive wizard — short config for AmneziaWG

_require_jq() {
  command -v jq >/dev/null 2>&1 || die "jq is not installed, so the server file cannot be read. The firewall was not changed."
}

_store_pasted_state() {
  local raw="$1"
  local old_umask
  _require_jq
  if ! printf '%s' "$raw" | jq -e . >/dev/null 2>&1; then
    die "Pasted server file is not valid JSON"
  fi
  old_umask="$(umask)"
  umask 077
  STATE_PASTE_TEMP="$(mktemp)"
  printf '%s' "$raw" >"${STATE_PASTE_TEMP}"
  chmod 600 "${STATE_PASTE_TEMP}"
  umask "$old_umask"
  STATE_SOURCE="${STATE_PASTE_TEMP}"
  RESTORE_MODE="true"
  STATE_SOURCE_LABEL="pasted server.json"
}

_prompt_pasted_state() {
  prompt_multiline_end "Paste server.json (line with only END when finished; empty first line cancels paste)"
  if [[ -z "${REPLY}" ]]; then
    return 1
  fi
  _store_pasted_state "${REPLY}"
  return 0
}

ask_config() {
  log "Configuration wizard"
  echo "Domain is required. Endpoint in client configs will use this name."
  echo "If a server file is already on this machine, choose: use it, paste another, or create new."
  echo "To restore on another host: leave the path empty and paste server.json (end with END)."
  echo

  DOMAIN=""
  STATE_SOURCE=""
  STATE_SOURCE_LABEL=""
  STATE_PASTE_TEMP=""
  RESTORE_MODE="false"
  REPLACE_LOCAL_STATE="false"
  CLIENT_COUNT="1"
  ADD_CLIENTS="0"
  WIZARD_PORT="443"
  PREV_AWG_PORT=""

  prompt "Domain name" ""
  normalize_domain "${REPLY}"
  DOMAIN="${REPLY}"

  prompt "Path to existing server.json (optional)" ""
  STATE_SOURCE="${REPLY}"

  local local_state="${DEPLOY_DIR}/state/server.json"
  if [[ -n "$STATE_SOURCE" ]]; then
    [[ -f "$STATE_SOURCE" ]] || die "State file not found: ${STATE_SOURCE}"
    RESTORE_MODE="true"
    STATE_SOURCE_LABEL="$STATE_SOURCE"
  elif [[ -f "$local_state" ]]; then
    log "Found existing state at ${local_state}"
    prompt "Use this file, paste another, or create new? (use/paste/new)" "use"
    case "${REPLY,,}" in
      use|u)
        STATE_SOURCE="$local_state"
        RESTORE_MODE="true"
        STATE_SOURCE_LABEL="$local_state"
        ;;
      paste|p)
        _prompt_pasted_state || die "Paste was empty. Run install.sh again and choose use, paste, or new."
        ;;
      new|n)
        RESTORE_MODE="false"
        REPLACE_LOCAL_STATE="true"
        log "A new server will replace ${local_state} after you confirm"
        ;;
      *)
        die "Choose use, paste, or new"
        ;;
    esac
  else
    prompt_multiline_end "Paste server.json (line with only END when finished; empty first line = new server)"
    if [[ -n "${REPLY}" ]]; then
      _store_pasted_state "${REPLY}"
    fi
  fi

  local port_default="443"
  if [[ "$RESTORE_MODE" == "true" ]]; then
    local state_domain
    _require_jq
    if ! jq -e . "$STATE_SOURCE" >/dev/null 2>&1; then
      die "Server file is not valid JSON: ${STATE_SOURCE_LABEL}"
    fi
    state_domain="$(jq -r '.domain // empty' "$STATE_SOURCE")"
    [[ -n "$state_domain" ]] || die "State file has no domain: ${STATE_SOURCE_LABEL}"
    normalize_domain "$state_domain"
    state_domain="${REPLY}"
    if [[ "$state_domain" != "$DOMAIN" ]]; then
      [[ -n "${STATE_PASTE_TEMP}" ]] && rm -f "${STATE_PASTE_TEMP}"
      die "Domain mismatch: wizard=${DOMAIN}, state=${state_domain}. The firewall was not changed."
    fi
    validate_state_json "$(cat "$STATE_SOURCE")"
    port_default="$(jq -r '.port' "$STATE_SOURCE")"
    prompt "How many new clients to add" "0"
    ADD_CLIENTS="${REPLY}"
    [[ "$ADD_CLIENTS" =~ ^[0-9]+$ ]] || die "Client count must be a number"
  else
    prompt "Number of clients" "1"
    CLIENT_COUNT="${REPLY}"
    [[ "$CLIENT_COUNT" =~ ^[0-9]+$ ]] || die "Client count must be a number"
    (( CLIENT_COUNT >= 1 )) || die "Need at least one client"
  fi

  prompt "UDP port" "$port_default"
  WIZARD_PORT="${REPLY}"
  [[ "$WIZARD_PORT" =~ ^[0-9]+$ ]] || die "UDP port must be a number"
  (( WIZARD_PORT >= 1 && WIZARD_PORT <= 65535 )) || die "UDP port must be between 1 and 65535"

  PUBLIC_IP="$(detect_public_ip)"
  echo
  log "Summary of choices"
  echo "  Domain:       ${DOMAIN}"
  echo "  Public IP:    ${PUBLIC_IP:-unknown}"
  echo "  Deploy dir:   ${DEPLOY_DIR}"
  echo "  UDP port:     ${WIZARD_PORT}"
  if [[ "$RESTORE_MODE" == "true" ]]; then
    echo "  Mode:         restore from ${STATE_SOURCE_LABEL}"
    echo "  Add clients:  ${ADD_CLIENTS}"
  elif [[ "$REPLACE_LOCAL_STATE" == "true" ]]; then
    echo "  Mode:         new server (replaces ${local_state})"
    echo "  Clients:      ${CLIENT_COUNT}"
  else
    echo "  Mode:         new server"
    echo "  Clients:      ${CLIENT_COUNT}"
  fi
  echo
  prompt "Proceed with installation?" "yes"
  if [[ "${REPLY,,}" != "yes" && "${REPLY,,}" != "y" ]]; then
    [[ -n "${STATE_PASTE_TEMP}" ]] && rm -f "${STATE_PASTE_TEMP}"
    die "Aborted by user"
  fi

  if command -v getent >/dev/null 2>&1 && [[ -n "$PUBLIC_IP" ]]; then
    local resolved
    resolved="$(getent ahostsv4 "$DOMAIN" 2>/dev/null | awk '{print $1; exit}' || true)"
    if [[ -n "$resolved" && "$resolved" != "$PUBLIC_IP" ]]; then
      warn "DNS for $DOMAIN resolves to $resolved, this host is $PUBLIC_IP — update the A record"
    fi
  fi
}
