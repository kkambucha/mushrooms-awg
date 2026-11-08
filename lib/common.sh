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
  # Inclusive range. openssl, not bash RANDOM (15 bits): H1–H4 need the full span.
  local lo="$1" hi="$2"
  local span=$((hi - lo + 1))
  local limit r
  limit=$(((4294967296 / span) * span))
  while true; do
    r=$((16#$(openssl rand -hex 4)))
    if ((r < limit)); then
      echo $((lo + r % span))
      return 0
    fi
  done
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

detect_egress_iface() {
  ip -4 route show default 2>/dev/null | awk '{print $5; exit}'
}

check_cpu_arch() {
  local machine
  machine="$(uname -m)"
  case "$machine" in
    x86_64|amd64) return 0 ;;
  esac
  if [[ -r /proc/sys/fs/binfmt_misc/qemu-x86_64 ]] || [[ -r /proc/sys/fs/binfmt_misc/qemu-x86_64-static ]]; then
    warn "CPU is ${machine}. The tunnel image is amd64; continuing because qemu-x86_64 emulation is installed."
    return 0
  fi
  die "CPU is ${machine}. The AmneziaWG image is amd64-only. Use an amd64 server, or install qemu-user-static and run this again. The firewall was not changed."
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

normalize_domain() {
  # Strip scheme/path/trailing dot, lowercase, require a hostname (labels + a dot).
  # Sets REPLY. Dies if empty or not a hostname (port/scheme leftovers). Firewall untouched.
  local raw="${1-}"
  local d="$raw"
  d="${d,,}"
  d="${d#https://}"
  d="${d#http://}"
  d="${d%%/*}"
  d="${d%.}"
  [[ -n "$d" ]] || die "Domain is required. The firewall was not changed."
  if [[ ! "$d" =~ ^([a-z0-9]([a-z0-9-]*[a-z0-9])?\.)+[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]]; then
    die "Domain must be a hostname (letters, digits, dots, hyphens; no port). Got: ${raw}. The firewall was not changed."
  fi
  REPLY="$d"
}
