#!/usr/bin/env bash
# Print and save deployment summary

write_summary() {
  local out="${DEPLOY_DIR}/DEPLOY.txt"
  local panel_host="${DOMAIN}"
  local client_lines=""
  local name

  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    client_lines+="  ${name}:"$'\n'
    client_lines+="    Short conf:  ${DEPLOY_DIR}/clients/${name}.conf"$'\n'
    if [[ -f "${DEPLOY_DIR}/clients/${name}.png" ]]; then
      client_lines+="    QR PNG:      ${DEPLOY_DIR}/clients/${name}.png"$'\n'
    else
      client_lines+="    QR PNG:      (skipped — conf too large for one QR)"$'\n'
    fi
    client_lines+="    Full conf:   ${DEPLOY_DIR}/clients/${name}.full.conf  (optional import)"$'\n'
  done < <(jq -r '.clients[].name' <<<"$STATE_JSON")

  : >"$out"
  chmod 600 "$out"

  {
    cat <<EOF
════════════════════════════════════════════════════════════
 Mushrooms-AWG / AmneziaWG deployment summary
 Generated: $(date -u +"%Y-%m-%d %H:%M:%S UTC")
════════════════════════════════════════════════════════════

DEPLOY DIRECTORY
  Path:           ${DEPLOY_DIR}
  Compose file:   ${DEPLOY_DIR}/docker-compose.yml
  This file:      ${out}
  State (keep):   ${DEPLOY_DIR}/state/server.json

  Source code (install.sh) is separate — e.g. /opt/mushrooms-awg-src
  Runtime exists only AFTER a successful install past dependencies.

RESTORE ON A NEW SERVER
  1. Keep the text of ${DEPLOY_DIR}/state/server.json (password manager / offline copy).
  2. Point the domain A record to the new public IP.
  3. Run bootstrap + install.sh; enter the same domain; leave the file path empty
     and paste server.json (finish with a line END). Or pass a file path instead.
  Existing client configs keep working — Endpoint uses the domain, not an IP.

SERVER
  Domain:         ${DOMAIN}
  Public IP:      ${PUBLIC_IP:-unknown}
  Listen:         ${AWG_PORT}/${AWG_NETWORK}
  Keygen image:   ${AWG_IMAGE}
  Runtime image:  ${AWG_RUNTIME_IMAGE:-mushrooms-awg/amneziawg-go:tcp}
  Interface:      awg0 (${SERVER_ADDRESS})

CLIENT PROFILES
  UDP (default): scan the QR or import the short .conf in AmneziaWG (iOS OK —
  no Network/Format lines). TCP: conf includes Network/Format*; use a client
  that accepts them (iOS AmneziaWG rejects TCP profiles — choose udp in wizard).
  After port/transport change, delete the old tunnel and import again.
  Optional: import the .full.conf for the wider direct-route list, then remove
  the short tunnel so only one profile remains on the phone.
  IPv4 goes through the tunnel except private/service ranges and the direct
  lists. IPv6 stays on the phone provider; the tunnel and peers are IPv4-only.
  AmneziaWG does not merge a second file into an existing tunnel.

${client_lines}
USEFUL COMMANDS
  cd ${DEPLOY_DIR}
  docker compose ps
  docker compose logs -f
  docker compose restart amneziawg
  docker exec mushrooms_awg awg show
  ufw status

════════════════════════════════════════════════════════════
EOF
  } >"$out"

  echo
  cat "$out"
  echo
  chmod 600 "$out"
  log "Summary saved to ${out} (mode 600)"
}
