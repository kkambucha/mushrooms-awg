#!/bin/bash
# Container entrypoint: bring up awg0 and NAT peer traffic

set -euo pipefail

CONF="/opt/amnezia/awg/awg0.conf"
[[ -f "$CONF" ]] || { echo "ERROR: missing ${CONF}"; exit 1; }

# Down any previous interface (restart path)
awg-quick down "$CONF" 2>/dev/null || true
awg-quick up "$CONF"

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
