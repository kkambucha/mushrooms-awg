#!/usr/bin/env bash
# Build AllowedIPs as the complement of direct-route lists.
# IPv4 and IPv6 are separate: listed networks stay off the tunnel, the rest goes in.
# Private ranges are always off the tunnel (same idea as the direct lists).

ALLOWED_IPS_SHORT=""
ALLOWED_IPS_FULL=""

_routes_complement() {
  # args: route files. stdout: IPv4 complement, then IPv6 complement, one CSV.
  python3 - "$@" <<'PY'
import ipaddress
import sys


def load(paths):
    v4, v6 = [], []
    for path in paths:
        with open(path, encoding="utf-8") as f:
            for lineno, line in enumerate(f, 1):
                line = line.strip()
                if not line or line.startswith("#"):
                    continue
                try:
                    net = ipaddress.ip_network(line, strict=False)
                except ValueError as exc:
                    raise SystemExit(f"Bad route {path}:{lineno}: {line} ({exc})") from exc
                if net.version == 6:
                    v6.append(net)
                else:
                    v4.append(net)
    return v4, v6


def complement(nets, universe, always):
    nets = list(nets)
    for item in always:
        nets.append(ipaddress.ip_network(item))
    remaining = [ipaddress.ip_network(universe)]
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
    return remaining


def joined(paths):
    v4, v6 = load(paths)
    parts = complement(v4, "0.0.0.0/0", ("10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16"))
    parts += complement(v6, "::/0", ("fc00::/7", "fe80::/10"))
    return ",".join(str(n) for n in parts)


print(joined(sys.argv[1:]))
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
