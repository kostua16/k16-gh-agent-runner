#!/usr/bin/env bash
# Installs CI toolchain into the actions-runner image (invoked from Dockerfile as root).
set -euo pipefail

RUNNER_USER="${RUNNER_USER:-runner}"
RUNNER_HOME="${RUNNER_HOME:-/home/runner}"

is_true() {
  case "${1,,}" in
    true | 1 | yes) return 0 ;;
    *) return 1 ;;
  esac
}

detect_arch() {
  local machine
  machine="$(uname -m)"
  case "$machine" in
    x86_64 | amd64) echo "amd64" ;;
    aarch64 | arm64) echo "arm64" ;;
    *)
      echo "unsupported architecture: $machine" >&2
      exit 1
      ;;
  esac
}

detect_gh_asset() {
  local arch="$1"
  case "$arch" in
    amd64) echo "linux_amd64" ;;
    arm64) echo "linux_arm64" ;;
  esac
}

verify_sha256() {
  local expected="$1"
  local file="$2"
  if command -v sha256sum >/dev/null 2>&1; then
    printf '%s  %s\n' "$expected" "$file" | sha256sum -c -
  else
    printf '%s  %s\n' "$expected" "$file" | shasum -a 256 -c -
  fi
}

as_runner() {
  local cmd="$1"
  su - "$RUNNER_USER" -c "$cmd"
}

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

  echo "==> Installing Docker CLI ${DOCKER_VERSION:-28.0.4}"
  DOCKER_VERSION="${DOCKER_VERSION:-28.0.4}"
  curl -fsSL -o /tmp/docker.tgz \
    "https://download.docker.com/linux/static/stable/${docker_arch}/docker-${DOCKER_VERSION}.tgz"
  tar -xzf /tmp/docker.tgz -C /tmp
  install -m 755 /tmp/docker/docker /usr/local/bin/docker
  rm -rf /tmp/docker /tmp/docker.tgz
  docker --version

  echo "==> Installing Docker Compose plugin ${DOCKER_COMPOSE_VERSION:-2.38.2}"
  DOCKER_COMPOSE_VERSION="${DOCKER_COMPOSE_VERSION:-2.38.2}"
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

echo "==> Installing Node.js ${NODE_MAJOR:-22}.x"
NODE_MAJOR="${NODE_MAJOR:-22}"
curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" | bash -
apt-get install -y --no-install-recommends nodejs
node -v
npm -v

echo "==> Enabling corepack (pnpm / yarn)"
corepack enable
corepack prepare pnpm@latest --activate 2>/dev/null || true

echo "==> Installing Bun ${BUN_VERSION:-1.3.14}"
export BUN_INSTALL="/usr/local/bun"
export PATH="${BUN_INSTALL}/bin:${PATH}"
curl -fsSL https://bun.sh/install | bash -s "bun-v${BUN_VERSION:-1.3.14}"
ln -sf "${BUN_INSTALL}/bin/bun" /usr/local/bin/bun
bun --version

install_yq "$ARCH"
install_shfmt "$ARCH"
install_hadolint "$ARCH"
install_gitleaks "$ARCH"
install_uv

echo "==> Installing GitHub CLI ${GH_VERSION:-2.93.0}"
GH_ASSET="$(detect_gh_asset "$ARCH")"
GH_VERSION="${GH_VERSION:-2.93.0}"
GH_TARBALL="gh_${GH_VERSION}_${GH_ASSET}.tar.gz"
curl -fsSL -o "/tmp/${GH_TARBALL}" \
  "https://github.com/cli/cli/releases/download/v${GH_VERSION}/${GH_TARBALL}"
tar -xzf "/tmp/${GH_TARBALL}" -C /tmp
install -m 755 "/tmp/gh_${GH_VERSION}_${GH_ASSET}/bin/gh" /usr/local/bin/gh
rm -rf "/tmp/gh_${GH_VERSION}_${GH_ASSET}" "/tmp/${GH_TARBALL}"
gh --version

if is_true "${INSTALL_GSD:-true}"; then
  echo "==> Installing GSD @opengsd/get-shit-done-redux@${GSD_VERSION:-1.1.0}"
  npm install -g "@opengsd/get-shit-done-redux@${GSD_VERSION:-1.1.0}"
fi

if is_true "${INSTALL_PRISMA:-true}"; then
  echo "==> Installing Prisma CLI ${PRISMA_VERSION:-latest}"
  if [[ "${PRISMA_VERSION:-latest}" == "latest" ]]; then
    npm install -g prisma
  else
    npm install -g "prisma@${PRISMA_VERSION}"
  fi
  prisma -v
fi

if is_true "${INSTALL_ACTIONLINT:-true}"; then
  echo "==> Installing actionlint ${ACTIONLINT_VERSION:-1.7.7}"
  ACTIONLINT_VERSION="${ACTIONLINT_VERSION:-1.7.7}"
  case "$ARCH" in
    amd64) ACTIONLINT_ARCH="amd64" ;;
    arm64) ACTIONLINT_ARCH="arm64" ;;
  esac
  ACTIONLINT_TARBALL="actionlint_${ACTIONLINT_VERSION}_linux_${ACTIONLINT_ARCH}.tar.gz"
  curl -fsSL -o "/tmp/${ACTIONLINT_TARBALL}" \
    "https://github.com/rhysd/actionlint/releases/download/v${ACTIONLINT_VERSION}/${ACTIONLINT_TARBALL}"
  tar -xzf "/tmp/${ACTIONLINT_TARBALL}" -C /tmp actionlint
  install -m 755 /tmp/actionlint /usr/local/bin/actionlint
  rm -f "/tmp/${ACTIONLINT_TARBALL}" /tmp/actionlint
  actionlint -version
fi

if is_true "${INSTALL_RTK:-true}"; then
  echo "==> Installing RTK ${RTK_VERSION:-0.35.0}"
  RTK_VERSION="${RTK_VERSION:-0.35.0}"
  RTK_INSTALL_SHA256="${RTK_INSTALL_SHA256:-9989e60e33a353e9e6802fab1fd410b96d1dd228b34e52402c32f3c8c2dd8c66}"
  mkdir -p "${RUNNER_HOME}/.local/bin"
  curl -fsSL -o /tmp/rtk-install.sh \
    "https://raw.githubusercontent.com/rtk-ai/rtk/refs/tags/v${RTK_VERSION}/install.sh"
  verify_sha256 "$RTK_INSTALL_SHA256" /tmp/rtk-install.sh
  chown -R "${RUNNER_USER}:${RUNNER_USER}" "${RUNNER_HOME}/.local"
  as_runner "sh /tmp/rtk-install.sh"
  as_runner "mkdir -p ~/.claude && ~/.local/bin/rtk init -g --auto-patch"
  rm -f /tmp/rtk-install.sh
  as_runner "~/.local/bin/rtk --version"
fi

if is_true "${INSTALL_CODEX:-true}"; then
  echo "==> Installing Codex CLI ${CODEX_VERSION:-latest}"
  if [[ "${CODEX_VERSION:-latest}" == "latest" ]]; then
    npm install -g @openai/codex
  else
    npm install -g "@openai/codex@${CODEX_VERSION}"
  fi
  codex --version
fi

if is_true "${INSTALL_CLAUDE_CODE:-true}"; then
  echo "==> Installing Claude Code (${CLAUDE_CODE_VERSION:-latest})"
  mkdir -p "${RUNNER_HOME}/.local/bin"
  chown -R "${RUNNER_USER}:${RUNNER_USER}" "${RUNNER_HOME}/.local"
  CLAUDE_INSTALL_CMD='curl -fsSL https://claude.ai/install.sh | bash'
  if [[ -n "${CLAUDE_CODE_VERSION:-}" && "${CLAUDE_CODE_VERSION}" != "latest" ]]; then
    CLAUDE_INSTALL_CMD="curl -fsSL https://claude.ai/install.sh | bash -s -- --version ${CLAUDE_CODE_VERSION}"
  fi
  as_runner "export DISABLE_AUTOUPDATER=1 CLAUDE_CODE_DISABLE_AUTOUPDATE=1; ${CLAUDE_INSTALL_CMD}"
  as_runner "claude --version"
fi

if is_true "${INSTALL_CURSOR_AGENT:-true}"; then
  echo "==> Installing Cursor Agent CLI"
  mkdir -p "${RUNNER_HOME}/.local/bin"
  chown -R "${RUNNER_USER}:${RUNNER_USER}" "${RUNNER_HOME}/.local"
  as_runner "export CURSOR_DISABLE_AUTO_UPDATE=1; curl https://cursor.com/install -fsS | bash"
  as_runner "agent --version"
fi

echo "==> Configuring PATH for ${RUNNER_USER}"
PROFILE_SNIPPET="/etc/profile.d/runner-toolchain.sh"
cat >"$PROFILE_SNIPPET" <<'EOF'
export PATH="/home/runner/.local/bin:/usr/local/bun/bin:${PATH}"
EOF
chmod 644 "$PROFILE_SNIPPET"

ENV_FILE="/etc/environment"
if grep -q 'runner-toolchain' "$ENV_FILE" 2>/dev/null; then
  :
else
  echo 'PATH="/home/runner/.local/bin:/usr/local/bun/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"' >>"$ENV_FILE"
fi

apt-get clean
rm -rf /var/lib/apt/lists/*

echo "==> Toolchain installation complete"
