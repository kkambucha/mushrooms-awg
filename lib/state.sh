#!/usr/bin/env bash
# Persist and restore AmneziaWG server identity

AWG_IMAGE="${AWG_IMAGE:-amneziavpn/amneziawg-go:3.1.20260828}"
STATE_JSON=""
# Fixed AWG 3.1 stream framing (server view). Client swaps FormatIn/FormatOut.
AWG_DEFAULT_FORMAT_IN='<b 0x4567><dz be 4><r 12><d><t>'
AWG_DEFAULT_FORMAT_OUT='<b 0x1234><dz be 4><d>'

_awg_run() {
  # -i so pubkey can read the private key from stdin
  docker run --rm -i --platform linux/amd64 --entrypoint awg "$AWG_IMAGE" "$@"
}

awg_genkey() {
  _awg_run genkey
}

awg_pubkey() {
  # stdin private key -> stdout public key
  _awg_run pubkey
}

awg_genpsk() {
  _awg_run genpsk
}

generate_obfuscation() {
  JC="$(rand_int 4 6)"
  JMIN=50
  JMAX=150
  S1="$(rand_int 15 40)"
  S2="$(rand_int 15 40)"
  while (( S1 + 56 == S2 )); do
    S2="$(rand_int 15 40)"
  done
  S3="$(rand_int 8 20)"
  S4="$(rand_int 4 16)"

  local h1 h2 h3 h4
  while true; do
    h1="$(rand_int 5 2147483647)"
    h2="$(rand_int 5 2147483647)"
    h3="$(rand_int 5 2147483647)"
    h4="$(rand_int 5 2147483647)"
    if [[ "$h1" != "$h2" && "$h1" != "$h3" && "$h1" != "$h4" \
       && "$h2" != "$h3" && "$h2" != "$h4" && "$h3" != "$h4" ]]; then
      break
    fi
  done
  H1="$h1"
  H2="$h2"
  H3="$h3"
  H4="$h4"
}

_next_client_ip() {
  # given used last octet list as args, return next 10.8.1.N
  local used=("$@")
  local n=2
  while (( n <= 254 )); do
    local hit=0 u
    for u in "${used[@]}"; do
      if [[ "$u" == "$n" ]]; then
        hit=1
        break
      fi
    done
    if [[ "$hit" -eq 0 ]]; then
      echo "10.8.1.${n}"
      return 0
    fi
    n=$((n + 1))
  done
  die "No free client addresses left in 10.8.1.0/24"
}

create_new_state() {
  local count="$1"
  log "Generating new AmneziaWG state (${count} clients)"

  docker pull --platform linux/amd64 "$AWG_IMAGE" >/dev/null

  local server_priv server_pub port
  server_priv="$(awg_genkey)"
  server_pub="$(printf '%s' "$server_priv" | awg_pubkey)"
  port="${WIZARD_PORT:-443}"
  [[ "$port" =~ ^[0-9]+$ ]] || die "Tunnel port must be a number"
  (( port >= 1 && port <= 65535 )) || die "Tunnel port must be between 1 and 65535"
  local network="${WIZARD_NETWORK:-tcp}"
  [[ "$network" == "tcp" || "$network" == "udp" ]] || die "Transport must be tcp or udp"
  generate_obfuscation

  local clients_json="[]"
  local i used_octets=()
  for ((i = 1; i <= count; i++)); do
    local name ip cpriv cpub cpsk
    name="client${i}"
    if ((${#used_octets[@]})); then
      ip="$(_next_client_ip "${used_octets[@]}")"
    else
      ip="$(_next_client_ip)"
    fi
    used_octets+=("${ip##*.}")
    cpriv="$(awg_genkey)"
    cpub="$(printf '%s' "$cpriv" | awg_pubkey)"
    cpsk="$(awg_genpsk)"
    clients_json="$(jq -c \
      --arg name "$name" \
      --arg priv "$cpriv" \
      --arg pub "$cpub" \
      --arg addr "${ip}/32" \
      --arg psk "$cpsk" \
      '. + [{name:$name, private_key:$priv, public_key:$pub, address:$addr, psk:$psk}]' <<<"$clients_json")"
  done

  STATE_JSON="$(jq -n \
    --arg domain "$DOMAIN" \
    --argjson port "$port" \
    --arg network "$network" \
    --arg format_in "$AWG_DEFAULT_FORMAT_IN" \
    --arg format_out "$AWG_DEFAULT_FORMAT_OUT" \
    --arg server_priv "$server_priv" \
    --arg server_pub "$server_pub" \
    --arg subnet "10.8.1.0/24" \
    --arg server_addr "10.8.1.1/24" \
    --argjson mtu 1280 \
    --argjson jc "$JC" \
    --argjson jmin "$JMIN" \
    --argjson jmax "$JMAX" \
    --argjson s1 "$S1" \
    --argjson s2 "$S2" \
    --argjson s3 "$S3" \
    --argjson s4 "$S4" \
    --argjson h1 "$H1" \
    --argjson h2 "$H2" \
    --argjson h3 "$H3" \
    --argjson h4 "$H4" \
    --argjson clients "$clients_json" \
    '{
      domain: $domain,
      port: $port,
      subnet: $subnet,
      server_address: $server_addr,
      mtu: $mtu,
      server_private_key: $server_priv,
      server_public_key: $server_pub,
      psk: "",
      transport: {
        network: $network,
        format_in: $format_in,
        format_out: $format_out
      },
      obfuscation: {
        Jc: $jc, Jmin: $jmin, Jmax: $jmax,
        S1: $s1, S2: $s2, S3: $s3, S4: $s4,
        H1: $h1, H2: $h2, H3: $h3, H4: $h4
      },
      clients: $clients
    }')"
}

load_state_file() {
  local path="$1"
  log "Loading state from ${path}"
  STATE_JSON="$(jq -c '.' "$path")"
  normalize_domain "$(jq -r '.domain // empty' <<<"$STATE_JSON")"
  DOMAIN="${REPLY}"
  STATE_JSON="$(jq -c --arg domain "$DOMAIN" '.domain = $domain' <<<"$STATE_JSON")"
}

add_clients_to_state() {
  local n="$1"
  (( n > 0 )) || return 0
  log "Adding ${n} client(s) to state"

  docker pull --platform linux/amd64 "$AWG_IMAGE" >/dev/null

  local used_octets=()
  local addr octet
  while IFS= read -r addr; do
    [[ -n "$addr" ]] || continue
    octet="${addr%%/*}"
    octet="${octet##*.}"
    used_octets+=("$octet")
  done < <(jq -r '.clients[].address' <<<"$STATE_JSON")

  local existing_names
  existing_names="$(jq -r '.clients[].name' <<<"$STATE_JSON")"
  local i=1 added=0
  while (( added < n )); do
    local name="client${i}"
    if printf '%s\n' "$existing_names" | grep -qx "$name"; then
      i=$((i + 1))
      continue
    fi
    local ip cpriv cpub cpsk
    if ((${#used_octets[@]})); then
      ip="$(_next_client_ip "${used_octets[@]}")"
    else
      ip="$(_next_client_ip)"
    fi
    used_octets+=("${ip##*.}")
    cpriv="$(awg_genkey)"
    cpub="$(printf '%s' "$cpriv" | awg_pubkey)"
    cpsk="$(awg_genpsk)"
    STATE_JSON="$(jq -c \
      --arg name "$name" \
      --arg priv "$cpriv" \
      --arg pub "$cpub" \
      --arg addr "${ip}/32" \
      --arg psk "$cpsk" \
      '.clients += [{name:$name, private_key:$priv, public_key:$pub, address:$addr, psk:$psk}]' <<<"$STATE_JSON")"
    existing_names+=$'\n'"$name"
    added=$((added + 1))
    i=$((i + 1))
  done
}

apply_wizard_port() {
  # Align STATE_JSON.port with wizard choice; remember previous for UFW cleanup.
  PREV_AWG_PORT=""
  local current
  current="$(jq -r '.port' <<<"$STATE_JSON")"
  if [[ -z "${WIZARD_PORT:-}" ]]; then
    return 0
  fi
  if [[ "$WIZARD_PORT" == "$current" ]]; then
    return 0
  fi
  PREV_AWG_PORT="$current"
  PREV_AWG_PROTO="$(jq -r '.transport.network // "udp"' <<<"$STATE_JSON")"
  STATE_JSON="$(jq --argjson port "$WIZARD_PORT" '.port = $port' <<<"$STATE_JSON")"
  log "Tunnel port changed: ${PREV_AWG_PORT} → ${WIZARD_PORT}"
}

ensure_transport_in_state() {
  # Fill transport block; apply wizard network; remember previous proto for UFW.
  local net fmt_in fmt_out current_net
  net="${WIZARD_NETWORK:-tcp}"
  [[ "$net" == "tcp" || "$net" == "udp" ]] || die "Transport must be tcp or udp"

  current_net="$(jq -r '.transport.network // empty' <<<"$STATE_JSON")"
  fmt_in="$(jq -r '.transport.format_in // empty' <<<"$STATE_JSON")"
  fmt_out="$(jq -r '.transport.format_out // empty' <<<"$STATE_JSON")"
  if [[ -z "$fmt_in" || -z "$fmt_out" ]]; then
    fmt_in="$AWG_DEFAULT_FORMAT_IN"
    fmt_out="$AWG_DEFAULT_FORMAT_OUT"
  fi

  if [[ -z "$current_net" ]]; then
    # Legacy state had no transport — previous deploys listened on UDP.
    if [[ "$net" != "udp" ]]; then
      PREV_AWG_PROTO="udp"
      if [[ -z "${PREV_AWG_PORT:-}" ]]; then
        PREV_AWG_PORT="$(jq -r '.port' <<<"$STATE_JSON")"
      fi
      log "Transport set: udp (legacy) → ${net}"
    fi
  elif [[ "$current_net" != "$net" ]]; then
    PREV_AWG_PROTO="$current_net"
    if [[ -z "${PREV_AWG_PORT:-}" ]]; then
      PREV_AWG_PORT="$(jq -r '.port' <<<"$STATE_JSON")"
    fi
    log "Transport changed: ${current_net} → ${net}"
  fi

  STATE_JSON="$(jq -c \
    --arg network "$net" \
    --arg format_in "$fmt_in" \
    --arg format_out "$fmt_out" \
    '.transport = {network: $network, format_in: $format_in, format_out: $format_out}' \
    <<<"$STATE_JSON")"
}

write_state_file() {
  local out="${DEPLOY_DIR}/state/server.json"
  mkdir -p "${DEPLOY_DIR}/state"
  umask 077
  printf '%s\n' "$STATE_JSON" >"$out"
  chmod 600 "$out"
  log "State saved to ${out}"
}

validate_state_json() {
  local json="$1"
  local err missing
  err="$(jq -r '
    def need_str(k):
      if (.[k] | type) != "string" or (.[k] | length) == 0 then k else empty end;
    def base:
      [
        need_str("domain"),
        (if (.port | type) != "number" or .port < 1 or .port > 65535 then "port" else empty end),
        need_str("server_private_key"),
        need_str("server_public_key"),
        need_str("server_address"),
        (if (.subnet | type) != "string" then "subnet"
         elif ((.subnet | contains("/")) | not) then "subnet"
         else empty end),
        (if (.mtu | type) != "number" then "mtu" else empty end),
        (if (.clients | type) != "array" then "clients" else empty end),
        (if (.obfuscation | type) != "object" then "obfuscation" else empty end)
      ];
    def obf:
      if (.obfuscation | type) != "object" then empty
      else
        ["Jc","Jmin","Jmax","S1","S2","S3","S4","H1","H2","H3","H4"][] as $k
        | if (.obfuscation[$k] | type) != "number" then "obfuscation." + $k else empty end
      end;
    def clients_bad:
      if (.clients | type) != "array" then empty
      else
        .clients | to_entries[] | .key as $i | .value as $c
        | ["name","private_key","public_key","address"][] as $k
        | if ($c[$k] | type) != "string" or ($c[$k] | length) == 0 then "clients[\($i)].\($k)" else empty end
      end;
    def psk_bad:
      if (.clients | type) != "array" or (.clients | length) == 0 then empty
      elif (.psk | type) == "string" and (.psk | length) > 0 then empty
      else
        .clients | to_entries[]
        | if (.value.psk | type) != "string" or (.value.psk | length) == 0 then "clients[\(.key)].psk" else empty end
      end;
    def transport_bad:
      if (.transport | type) != "object" then empty
      elif (.transport.network != "tcp" and .transport.network != "udp") then "transport.network"
      elif (.transport.format_in | type) != "string" or (.transport.format_in | length) == 0 then "transport.format_in"
      elif (.transport.format_out | type) != "string" or (.transport.format_out | length) == 0 then "transport.format_out"
      else empty end;
    [base[], obf, clients_bad, psk_bad, transport_bad] | .[]
  ' <<<"$json")" || die "Server file could not be checked. Firewall was not changed."
  if [[ -n "$err" ]]; then
    [[ -n "${STATE_PASTE_TEMP:-}" && -f "${STATE_PASTE_TEMP}" ]] && rm -f "${STATE_PASTE_TEMP}"
    missing="${err//$'\n'/, }"
    die "Server file is incomplete (missing or empty: ${missing}). Firewall was not changed and the saved server file was not overwritten."
  fi
}

export_state_vars() {
  AWG_PORT="$(jq -r '.port' <<<"$STATE_JSON")"
  AWG_NETWORK="$(jq -r '.transport.network // "tcp"' <<<"$STATE_JSON")"
  AWG_FORMAT_IN="$(jq -r '.transport.format_in // empty' <<<"$STATE_JSON")"
  AWG_FORMAT_OUT="$(jq -r '.transport.format_out // empty' <<<"$STATE_JSON")"
  SERVER_PRIVATE_KEY="$(jq -r '.server_private_key' <<<"$STATE_JSON")"
  SERVER_PUBLIC_KEY="$(jq -r '.server_public_key' <<<"$STATE_JSON")"
  SERVER_PSK="$(jq -r '.psk // empty' <<<"$STATE_JSON")"
  AWG_SUBNET="$(jq -r '.subnet // empty' <<<"$STATE_JSON")"
  SERVER_ADDRESS="$(jq -r '.server_address' <<<"$STATE_JSON")"
  AWG_MTU="$(jq -r '.mtu' <<<"$STATE_JSON")"
  JC="$(jq -r '.obfuscation.Jc' <<<"$STATE_JSON")"
  JMIN="$(jq -r '.obfuscation.Jmin' <<<"$STATE_JSON")"
  JMAX="$(jq -r '.obfuscation.Jmax' <<<"$STATE_JSON")"
  S1="$(jq -r '.obfuscation.S1' <<<"$STATE_JSON")"
  S2="$(jq -r '.obfuscation.S2' <<<"$STATE_JSON")"
  S3="$(jq -r '.obfuscation.S3' <<<"$STATE_JSON")"
  S4="$(jq -r '.obfuscation.S4' <<<"$STATE_JSON")"
  H1="$(jq -r '.obfuscation.H1' <<<"$STATE_JSON")"
  H2="$(jq -r '.obfuscation.H2' <<<"$STATE_JSON")"
  H3="$(jq -r '.obfuscation.H3' <<<"$STATE_JSON")"
  H4="$(jq -r '.obfuscation.H4' <<<"$STATE_JSON")"
}
