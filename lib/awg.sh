#!/usr/bin/env bash
# Render awg0.conf, client configs, and QR codes

QR_MAX_BYTES=2700
QR_SKIPPED=()

_render_replace() {
  local content="$1"
  shift
  local key val
  while (($# >= 2)); do
    key="$1"
    val="$2"
    content="${content//__${key}__/${val}}"
    shift 2
  done
  printf '%s' "$content"
}

render_awg0_conf() {
  log "Rendering awg0.conf"
  mkdir -p "${DEPLOY_DIR}/awg"
  local tpl peers peer_block client_pub client_addr
  tpl="$(cat "${REPO_DIR}/templates/awg0.conf.tpl")"
  peers=""

  while IFS=$'\t' read -r client_pub client_addr client_psk; do
    [[ -n "$client_pub" ]] || continue
    peer_block="$(cat <<EOF

[Peer]
PublicKey = ${client_pub}
PresharedKey = ${client_psk}
AllowedIPs = ${client_addr}
EOF
)"
    peers+="$peer_block"
  done < <(jq -r --arg fallback "${SERVER_PSK:-}" '
    .clients[]
    | [.public_key, .address, (if (.psk // "") != "" then .psk else $fallback end)]
    | @tsv
  ' <<<"$STATE_JSON")

  local out
  out="$(_render_replace "$tpl" \
    SERVER_PRIVATE_KEY "$SERVER_PRIVATE_KEY" \
    SERVER_ADDRESS "$SERVER_ADDRESS" \
    AWG_PORT "$AWG_PORT" \
    AWG_MTU "$AWG_MTU" \
    AWG_NETWORK "$AWG_NETWORK" \
    AWG_FORMAT_IN "$AWG_FORMAT_IN" \
    AWG_FORMAT_OUT "$AWG_FORMAT_OUT" \
    JC "$JC" \
    JMIN "$JMIN" \
    JMAX "$JMAX" \
    S1 "$S1" \
    S2 "$S2" \
    S3 "$S3" \
    S4 "$S4" \
    H1 "$H1" \
    H2 "$H2" \
    H3 "$H3" \
    H4 "$H4" \
    PEERS "$peers")"

  umask 077
  printf '%s\n' "$out" >"${DEPLOY_DIR}/awg/awg0.conf"
  chmod 600 "${DEPLOY_DIR}/awg/awg0.conf"
}

_write_client_conf() {
  local outfile="$1"
  local client_priv="$2"
  local client_addr="$3"
  local allowed_ips="$4"
  local client_psk="$5"
  local tpl out
  tpl="$(cat "${REPO_DIR}/templates/client.conf.tpl")"
  out="$(_render_replace "$tpl" \
    CLIENT_ADDRESS "$client_addr" \
    CLIENT_PRIVATE_KEY "$client_priv" \
    AWG_MTU "$AWG_MTU" \
    AWG_NETWORK "$AWG_NETWORK" \
    AWG_FORMAT_IN "$AWG_FORMAT_IN" \
    AWG_FORMAT_OUT "$AWG_FORMAT_OUT" \
    JC "$JC" \
    JMIN "$JMIN" \
    JMAX "$JMAX" \
    S1 "$S1" \
    S2 "$S2" \
    S3 "$S3" \
    S4 "$S4" \
    H1 "$H1" \
    H2 "$H2" \
    H3 "$H3" \
    H4 "$H4" \
    SERVER_PUBLIC_KEY "$SERVER_PUBLIC_KEY" \
    CLIENT_PSK "$client_psk" \
    ALLOWED_IPS "$allowed_ips" \
    DOMAIN "$DOMAIN" \
    AWG_PORT "$AWG_PORT")"
  umask 077
  printf '%s\n' "$out" >"$outfile"
  chmod 600 "$outfile"
}

render_client_configs() {
  log "Rendering client configs"
  mkdir -p "${DEPLOY_DIR}/clients"
  QR_SKIPPED=()

  local name priv addr psk short_path full_path short_bytes
  while IFS=$'\t' read -r name priv addr psk; do
    [[ -n "$name" ]] || continue
    short_path="${DEPLOY_DIR}/clients/${name}.conf"
    full_path="${DEPLOY_DIR}/clients/${name}.full.conf"
    _write_client_conf "$short_path" "$priv" "$addr" "$ALLOWED_IPS_SHORT" "$psk"
    _write_client_conf "$full_path" "$priv" "$addr" "$ALLOWED_IPS_FULL" "$psk"

    short_bytes="$(wc -c <"$short_path" | tr -d ' ')"
    if (( short_bytes <= QR_MAX_BYTES )); then
      qrencode -t PNG -o "${DEPLOY_DIR}/clients/${name}.png" <"$short_path"
      chmod 600 "${DEPLOY_DIR}/clients/${name}.png"
      log "QR written: ${DEPLOY_DIR}/clients/${name}.png (${short_bytes} bytes)"
    else
      QR_SKIPPED+=("$name")
      warn "Config ${name}.conf is ${short_bytes} bytes (>${QR_MAX_BYTES}) — QR skipped; use the .conf file"
      rm -f "${DEPLOY_DIR}/clients/${name}.png"
    fi
  done < <(jq -r --arg fallback "${SERVER_PSK:-}" '
    .clients[]
    | [.name, .private_key, .address, (if (.psk // "") != "" then .psk else $fallback end)]
    | @tsv
  ' <<<"$STATE_JSON")
}
