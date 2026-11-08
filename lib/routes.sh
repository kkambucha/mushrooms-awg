#!/usr/bin/env bash
# Build AllowedIPs as the complement of direct-route lists

ALLOWED_IPS_SHORT=""
ALLOWED_IPS_FULL=""

_routes_complement() {
  # stdin: list of CIDRs (comments/blank allowed) -> stdout: complement of 0.0.0.0/0 as CSV
  python3 - "$@" <<'PY'
import ipaddress
import sys

nets = []
for path in sys.argv[1:]:
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            nets.append(ipaddress.ip_network(line, strict=False))

# Always keep LAN out of the tunnel
for lan in ("10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16"):
    nets.append(ipaddress.ip_network(lan))

remaining = [ipaddress.ip_network("0.0.0.0/0")]
for net in ipaddress.collapse_addresses(nets):
    nxt = []
    for block in remaining:
        if net.subnet_of(block) or net == block:
            if block.subnet_of(net):
                continue
            nxt.extend(block.address_exclude(net))
        else:
            nxt.append(block)
    remaining = nxt

print(",".join(str(n) for n in remaining))
PY
}

build_allowed_ips() {
  local short_file="${REPO_DIR}/routes/direct.txt"
  local extra_file="${REPO_DIR}/routes/direct-extra.txt"
  [[ -f "$short_file" ]] || die "Missing ${short_file}"
  [[ -f "$extra_file" ]] || die "Missing ${extra_file}"

  log "Building AllowedIPs (short for QR, full for optional .conf)"
  ALLOWED_IPS_SHORT="$(_routes_complement "$short_file")"
  ALLOWED_IPS_FULL="$(_routes_complement "$short_file" "$extra_file")"

  local short_count full_count
  short_count="$(awk -F',' '{print NF}' <<<"$ALLOWED_IPS_SHORT")"
  full_count="$(awk -F',' '{print NF}' <<<"$ALLOWED_IPS_FULL")"
  log "AllowedIPs short: ${short_count} routes; full: ${full_count} routes"
}
