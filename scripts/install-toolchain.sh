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
  gnupg

echo "==> Installing Node.js ${NODE_MAJOR:-22}.x"
NODE_MAJOR="${NODE_MAJOR:-22}"
curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" | bash -
apt-get install -y --no-install-recommends nodejs
node -v
npm -v

echo "==> Installing Bun ${BUN_VERSION:-1.3.14}"
export BUN_INSTALL="/usr/local/bun"
export PATH="${BUN_INSTALL}/bin:${PATH}"
curl -fsSL https://bun.sh/install | bash -s "bun-v${BUN_VERSION:-1.3.14}"
ln -sf "${BUN_INSTALL}/bin/bun" /usr/local/bin/bun
bun --version

echo "==> Installing GitHub CLI ${GH_VERSION:-2.93.0}"
ARCH="$(detect_arch)"
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
