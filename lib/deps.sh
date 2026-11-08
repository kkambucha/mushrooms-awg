#!/usr/bin/env bash
# System dependencies: Docker, jq, curl, ufw, qrencode, python3

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

configure_ufw() {
  log "Configuring UFW"
  local port="$1"

  ufw allow OpenSSH >/dev/null 2>&1 || ufw allow 22/tcp >/dev/null 2>&1 || true
  ufw allow "${port}/udp" >/dev/null 2>&1 || true

  if ufw status | grep -qi inactive; then
    echo "y" | ufw enable || true
  fi
  ufw reload || true
  log "UFW allow: 22/tcp ${port}/udp"
}
