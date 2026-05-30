#!/usr/bin/env bash
set -euo pipefail

cd /home/runner

: "${GITHUB_URL:?GITHUB_URL is required}"
: "${RUNNER_TOKEN:?RUNNER_TOKEN is required}"

RUNNER_NAME="${RUNNER_NAME:-$(hostname)}"
RUNNER_LABELS="${RUNNER_LABELS:-self-hosted,Linux,X64,docker}"

config_args=(
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

./run.sh &
runner_pid=$!

cleanup() {
  echo "Removing runner..."
  kill -TERM "$runner_pid" 2>/dev/null || true
  wait "$runner_pid" 2>/dev/null || true
  ./config.sh remove --token "${RUNNER_TOKEN}" || true
}

trap cleanup EXIT INT TERM

wait "$runner_pid"
