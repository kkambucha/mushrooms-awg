#!/usr/bin/env bash
# Prepare deploy directory and start AmneziaWG container

AWG_RUNTIME_IMAGE="${AWG_RUNTIME_IMAGE:-mushrooms-awg/amneziawg-go:tcp}"

prepare_deploy_dir() {
  log "Preparing deploy directory ${DEPLOY_DIR}"
  mkdir -p \
    "${DEPLOY_DIR}/awg" \
    "${DEPLOY_DIR}/clients" \
    "${DEPLOY_DIR}/state"

  local tpl out
  tpl="$(cat "${REPO_DIR}/templates/docker-compose.yml.tpl")"
  out="${tpl//__AWG_RUNTIME_IMAGE__/${AWG_RUNTIME_IMAGE}}"
  out="${out//__DOCKER_BUILD_CONTEXT__/${REPO_DIR}/docker}"
  printf '%s\n' "$out" >"${DEPLOY_DIR}/docker-compose.yml"

  cp "${REPO_DIR}/templates/start.sh" "${DEPLOY_DIR}/start.sh"
  chmod 755 "${DEPLOY_DIR}/start.sh"
  log "Deploy directory ready: ${DEPLOY_DIR}"
  log "Runtime image: ${AWG_RUNTIME_IMAGE} (build context ${REPO_DIR}/docker)"
}

compose_up() {
  log "Building and starting Docker Compose in ${DEPLOY_DIR}"
  cd "${DEPLOY_DIR}"
  docker compose build
  docker compose up -d --remove-orphans
}

wait_for_awg() {
  local proto="${AWG_NETWORK:-udp}"
  local ss_flag="-uln"
  if [[ "$proto" == "tcp" ]]; then
    ss_flag="-tln"
  fi
  log "Waiting for AmneziaWG on ${proto^^} :${AWG_PORT}"
  local i
  for i in $(seq 1 90); do
    if docker ps --format '{{.Names}} {{.Status}}' | grep -q '^mushrooms_awg .*Up'; then
      if ss $ss_flag | grep -qE ":${AWG_PORT}\\b"; then
        if docker exec mushrooms_awg awg show awg0 >/dev/null 2>&1; then
          log "AmneziaWG is up (awg0 listening on ${AWG_PORT}/${proto})"
          return 0
        fi
      fi
    fi
    sleep 2
  done
  warn "Container logs:"
  docker logs --tail 80 mushrooms_awg 2>&1 || true
  die "AmneziaWG did not become ready on ${proto} port ${AWG_PORT}"
}
