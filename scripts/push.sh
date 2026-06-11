#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

if [[ -n "${ENV_BUILD_FILE:-}" ]]; then
  :
elif [[ -f .env.build ]]; then
  ENV_BUILD_FILE=.env.build
else
  ENV_BUILD_FILE=env.build
fi

IMAGE="${IMAGE:-ghcr.io/kostua16/k16-gh-agent-runner}"
TAG="${TAG:-latest}"
PLATFORMS="${PLATFORMS:-linux/amd64,linux/arm64}"

load_env_build_defaults() {
  local line key value

  while IFS= read -r line || [[ -n "$line" ]]; do
    case "$line" in
      '' | '#'*)
        continue
        ;;
    esac

    key="${line%%=*}"
    value="${line#*=}"
    [[ "$key" =~ ^[A-Z0-9_]+$ ]] || continue

    if [[ -z "${!key+x}" ]]; then
      export "$key=$value"
    fi
  done <"$ENV_BUILD_FILE"
}

if ! command -v gh >/dev/null 2>&1; then
  echo "gh CLI is required. Install: https://cli.github.com/" >&2
  exit 1
fi

if ! command -v docker >/dev/null 2>&1; then
  echo "docker CLI is required." >&2
  exit 1
fi

if ! gh auth status >/dev/null 2>&1; then
  echo "Run: gh auth login" >&2
  exit 1
fi

if [[ ! -f "$ENV_BUILD_FILE" ]]; then
  echo "Build config file not found: ${ENV_BUILD_FILE}" >&2
  exit 1
fi

load_env_build_defaults

USER="$(gh api user -q .login)"
echo "Logging in to ghcr.io as ${USER}..."
gh auth token | docker login ghcr.io -u "${USER}" --password-stdin

if ! docker buildx inspect >/dev/null 2>&1; then
  docker buildx create --use >/dev/null
fi

BUILD_ARG_KEYS=(
  NODE_MAJOR
  BUN_VERSION
  GH_VERSION
  GSD_VERSION
  RTK_VERSION
  RTK_INSTALL_SHA256
  PRISMA_VERSION
  ACTIONLINT_VERSION
  CLAUDE_CODE_VERSION
  CODEX_VERSION
  GEMINI_CLI_VERSION
  DOCKER_VERSION
  DOCKER_COMPOSE_VERSION
  YQ_VERSION
  SHFMT_VERSION
  HADOLINT_VERSION
  GITLEAKS_VERSION
  UV_VERSION
  AI_TOOLS_CACHE_BUST
  INSTALL_RTK
  INSTALL_GSD
  INSTALL_PRISMA
  INSTALL_ACTIONLINT
  INSTALL_CLAUDE_CODE
  INSTALL_CODEX
  INSTALL_CURSOR_AGENT
  INSTALL_GEMINI_CLI
  INSTALL_ANTIGRAVITY_CLI
)
BUILD_ARGS=()

for key in "${BUILD_ARG_KEYS[@]}"; do
  BUILD_ARGS+=(--build-arg "${key}=${!key-}")
done

echo "Building and pushing ${IMAGE}:${TAG} for ${PLATFORMS}..."
docker buildx build \
  --file Dockerfile \
  --platform "${PLATFORMS}" \
  --push \
  --tag "${IMAGE}:${TAG}" \
  "${BUILD_ARGS[@]}" \
  .
