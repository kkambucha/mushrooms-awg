#!/bin/bash
# Container entrypoint: bring up awg0 and NAT peer traffic

set -euo pipefail

CONF="/opt/amnezia/awg/awg0.conf"
UAPI_FILE="/opt/amnezia/awg/transport.uapi"
[[ -f "$CONF" ]] || { echo "ERROR: missing ${CONF}"; exit 1; }

_ensure_socat() {
  if command -v socat >/dev/null 2>&1; then
    return 0
  fi
  if command -v apk >/dev/null 2>&1; then
    echo "Installing socat (needed for AmneziaWG UAPI)"
    apk add --no-cache socat >/dev/null
  fi
  command -v socat >/dev/null 2>&1 || {
    echo "ERROR: socat is required to apply transport via UAPI" >&2
    return 1
  }
}

# Down any previous interface (restart path)
awg-quick down "$CONF" 2>/dev/null || true
awg-quick up "$CONF"

_wait_awg_sock() {
  local s i
  for i in $(seq 1 30); do
    for s in /var/run/amneziawg/awg0.sock /var/run/wireguard/awg0.sock; do
      if [[ -S "$s" ]]; then
        printf '%s' "$s"
        return 0
      fi
    done
    sleep 0.5
  done
  return 1
}

_uapi_set() {
  local sock="$1"
  local body="$2"
  local reply
  # Must connect(2) via socat — bash exec <> uses open(2) and fails with ENXIO.
  reply="$(printf 'set=1\n%s\n' "$body" | socat -t 5 - "UNIX-CONNECT:${sock}" 2>/dev/null || true)"
  printf '%s' "$reply"
  printf '%s' "$reply" | grep -q 'errno=0'
}

_apply_transport_uapi() {
  [[ -f "$UAPI_FILE" ]] || {
    echo "WARN: missing ${UAPI_FILE}; leaving default UDP transport"
    return 0
  }
  _ensure_socat

  local sock body network listen_port reply i
  sock="$(_wait_awg_sock)" || {
    echo "ERROR: AmneziaWG UAPI socket not found after awg-quick up" >&2
    return 1
  }
  body="$(cat "$UAPI_FILE")"
  network="$(awk -F= '/^network=/{print $2; exit}' "$UAPI_FILE")"
  listen_port="$(awk -F' *= *' 'tolower($1)=="listenport"{print $2; exit}' "$CONF")"

  echo "Applying transport UAPI from ${UAPI_FILE} via ${sock}"
  reply=""
  for i in 1 2 3 4 5 6 7 8; do
    if reply="$(_uapi_set "$sock" "$body")"; then
      break
    fi
    echo "UAPI attempt ${i} failed; retrying..."
    sleep 1
    sock="$(_wait_awg_sock)" || true
  done
  if ! printf '%s' "$reply" | grep -q 'errno=0'; then
    echo "ERROR: UAPI set failed (daemon rejected transport?). Reply:" >&2
    echo "$reply" >&2
    return 1
  fi
  echo "UAPI transport applied (network=${network:-unknown})"

  if [[ "$network" == "tcp" ]]; then
    [[ -n "$listen_port" ]] || {
      echo "ERROR: could not parse ListenPort from ${CONF}" >&2
      return 1
    }
    for i in 1 2 3 4 5 6 7 8 9 10; do
      if ss -tln 2>/dev/null | grep -qE ":${listen_port}\\b"; then
        echo "TCP listen OK on :${listen_port}"
        return 0
      fi
      sleep 1
    done
    echo "ERROR: transport=tcp but nothing listens on TCP :${listen_port}" >&2
    ss -tlnp 2>/dev/null || true
    ss -ulnp 2>/dev/null || true
    return 1
  fi
  return 0
}

_apply_transport_uapi

# Detect default egress interface for masquerade (host network mode)
EGRESS="$(ip -4 route show default 2>/dev/null | awk '{print $5; exit}')"
[[ -n "${EGRESS:-}" ]] || EGRESS="eth0"
SUBNET="$(ip -4 route show dev awg0 scope link 2>/dev/null | awk '{print $1; exit}')"
[[ -n "${SUBNET:-}" ]] || { echo "ERROR: could not determine awg0 subnet"; exit 1; }

# Drop any older copy (including one appended after the firewall reject), then insert at the top.
_ipt_top() {
  local table=""
  if [[ "$1" == "-t" ]]; then
    table="$2"
    shift 2
  fi
  local chain="$1"
  shift
  local -a bin=(iptables)
  if [[ -n "$table" ]]; then
    bin+=(-t "$table")
  fi
  while "${bin[@]}" -D "$chain" "$@" 2>/dev/null; do
    :
  done
  "${bin[@]}" -I "$chain" 1 "$@"
}

_ipt_top INPUT -i awg0 -j ACCEPT
_ipt_top FORWARD -i awg0 -j ACCEPT
_ipt_top FORWARD -o awg0 -j ACCEPT
_ipt_top FORWARD -m state --state ESTABLISHED,RELATED -j ACCEPT
_ipt_top -t nat POSTROUTING -s "$SUBNET" -o "$EGRESS" -j MASQUERADE

echo "AmneziaWG is up on awg0 (egress=${EGRESS} subnet=${SUBNET})"

# awg-quick backgrounds the userspace process and returns. Exit when that process
# (or the kernel interface) is gone so Docker restarts the container.
_backend_alive() {
  if [[ -d /sys/module/amneziawg ]]; then
    return 0
  fi
  local d comm
  for d in /proc/[0-9]*; do
    [[ -r "$d/comm" ]] || continue
    comm="$(cat "$d/comm" 2>/dev/null || true)"
    if [[ "$comm" == "amneziawg-go" ]]; then
      return 0
    fi
  done
  return 1
}

ready=0
for _ in 1 2 3 4 5; do
  if _backend_alive; then
    ready=1
    break
  fi
  sleep 1
done
if [[ "$ready" -ne 1 ]]; then
  echo "ERROR: awg0 is up but the AmneziaWG backend is not running" >&2
  exit 1
fi

while true; do
  if ! ip link show awg0 >/dev/null 2>&1; then
    echo "ERROR: awg0 disappeared" >&2
    exit 1
  fi
  if ! _backend_alive; then
    echo "ERROR: AmneziaWG backend exited" >&2
    exit 1
  fi
  sleep 2
done
