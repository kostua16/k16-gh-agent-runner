#!/usr/bin/env bash
# Compatibility wrapper for running the complete image toolchain installer.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

"${SCRIPT_DIR}/install-system.sh"
"${SCRIPT_DIR}/install-node.sh"
"${SCRIPT_DIR}/install-ci-tools.sh"

"${SCRIPT_DIR}/install-common.sh" npm-global-if-enabled \
  "${INSTALL_CODEX:-true}" \
  "Codex CLI" \
  "@openai/codex" \
  "${CODEX_VERSION:-latest}" \
  "codex --version"

claude_args=""
if [[ -n "${CLAUDE_CODE_VERSION:-}" && "${CLAUDE_CODE_VERSION}" != "latest" ]]; then
  claude_args="--version ${CLAUDE_CODE_VERSION}"
fi
"${SCRIPT_DIR}/install-common.sh" runner-curl-bash-if-enabled \
  "${INSTALL_CLAUDE_CODE:-true}" \
  "Claude Code" \
  "https://claude.ai/install.sh" \
  "$claude_args" \
  "claude --version" \
  "DISABLE_AUTOUPDATER=1 CLAUDE_CODE_DISABLE_AUTOUPDATE=1"

"${SCRIPT_DIR}/install-common.sh" runner-curl-bash-if-enabled \
  "${INSTALL_CURSOR_AGENT:-true}" \
  "Cursor Agent CLI" \
  "https://cursor.com/install" \
  "" \
  "agent --version" \
  "CURSOR_DISABLE_AUTO_UPDATE=1"

"${SCRIPT_DIR}/install-common.sh" npm-global-if-enabled \
  "${INSTALL_GEMINI_CLI:-true}" \
  "Gemini CLI" \
  "@google/gemini-cli" \
  "${GEMINI_CLI_VERSION:-latest}" \
  "gemini --version"

"${SCRIPT_DIR}/install-common.sh" runner-curl-bash-if-enabled \
  "${INSTALL_ANTIGRAVITY_CLI:-true}" \
  "Antigravity CLI" \
  "https://antigravity.google/cli/install.sh" \
  "--dir ${RUNNER_HOME:-/home/runner}/.local/bin" \
  "test -x ${RUNNER_HOME:-/home/runner}/.local/bin/agy"

echo "==> Toolchain installation complete"
