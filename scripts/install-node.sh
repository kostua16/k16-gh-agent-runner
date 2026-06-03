#!/usr/bin/env bash
# Installs Node.js, corepack package managers, and Bun.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/install-common.sh
source "${SCRIPT_DIR}/install-common.sh"

echo "==> Installing Node.js ${NODE_MAJOR:-22}.x"
export DEBIAN_FRONTEND=noninteractive
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
clean_apt

echo "==> Node tool installation complete"
