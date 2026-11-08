#!/usr/bin/env bash
# Shared helpers for mushrooms-awg installer

set -euo pipefail

log()  { printf '\n==> %s\n' "$*"; }
warn() { printf 'WARN: %s\n' "$*" >&2; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

rand_hex() {
  local n="${1:-16}"
  local s
  s="$(openssl rand -hex "$(( (n + 1) / 2 ))")"
  printf '%s' "${s:0:${n}}"
}

rand_alnum() {
  local n="${1:-16}"
  local s
  s="$(openssl rand -hex "$n")"
  printf '%s' "${s:0:${n}}"
}

rand_int() {
  # inclusive range
  local lo="$1" hi="$2"
  echo $((lo + RANDOM % (hi - lo + 1)))
}

rand_port() {
  # 20000-50000
  echo $((20000 + RANDOM % 30001))
}

prompt() {
  # prompt "Label" "default" -> sets REPLY
  local label="$1"
  local def="${2-}"
  if [[ -n "$def" ]]; then
    read -r -p "$label [$def]: " REPLY || true
    REPLY="${REPLY:-$def}"
  else
    read -r -p "$label: " REPLY || true
  fi
}

prompt_multiline_end() {
  # Reads lines until a line with only END; empty first line → REPLY=""
  local label="$1"
  echo "$label"
  echo "(paste text, then a line with only END; leave the first line empty to skip)"
  local line first=1 buf=""
  while IFS= read -r line; do
    if [[ "$first" -eq 1 && -z "$line" ]]; then
      REPLY=""
      return 0
    fi
    first=0
    if [[ "$line" == "END" ]]; then
      break
    fi
    buf+="$line"$'\n'
  done
  REPLY="$buf"
}

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    die "Run as root: sudo bash install.sh"
  fi
}

detect_public_ip() {
  local ip=""
  ip="$(curl -4 -fsS --max-time 5 https://ifconfig.me 2>/dev/null || true)"
  if [[ -z "$ip" ]]; then
    ip="$(curl -4 -fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)"
  fi
  printf '%s' "$ip"
}

check_ubuntu() {
  if [[ ! -f /etc/os-release ]]; then
    warn "Cannot detect OS; continuing anyway"
    return 0
  fi
  # shellcheck source=/dev/null
  . /etc/os-release
  if [[ "${ID:-}" != "ubuntu" && "${ID:-}" != "debian" ]]; then
    warn "Expected Ubuntu/Debian, found ${ID:-unknown}"
  fi
  local ver="${VERSION_ID:-0}"
  local major="${ver%%.*}"
  if [[ "${ID:-}" == "ubuntu" && "$major" -lt 20 ]]; then
    die "Ubuntu 20.04+ required (found $ver)"
  fi
}

json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\r'/}"
  s="${s//$'\t'/\\t}"
  printf '%s' "$s"
}
