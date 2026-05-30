#!/usr/bin/env bash
set -euo pipefail

cd /home/runner

: "${GITHUB_URL:?GITHUB_URL is required}"

RUNNER_NAME="${RUNNER_NAME:-$(hostname)}"
RUNNER_LABELS="${RUNNER_LABELS:-self-hosted,Linux,X64,docker}"

is_true() {
  case "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" in
    true | 1 | yes | y) return 0 ;;
    *) return 1 ;;
  esac
}

runner_is_configured() {
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
    --replace
  )

  if [[ "${RUNNER_DISABLE_UPDATE:-}" == "true" ]]; then
    config_args+=(--disableupdate)
  fi

  if [[ "${RUNNER_EPHEMERAL:-}" == "true" ]]; then
    config_args+=(--ephemeral)
  fi

  echo "Configuring runner ${RUNNER_NAME} for ${GITHUB_URL}"
  ./config.sh "${config_args[@]}"
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
else
  configure_runner
fi

./run.sh &
runner_pid=$!

cleanup() {
  echo "Stopping runner listener..."
  kill -TERM "$runner_pid" 2>/dev/null || true
  wait "$runner_pid" 2>/dev/null || true

  if is_true "${RUNNER_REMOVE_ON_EXIT:-false}" && runner_is_configured; then
    echo "Deregistering runner from GitHub..."
    ./config.sh remove --unattended || true
  fi
}

trap cleanup EXIT INT TERM

wait "$runner_pid"
