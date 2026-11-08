#!/usr/bin/env bash
# Interactive wizard — short config for AmneziaWG

ask_config() {
  log "Configuration wizard"
  echo "Domain is required. Endpoint in client configs will use this name."
  echo "Empty state path → reuse local state, paste server.json, or create a new server."
  echo "To restore on another host: leave the path empty and paste server.json (end with END)."
  echo

  DOMAIN=""
  STATE_SOURCE=""
  STATE_SOURCE_LABEL=""
  STATE_PASTE_TEMP=""
  RESTORE_MODE="false"
  CLIENT_COUNT="1"
  ADD_CLIENTS="0"

  prompt "Domain name" ""
  DOMAIN="${REPLY}"
  [[ -n "$DOMAIN" ]] || die "Domain is required"
  DOMAIN="${DOMAIN,,}"
  DOMAIN="${DOMAIN#https://}"
  DOMAIN="${DOMAIN#http://}"
  DOMAIN="${DOMAIN%%/*}"
  DOMAIN="${DOMAIN%.}"

  prompt "Path to existing server.json (optional)" ""
  STATE_SOURCE="${REPLY}"

  local local_state="${DEPLOY_DIR}/state/server.json"
  if [[ -n "$STATE_SOURCE" ]]; then
    [[ -f "$STATE_SOURCE" ]] || die "State file not found: ${STATE_SOURCE}"
    RESTORE_MODE="true"
    STATE_SOURCE_LABEL="$STATE_SOURCE"
  elif [[ -f "$local_state" ]]; then
    STATE_SOURCE="$local_state"
    RESTORE_MODE="true"
    STATE_SOURCE_LABEL="$local_state"
    log "Found existing state at ${local_state}"
  else
    prompt_multiline_end "Paste server.json (line with only END when finished; empty first line = new server)"
    if [[ -n "${REPLY}" ]]; then
      if ! echo "${REPLY}" | jq -e . >/dev/null 2>&1; then
        die "Pasted server.json is not valid JSON"
      fi
      STATE_PASTE_TEMP="$(mktemp)"
      umask 077
      printf '%s' "${REPLY}" >"${STATE_PASTE_TEMP}"
      chmod 600 "${STATE_PASTE_TEMP}"
      STATE_SOURCE="${STATE_PASTE_TEMP}"
      RESTORE_MODE="true"
      STATE_SOURCE_LABEL="pasted server.json"
    fi
  fi

  if [[ "$RESTORE_MODE" == "true" ]]; then
    local state_domain
    state_domain="$(jq -r '.domain // empty' "$STATE_SOURCE")"
    [[ -n "$state_domain" ]] || die "State file has no domain: ${STATE_SOURCE_LABEL}"
    if [[ "$state_domain" != "$DOMAIN" ]]; then
      [[ -n "${STATE_PASTE_TEMP}" ]] && rm -f "${STATE_PASTE_TEMP}"
      die "Domain mismatch: wizard=${DOMAIN}, state=${state_domain}"
    fi
    prompt "How many new clients to add" "0"
    ADD_CLIENTS="${REPLY}"
    [[ "$ADD_CLIENTS" =~ ^[0-9]+$ ]] || die "Client count must be a number"
  else
    prompt "Number of clients" "1"
    CLIENT_COUNT="${REPLY}"
    [[ "$CLIENT_COUNT" =~ ^[0-9]+$ ]] || die "Client count must be a number"
    (( CLIENT_COUNT >= 1 )) || die "Need at least one client"
  fi

  PUBLIC_IP="$(detect_public_ip)"
  echo
  log "Summary of choices"
  echo "  Domain:       ${DOMAIN}"
  echo "  Public IP:    ${PUBLIC_IP:-unknown}"
  echo "  Deploy dir:   ${DEPLOY_DIR}"
  if [[ "$RESTORE_MODE" == "true" ]]; then
    echo "  Mode:         restore from ${STATE_SOURCE_LABEL}"
    echo "  Add clients:  ${ADD_CLIENTS}"
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
