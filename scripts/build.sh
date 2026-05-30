#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

IMAGE="${IMAGE:-ghcr.io/kostua16/k16-gh-agent-runner}"
TAG="${TAG:-latest}"

docker build -t "${IMAGE}:${TAG}" -f Dockerfile .
