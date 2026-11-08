#!/usr/bin/env bash
# System dependencies: Docker, jq, curl, ufw, qrencode, python3

ensure_jq() {
  if command -v jq >/dev/null 2>&1; then
    return 0
  fi
  log "Installing jq so the server file can be read"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y jq
  command -v jq >/dev/null 2>&1 || die "jq is required to read the server file and was not installed. The firewall was not changed."
}

ensure_docker_compose() {
  if docker compose version >/dev/null 2>&1; then
    log "docker compose OK: $(docker compose version --short 2>/dev/null || docker compose version | head -n1)"
    return 0
  fi

  log "Installing / repairing Docker via get.docker.com (includes compose plugin)"
  curl -fsSL https://get.docker.com | sh
  systemctl enable --now docker || true

  if docker compose version >/dev/null 2>&1; then
    log "docker compose OK after get.docker.com"
    return 0
  fi

  die "docker compose is still missing. Install official Docker from https://get.docker.com"
}

install_deps() {
  log "Installing dependencies"
  echo "Note: runtime directory ${DEPLOY_DIR} is created only AFTER deps succeed."

  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y \
    ca-certificates curl gnupg lsb-release \
    jq openssl dnsutils \
    ufw \
    qrencode \
    python3

  if ! command -v docker >/dev/null 2>&1; then
    log "Docker not found — installing via get.docker.com"
  else
    log "Docker binary present — ensuring compose plugin works"
  fi
  ensure_docker_compose

  command -v jq >/dev/null 2>&1 || die "jq is required"
  command -v curl >/dev/null 2>&1 || die "curl is required"
  command -v python3 >/dev/null 2>&1 || die "python3 is required"
  command -v qrencode >/dev/null 2>&1 || die "qrencode is required"
}

configure_sysctl() {
  log "Enabling IPv4 forwarding"
  mkdir -p /etc/sysctl.d
  cat >/etc/sysctl.d/99-mushrooms-awg.conf <<EOF
net.ipv4.ip_forward=1
EOF
  sysctl -w net.ipv4.ip_forward=1 >/dev/null
}

detect_ssh_ports() {
  local ports=""
  if command -v sshd >/dev/null 2>&1; then
    ports="$(sshd -T 2>/dev/null | awk 'tolower($1)=="port" && $2 ~ /^[0-9]+$/ {print $2}' | sort -u || true)"
  fi
  if [[ -z "$ports" ]] && command -v ss >/dev/null 2>&1; then
    ports="$(ss -H -lntp 2>/dev/null | awk '
      /sshd/ {
        n = $4
        sub(/^.*:/, "", n)
        if (n ~ /^[0-9]+$/) print n
      }
    ' | sort -u || true)"
  fi
  printf '%s\n' "$ports"
}

_enable_ufw_ip_forward() {
  local f="/etc/ufw/sysctl.conf"
  sysctl -w net.ipv4.ip_forward=1 >/dev/null
  [[ -f "$f" ]] || return 0
  if grep -qE '^[# ]*net/ipv4/ip_forward=' "$f"; then
    sed -i -E 's|^[# ]*net/ipv4/ip_forward=.*|net/ipv4/ip_forward=1|' "$f"
  else
    printf '\nnet/ipv4/ip_forward=1\n' >>"$f"
  fi
}

_install_ufw_persistent_rules() {
  local subnet="$1" egress="$2"
  local rules="/etc/ufw/before.rules"
  if [[ ! -f "$rules" ]]; then
    warn "No ${rules}. Tunnel forwarding will be applied only when the container starts."
    return 0
  fi
  SUBNET="$subnet" EGRESS="$egress" python3 - "$rules" <<'PY'
import os
import pathlib
import re
import sys

path = pathlib.Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
text = re.sub(r"\n?# BEGIN mushrooms-awg\n.*?# END mushrooms-awg\n?", "\n", text, flags=re.S)
text = re.sub(r"\n?# BEGIN mushrooms-awg-nat\n.*?# END mushrooms-awg-nat\n?", "\n", text, flags=re.S)
if text.endswith("COMMIT"):
    text += "\n"
filter_rules = """
# BEGIN mushrooms-awg
-A ufw-before-input -i awg0 -j ACCEPT
-A ufw-before-forward -i awg0 -j ACCEPT
-A ufw-before-forward -o awg0 -j ACCEPT
# END mushrooms-awg
"""
marker = "\nCOMMIT\n"
idx = text.rfind(marker)
if idx == -1:
    sys.stderr.write("ufw before.rules has no COMMIT line\n")
    sys.exit(1)
text = text[:idx] + "\n" + filter_rules + text[idx:]
egress = os.environ.get("EGRESS", "").strip()
subnet = os.environ["SUBNET"].strip()
if egress:
    nat = f"""
# BEGIN mushrooms-awg-nat
*nat
:POSTROUTING ACCEPT [0:0]
-A POSTROUTING -s {subnet} -o {egress} -j MASQUERADE
COMMIT
# END mushrooms-awg-nat
"""
    text = text.rstrip() + "\n" + nat
else:
    sys.stderr.write("WARN: no default route; persistent NAT rule was not written\n")
path.write_text(text, encoding="utf-8")
PY
}

_ufw_rule_listed() {
  local rule="$1"
  # Match To-column entries like "22/tcp" or "22/tcp (OpenSSH)".
  LC_ALL=C ufw status 2>/dev/null | grep -qE "^${rule}([[:space:]]| \\()"
}

_ufw_allow_once() {
  # Drop duplicate allow rules (bounded: ufw delete often exits 0 even when gone).
  local rule="$1"
  local i=0
  local max=32
  while ((i < max)); do
    if ! _ufw_rule_listed "$rule"; then
      break
    fi
    if ! ufw --force delete allow "$rule" >/dev/null 2>&1; then
      break
    fi
    i=$((i + 1))
  done
  ufw allow "$rule"
}

configure_ufw() {
  local port="$1" subnet="$2"
  local egress p
  local -a ssh_ports=()
  UFW_RELOADED="false"

  log "Configuring firewall"
  _enable_ufw_ip_forward
  egress="$(detect_egress_iface || true)"
  if [[ -n "$egress" && ! "$egress" =~ ^[A-Za-z0-9._:-]+$ ]]; then
    warn "Unexpected egress interface '${egress}'; persistent NAT rule skipped"
    egress=""
  fi
  if [[ ! "$subnet" =~ ^[0-9.]+/[0-9]+$ ]]; then
    die "Refusing to write firewall rules for subnet '${subnet}'"
  fi
  _install_ufw_persistent_rules "$subnet" "$egress"

  while IFS= read -r p; do
    [[ -n "$p" ]] || continue
    ssh_ports+=("$p")
  done < <(detect_ssh_ports)

  local active="false"
  if LC_ALL=C ufw status | grep -qi '^Status: active'; then
    active="true"
  fi

  if ((${#ssh_ports[@]} == 0)); then
    warn "Could not detect the SSH listen port. The firewall will not be switched on."
    if [[ "$active" == "false" ]]; then
      log "Firewall stays off. Tunnel UDP ${port} stays reachable because nothing is filtering it."
      return 0
    fi
    warn "Firewall is already on. Existing SSH rules were left unchanged. Opening tunnel UDP ${port} only."
  else
    for p in "${ssh_ports[@]}"; do
      if ! _ufw_allow_once "${p}/tcp"; then
        warn "Could not open SSH TCP ${p}. Open it manually if needed. Continuing install."
        return 0
      fi
    done
    log "Firewall allows SSH on TCP: ${ssh_ports[*]}"
  fi

  if ! _ufw_allow_once "${port}/udp"; then
    warn "Could not open tunnel UDP ${port}. Open it manually if needed. Continuing install."
    return 0
  fi
  log "Firewall allows tunnel UDP ${port}"

  if [[ "$active" == "false" ]]; then
    if ! ufw --force enable; then
      warn "ufw enable failed. Allow rules may be present but firewall is still off. Continuing install."
      return 0
    fi
  else
    if ! ufw reload; then
      warn "ufw reload failed. Continuing install."
      return 0
    fi
  fi
  sysctl -w net.ipv4.ip_forward=1 >/dev/null
  UFW_RELOADED="true"
}
