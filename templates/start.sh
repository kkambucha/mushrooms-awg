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

iptables -C INPUT -i awg0 -j ACCEPT 2>/dev/null || iptables -A INPUT -i awg0 -j ACCEPT
iptables -C FORWARD -i awg0 -j ACCEPT 2>/dev/null || iptables -A FORWARD -i awg0 -j ACCEPT
iptables -C FORWARD -o awg0 -j ACCEPT 2>/dev/null || iptables -A FORWARD -o awg0 -j ACCEPT
iptables -C FORWARD -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null \
  || iptables -A FORWARD -m state --state ESTABLISHED,RELATED -j ACCEPT

iptables -t nat -C POSTROUTING -o "$EGRESS" -j MASQUERADE 2>/dev/null \
  || iptables -t nat -A POSTROUTING -o "$EGRESS" -j MASQUERADE

echo "AmneziaWG is up on awg0 (egress=${EGRESS})"
exec tail -f /dev/null
