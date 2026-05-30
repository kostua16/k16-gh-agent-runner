#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# Committed build config (no secrets). Prefer .env.build if you renamed env.build.
if [[ -n "${ENV_BUILD_FILE:-}" ]]; then
  :
elif [[ -f .env.build ]]; then
  ENV_BUILD_FILE=.env.build
else
  ENV_BUILD_FILE=env.build
fi

docker compose \
  -f docker-compose.yml \
  -f docker-compose.build.yml \
  --env-file "$ENV_BUILD_FILE" \
  build runner
