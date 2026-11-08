#!/usr/bin/env bash
# Persist and restore AmneziaWG server identity

AWG_IMAGE="${AWG_IMAGE:-amneziavpn/amneziawg-go:3.1.20260828}"
STATE_JSON=""

_awg_run() {
  # Run awg tools from the pinned image without starting a daemon
  docker run --rm --platform linux/amd64 --entrypoint awg "$AWG_IMAGE" "$@"
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

  local server_priv server_pub psk port
  server_priv="$(awg_genkey)"
  server_pub="$(printf '%s' "$server_priv" | awg_pubkey)"
  psk="$(awg_genpsk)"
  port="$(rand_port)"
  generate_obfuscation

  local clients_json="[]"
  local i used_octets=()
  for ((i = 1; i <= count; i++)); do
    local name ip cpriv cpub
    name="client${i}"
    if ((${#used_octets[@]})); then
      ip="$(_next_client_ip "${used_octets[@]}")"
    else
      ip="$(_next_client_ip)"
    fi
    used_octets+=("${ip##*.}")
    cpriv="$(awg_genkey)"
    cpub="$(printf '%s' "$cpriv" | awg_pubkey)"
    clients_json="$(jq -c \
      --arg name "$name" \
      --arg priv "$cpriv" \
      --arg pub "$cpub" \
      --arg addr "${ip}/32" \
      '. + [{name:$name, private_key:$priv, public_key:$pub, address:$addr}]' <<<"$clients_json")"
  done

  STATE_JSON="$(jq -n \
    --arg domain "$DOMAIN" \
    --argjson port "$port" \
    --arg server_priv "$server_priv" \
    --arg server_pub "$server_pub" \
    --arg psk "$psk" \
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
      psk: $psk,
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
  DOMAIN="$(jq -r '.domain' <<<"$STATE_JSON")"
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
    local ip cpriv cpub
    if ((${#used_octets[@]})); then
      ip="$(_next_client_ip "${used_octets[@]}")"
    else
      ip="$(_next_client_ip)"
    fi
    used_octets+=("${ip##*.}")
    cpriv="$(awg_genkey)"
    cpub="$(printf '%s' "$cpriv" | awg_pubkey)"
    STATE_JSON="$(jq -c \
      --arg name "$name" \
      --arg priv "$cpriv" \
      --arg pub "$cpub" \
      --arg addr "${ip}/32" \
      '.clients += [{name:$name, private_key:$priv, public_key:$pub, address:$addr}]' <<<"$STATE_JSON")"
    existing_names+=$'\n'"$name"
    added=$((added + 1))
    i=$((i + 1))
  done
}

write_state_file() {
  local out="${DEPLOY_DIR}/state/server.json"
  mkdir -p "${DEPLOY_DIR}/state"
  umask 077
  printf '%s\n' "$STATE_JSON" >"$out"
  chmod 600 "$out"
  log "State saved to ${out}"
}

export_state_vars() {
  AWG_PORT="$(jq -r '.port' <<<"$STATE_JSON")"
  SERVER_PRIVATE_KEY="$(jq -r '.server_private_key' <<<"$STATE_JSON")"
  SERVER_PUBLIC_KEY="$(jq -r '.server_public_key' <<<"$STATE_JSON")"
  SERVER_PSK="$(jq -r '.psk' <<<"$STATE_JSON")"
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
