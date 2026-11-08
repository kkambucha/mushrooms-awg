#!/usr/bin/env bash
# Prepare deploy directory and start AmneziaWG container

prepare_deploy_dir() {
  log "Preparing deploy directory ${DEPLOY_DIR}"
  mkdir -p \
    "${DEPLOY_DIR}/awg" \
    "${DEPLOY_DIR}/clients" \
    "${DEPLOY_DIR}/state"

  cp "${REPO_DIR}/templates/docker-compose.yml.tpl" "${DEPLOY_DIR}/docker-compose.yml"
  cp "${REPO_DIR}/templates/start.sh" "${DEPLOY_DIR}/start.sh"
  chmod 755 "${DEPLOY_DIR}/start.sh"
  log "Deploy directory ready: ${DEPLOY_DIR}"
}

compose_up() {
  log "Starting Docker Compose in ${DEPLOY_DIR}"
  cd "${DEPLOY_DIR}"
  docker compose pull
  docker compose up -d --remove-orphans
}

wait_for_awg() {
  log "Waiting for AmneziaWG on UDP :${AWG_PORT}"
  local i
  for i in $(seq 1 45); do
    if docker ps --format '{{.Names}} {{.Status}}' | grep -q '^mushrooms_awg .*Up'; then
      if ss -uln | grep -qE ":${AWG_PORT}\\b"; then
        if docker exec mushrooms_awg awg show awg0 >/dev/null 2>&1; then
          log "AmneziaWG is up (awg0 listening on ${AWG_PORT}/udp)"
          return 0
        fi
      fi
    fi
    sleep 2
  done
  warn "Container logs:"
  docker logs --tail 80 mushrooms_awg 2>&1 || true
  die "AmneziaWG did not become ready on UDP port ${AWG_PORT}"
}
