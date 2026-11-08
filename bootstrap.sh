#!/usr/bin/env bash
# Mushrooms-AWG bootstrap — apt, Docker, clone sources
# Usage (from a clean Ubuntu host):
#   curl -fsSL https://raw.githubusercontent.com/kkambucha/mushrooms-awg/main/bootstrap.sh | sudo bash

set -euo pipefail

SRC_DIR="${SRC_DIR:-/opt/mushrooms-awg-src}"
REPO_URL="${REPO_URL:-https://github.com/kkambucha/mushrooms-awg.git}"

on_error() {
  echo "ERROR: bootstrap failed — see messages above." >&2
  exit 1
}
trap on_error ERR

if [[ "${EUID}" -ne 0 ]]; then
  echo "ERROR: run as root (sudo)." >&2
  exit 1
fi

echo "==> Installing base packages (git, ca-certificates, curl)"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y git ca-certificates curl

echo "==> Ensuring Docker Compose"
if docker compose version >/dev/null 2>&1; then
  echo "docker compose OK: $(docker compose version --short 2>/dev/null || docker compose version | head -n1)"
else
  echo "Installing Docker via get.docker.com"
  curl -fsSL https://get.docker.com | sh
  systemctl enable --now docker
  docker compose version >/dev/null 2>&1 \
    || { echo "ERROR: docker compose is still missing after get.docker.com" >&2; exit 1; }
fi

echo "==> Fetching sources into ${SRC_DIR}"
if [[ -d "${SRC_DIR}/.git" ]]; then
  git -C "${SRC_DIR}" remote set-url origin "${REPO_URL}"
  git -C "${SRC_DIR}" fetch --prune origin
  git -C "${SRC_DIR}" reset --hard origin/main
elif [[ -e "${SRC_DIR}" ]]; then
  echo "ERROR: ${SRC_DIR} exists but is not a git repository — remove or rename it and retry." >&2
  exit 1
else
  git clone "${REPO_URL}" "${SRC_DIR}"
fi

trap - ERR
echo "OK: bootstrap finished. Next: cd ${SRC_DIR} && sudo bash install.sh"
