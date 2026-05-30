#!/usr/bin/env bash
set -euo pipefail

cd /home/runner

: "${GITHUB_URL:?GITHUB_URL is required}"

RUNNER_NAME="${RUNNER_NAME:-$(hostname)}"
RUNNER_LABELS="${RUNNER_LABELS:-self-hosted,Linux,X64,docker}"
RUNNER_CONFIG_DIR="${RUNNER_CONFIG_DIR:-/config}"
CONFIG_FILES=(.runner .credentials .credentials_rsaparams)

is_true() {
  case "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" in
    true | 1 | yes | y) return 0 ;;
    *) return 1 ;;
  esac
}

config_file_in_volume() {
  local file="$1"
  [[ -f "${RUNNER_CONFIG_DIR}/${file}" ]]
}

legacy_volume_layout() {
  [[ -f "${RUNNER_CONFIG_DIR}/bin/Runner.Listener.dll" ]]
}

sync_config_from_volume() {
  local file
  mkdir -p "$RUNNER_CONFIG_DIR"

  for file in "${CONFIG_FILES[@]}"; do
    if config_file_in_volume "$file"; then
      install -m 600 -D "${RUNNER_CONFIG_DIR}/${file}" "./${file}"
    fi
  done
}

sync_config_to_volume() {
  local file
  mkdir -p "$RUNNER_CONFIG_DIR"

  for file in "${CONFIG_FILES[@]}"; do
    if [[ -f "./${file}" ]]; then
      install -m 600 "./${file}" "${RUNNER_CONFIG_DIR}/${file}"
    fi
  done
}

runner_is_configured() {
  sync_config_from_volume
  [[ -f .runner ]] && [[ -f .credentials ]]
}

configure_runner() {
  : "${RUNNER_TOKEN:?RUNNER_TOKEN is required for initial runner registration}"

  local config_args=(
    --url "$GITHUB_URL"
    --token "$RUNNER_TOKEN"
    --name "$RUNNER_NAME"
    --labels "$RUNNER_LABELS"
    --unattended
  )

  if is_true "${RUNNER_REPLACE:-false}"; then
    config_args+=(--replace)
  fi

  if [[ "${RUNNER_DISABLE_UPDATE:-}" == "true" ]]; then
    config_args+=(--disableupdate)
  fi

  if [[ "${RUNNER_EPHEMERAL:-}" == "true" ]]; then
    config_args+=(--ephemeral)
  fi

  echo "Configuring runner ${RUNNER_NAME} for ${GITHUB_URL}"
  ./config.sh "${config_args[@]}"
  sync_config_to_volume
}

stop_listener() {
  local pid="$1" elapsed=0

  if ! kill -0 "$pid" 2>/dev/null; then
    return 0
  fi

  echo "Stopping runner listener..."
  kill -TERM "$pid" 2>/dev/null || true

  while kill -0 "$pid" 2>/dev/null && ((elapsed < 45)); do
    sleep 1
    elapsed=$((elapsed + 1))
  done

  if kill -0 "$pid" 2>/dev/null; then
    echo "warning: listener still running after ${elapsed}s; sending SIGKILL" >&2
    kill -KILL "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  else
    wait "$pid" 2>/dev/null || true
  fi
}

if runner_is_configured; then
  configured_url=""
  if command -v jq >/dev/null 2>&1; then
    configured_url="$(jq -r '.gitHubUrl // empty' .runner 2>/dev/null || true)"
  fi
  echo "Runner already configured; starting listener for ${RUNNER_NAME}"
  if [[ -n "$configured_url" && "$configured_url" != "$GITHUB_URL" ]]; then
    echo "warning: GITHUB_URL (${GITHUB_URL}) differs from configured (${configured_url})" >&2
  fi
  if legacy_volume_layout; then
    echo "note: detected legacy runner-data layout; config files were restored from volume" >&2
  fi
else
  configure_runner
fi

./run.sh &
runner_pid=$!

cleanup() {
  stop_listener "$runner_pid"

  if is_true "${RUNNER_REMOVE_ON_EXIT:-false}" && runner_is_configured; then
    echo "Deregistering runner from GitHub..."
    ./config.sh remove --unattended || true
    rm -f "${CONFIG_FILES[@]}"
    rm -f "${RUNNER_CONFIG_DIR}/"* 2>/dev/null || true
  fi
}

trap cleanup EXIT INT TERM

wait "$runner_pid"
