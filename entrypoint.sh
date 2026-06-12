#!/usr/bin/env bash
set -euo pipefail

RUNNER_USER="${RUNNER_USER:-runner}"
RUNNER_HOME="${RUNNER_HOME:-/home/runner}"
RUNNER_CONFIG_DIR="${RUNNER_CONFIG_DIR:-/config}"
DOCKER_SOCK="${DOCKER_SOCK:-/var/run/docker.sock}"

log() {
  echo "entrypoint: $*"
}

docker_sock_gid() {
  stat -c '%g' "$DOCKER_SOCK" 2>/dev/null || stat -f '%g' "$DOCKER_SOCK" 2>/dev/null
}

runner_has_gid() {
  local gid="$1"
  id -G "$RUNNER_USER" | tr ' ' '\n' | grep -qx "$gid"
}

ensure_docker_sock_group() {
  local gid group

  [[ -S "$DOCKER_SOCK" ]] || return 0

  if ! id "$RUNNER_USER" >/dev/null 2>&1; then
    log "warning: runner user ${RUNNER_USER} does not exist; skipping Docker socket group setup"
    return 0
  fi

  gid="$(docker_sock_gid || true)"
  if [[ ! "$gid" =~ ^[0-9]+$ ]]; then
    log "warning: could not detect group id for ${DOCKER_SOCK}; Docker jobs may fail"
    return 0
  fi

  if runner_has_gid "$gid"; then
    return 0
  fi

  group="$(getent group "$gid" | cut -d: -f1 || true)"
  if [[ -z "$group" ]]; then
    group="docker-host"
    if getent group "$group" >/dev/null 2>&1; then
      group="docker-host-${gid}"
    fi
    if ! groupadd --gid "$gid" "$group"; then
      log "warning: could not create group for ${DOCKER_SOCK} gid ${gid}; Docker jobs may fail"
      return 0
    fi
  fi

  if usermod -aG "$group" "$RUNNER_USER"; then
    log "added ${RUNNER_USER} to ${group} (${gid}) for ${DOCKER_SOCK}"
  else
    log "warning: could not add ${RUNNER_USER} to ${group}; Docker jobs may fail"
  fi
}

prepare_runner_paths() {
  mkdir -p "$RUNNER_CONFIG_DIR" "$RUNNER_HOME"
  chown -R "${RUNNER_USER}:${RUNNER_USER}" "$RUNNER_CONFIG_DIR"
  chown "${RUNNER_USER}:${RUNNER_USER}" "$RUNNER_HOME" 2>/dev/null || true
}

main() {
  if [[ $# -eq 0 ]]; then
    set -- /runner.sh
  fi

  if [[ "$(id -u)" -eq 0 ]]; then
    command -v gosu >/dev/null 2>&1 || {
      echo "error: gosu is required to drop privileges" >&2
      exit 1
    }

    ensure_docker_sock_group
    prepare_runner_paths
    exec gosu "$RUNNER_USER" "$@"
  fi

  exec "$@"
}

main "$@"
