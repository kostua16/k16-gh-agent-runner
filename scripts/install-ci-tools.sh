#!/usr/bin/env bash
# Installs CI and repository automation tools.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/install-common.sh
source "${SCRIPT_DIR}/install-common.sh"

ARCH="$(detect_arch)"

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
  ensure_runner_local_bin
  curl -fsSL -o /tmp/rtk-install.sh \
    "https://raw.githubusercontent.com/rtk-ai/rtk/refs/tags/v${RTK_VERSION}/install.sh"
  verify_sha256 "$RTK_INSTALL_SHA256" /tmp/rtk-install.sh
  as_runner "sh /tmp/rtk-install.sh"
  as_runner "mkdir -p ${RUNNER_HOME}/.claude && ${RUNNER_HOME}/.local/bin/rtk init -g --auto-patch"
  rm -f /tmp/rtk-install.sh
  as_runner "${RUNNER_HOME}/.local/bin/rtk --version"
fi

echo "==> CI tool installation complete"
