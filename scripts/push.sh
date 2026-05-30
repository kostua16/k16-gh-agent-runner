#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

IMAGE="${IMAGE:-ghcr.io/kostua16/k16-gh-agent-runner}"
TAG="${TAG:-latest}"

if ! command -v gh >/dev/null 2>&1; then
  echo "gh CLI is required. Install: https://cli.github.com/" >&2
  exit 1
fi

if ! gh auth status >/dev/null 2>&1; then
  echo "Run: gh auth login" >&2
  exit 1
fi

USER="$(gh api user -q .login)"
echo "Logging in to ghcr.io as ${USER}..."
gh auth token | docker login ghcr.io -u "${USER}" --password-stdin

"${ROOT}/scripts/build.sh"

echo "Pushing ${IMAGE}:${TAG}..."
docker push "${IMAGE}:${TAG}"
