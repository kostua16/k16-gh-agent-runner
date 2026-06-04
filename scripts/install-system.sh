#!/usr/bin/env bash
# Installs slow-changing system packages and native tools.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/install-common.sh
source "${SCRIPT_DIR}/install-common.sh"

detect_docker_arch() {
  local arch="$1"
  case "$arch" in
    amd64) echo "x86_64" ;;
    arm64) echo "aarch64" ;;
  esac
}

install_docker_tooling() {
  local arch docker_arch compose_arch
  arch="$(detect_arch)"
  docker_arch="$(detect_docker_arch "$arch")"
  case "$arch" in
    amd64) compose_arch="x86_64" ;;
    arm64) compose_arch="aarch64" ;;
  esac

  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    echo "==> Docker CLI and compose plugin already present"
    docker --version
    docker compose version
    return 0
  fi

  DOCKER_VERSION="${DOCKER_VERSION:-28.0.4}"
  echo "==> Installing Docker CLI ${DOCKER_VERSION}"
  curl -fsSL -o /tmp/docker.tgz \
    "https://download.docker.com/linux/static/stable/${docker_arch}/docker-${DOCKER_VERSION}.tgz"
  tar -xzf /tmp/docker.tgz -C /tmp
  install -m 755 /tmp/docker/docker /usr/local/bin/docker
  rm -rf /tmp/docker /tmp/docker.tgz
  docker --version

  DOCKER_COMPOSE_VERSION="${DOCKER_COMPOSE_VERSION:-2.38.2}"
  echo "==> Installing Docker Compose plugin ${DOCKER_COMPOSE_VERSION}"
  mkdir -p /usr/local/lib/docker/cli-plugins
  curl -fsSL -o /usr/local/lib/docker/cli-plugins/docker-compose \
    "https://github.com/docker/compose/releases/download/v${DOCKER_COMPOSE_VERSION}/docker-compose-linux-${compose_arch}"
  chmod +x /usr/local/lib/docker/cli-plugins/docker-compose
  docker compose version
}

install_yq() {
  local arch="$1"
  YQ_VERSION="${YQ_VERSION:-4.45.1}"
  echo "==> Installing yq ${YQ_VERSION}"
  curl -fsSL -o /usr/local/bin/yq \
    "https://github.com/mikefarah/yq/releases/download/v${YQ_VERSION}/yq_linux_${arch}"
  chmod +x /usr/local/bin/yq
  yq --version
}

install_shfmt() {
  local arch="$1"
  SHFMT_VERSION="${SHFMT_VERSION:-3.10.0}"
  echo "==> Installing shfmt ${SHFMT_VERSION}"
  curl -fsSL -o /usr/local/bin/shfmt \
    "https://github.com/mvdan/sh/releases/download/v${SHFMT_VERSION}/shfmt_v${SHFMT_VERSION}_linux_${arch}"
  chmod +x /usr/local/bin/shfmt
  shfmt --version
}

install_hadolint() {
  local arch="$1"
  local hadolint_arch asset
  HADOLINT_VERSION="${HADOLINT_VERSION:-2.12.0}"
  case "$arch" in
    amd64) hadolint_arch="x86_64" ;;
    arm64) hadolint_arch="arm64" ;;
  esac
  asset="hadolint-Linux-${hadolint_arch}"
  echo "==> Installing hadolint ${HADOLINT_VERSION}"
  curl -fsSL -o /usr/local/bin/hadolint \
    "https://github.com/hadolint/hadolint/releases/download/v${HADOLINT_VERSION}/${asset}"
  chmod +x /usr/local/bin/hadolint
  hadolint --version
}

install_gitleaks() {
  local arch="$1"
  local gitleaks_arch tarball
  GITLEAKS_VERSION="${GITLEAKS_VERSION:-8.22.1}"
  case "$arch" in
    amd64) gitleaks_arch="x64" ;;
    arm64) gitleaks_arch="arm64" ;;
  esac
  tarball="gitleaks_${GITLEAKS_VERSION}_linux_${gitleaks_arch}.tar.gz"
  echo "==> Installing gitleaks ${GITLEAKS_VERSION}"
  curl -fsSL -o "/tmp/${tarball}" \
    "https://github.com/gitleaks/gitleaks/releases/download/v${GITLEAKS_VERSION}/${tarball}"
  tar -xzf "/tmp/${tarball}" -C /tmp gitleaks
  install -m 755 /tmp/gitleaks /usr/local/bin/gitleaks
  rm -f "/tmp/${tarball}" /tmp/gitleaks
  gitleaks version
}

install_uv() {
  UV_VERSION="${UV_VERSION:-0.6.14}"
  echo "==> Installing uv ${UV_VERSION}"
  curl -fsSL "https://astral.sh/uv/${UV_VERSION}/install.sh" \
    | env UV_INSTALL_DIR=/usr/local/bin UV_NO_MODIFY_PATH=1 sh
  uv --version
}

echo "==> Installing apt packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y --no-install-recommends \
  ca-certificates \
  curl \
  git \
  jq \
  bc \
  python3 \
  unzip \
  ripgrep \
  gnupg \
  make \
  shellcheck \
  openssh-client \
  xz-utils \
  zstd

ARCH="$(detect_arch)"
install_docker_tooling

if getent group docker >/dev/null 2>&1 && id "$RUNNER_USER" >/dev/null 2>&1; then
  usermod -aG docker "$RUNNER_USER" || true
fi

make --version
shellcheck --version

install_yq "$ARCH"
install_shfmt "$ARCH"
install_hadolint "$ARCH"
install_gitleaks "$ARCH"
install_uv
configure_runner_path
clean_apt

echo "==> System tool installation complete"
