FROM ghcr.io/falcondev-oss/actions-runner:latest

ENV PATH="/home/runner/.local/bin:/usr/local/bun/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

USER root

COPY scripts/install-common.sh /tmp/toolchain/install-common.sh

# Slow-changing system packages and native binaries.
COPY scripts/install-system.sh /tmp/toolchain/install-system.sh
ARG DOCKER_VERSION=28.0.4
ARG DOCKER_COMPOSE_VERSION=2.38.2
ARG YQ_VERSION=4.45.1
ARG SHFMT_VERSION=3.10.0
ARG HADOLINT_VERSION=2.12.0
ARG GITLEAKS_VERSION=8.22.1
ARG UV_VERSION=0.6.14
RUN chmod +x /tmp/toolchain/install-common.sh /tmp/toolchain/install-system.sh && \
    DOCKER_VERSION="${DOCKER_VERSION}" \
    DOCKER_COMPOSE_VERSION="${DOCKER_COMPOSE_VERSION}" \
    YQ_VERSION="${YQ_VERSION}" \
    SHFMT_VERSION="${SHFMT_VERSION}" \
    HADOLINT_VERSION="${HADOLINT_VERSION}" \
    GITLEAKS_VERSION="${GITLEAKS_VERSION}" \
    UV_VERSION="${UV_VERSION}" \
    /tmp/toolchain/install-system.sh

# Runtime layer: Node/package managers and Bun.
COPY scripts/install-node.sh /tmp/toolchain/install-node.sh
ARG NODE_MAJOR=22
ARG BUN_VERSION=1.3.14
RUN chmod +x /tmp/toolchain/install-node.sh && \
    NODE_MAJOR="${NODE_MAJOR}" \
    BUN_VERSION="${BUN_VERSION}" \
    /tmp/toolchain/install-node.sh

# CI/repository tooling layer.
COPY scripts/install-ci-tools.sh /tmp/toolchain/install-ci-tools.sh
ARG GH_VERSION=2.93.0
ARG GSD_VERSION=1.1.0
ARG RTK_VERSION=0.35.0
ARG RTK_INSTALL_SHA256=9989e60e33a353e9e6802fab1fd410b96d1dd228b34e52402c32f3c8c2dd8c66
ARG PRISMA_VERSION=latest
ARG ACTIONLINT_VERSION=1.7.7
ARG INSTALL_RTK=true
ARG INSTALL_GSD=true
ARG INSTALL_PRISMA=true
ARG INSTALL_ACTIONLINT=true
RUN chmod +x /tmp/toolchain/install-ci-tools.sh && \
    GH_VERSION="${GH_VERSION}" \
    GSD_VERSION="${GSD_VERSION}" \
    RTK_VERSION="${RTK_VERSION}" \
    RTK_INSTALL_SHA256="${RTK_INSTALL_SHA256}" \
    PRISMA_VERSION="${PRISMA_VERSION}" \
    ACTIONLINT_VERSION="${ACTIONLINT_VERSION}" \
    INSTALL_RTK="${INSTALL_RTK}" \
    INSTALL_GSD="${INSTALL_GSD}" \
    INSTALL_PRISMA="${INSTALL_PRISMA}" \
    INSTALL_ACTIONLINT="${INSTALL_ACTIONLINT}" \
    /tmp/toolchain/install-ci-tools.sh

# Fast-moving AI CLIs. Set AI_TOOLS_CACHE_BUST to refresh latest-version installs.
ARG AI_TOOLS_CACHE_BUST=
RUN echo "AI_TOOLS_CACHE_BUST=${AI_TOOLS_CACHE_BUST:-none}"

ARG INSTALL_CODEX=true
ARG CODEX_VERSION=latest
RUN /tmp/toolchain/install-common.sh npm-global-if-enabled \
    "${INSTALL_CODEX}" \
    "Codex CLI" \
    "@openai/codex" \
    "${CODEX_VERSION}" \
    "codex --version"

ARG INSTALL_CLAUDE_CODE=true
ARG CLAUDE_CODE_VERSION=latest
RUN claude_args="" && \
    if [ -n "${CLAUDE_CODE_VERSION}" ] && [ "${CLAUDE_CODE_VERSION}" != "latest" ]; then \
      claude_args="--version ${CLAUDE_CODE_VERSION}"; \
    fi && \
    /tmp/toolchain/install-common.sh runner-curl-bash-if-enabled \
      "${INSTALL_CLAUDE_CODE}" \
      "Claude Code" \
      "https://claude.ai/install.sh" \
      "$claude_args" \
      "claude --version" \
      "DISABLE_AUTOUPDATER=1 CLAUDE_CODE_DISABLE_AUTOUPDATE=1"

ARG INSTALL_CURSOR_AGENT=true
RUN /tmp/toolchain/install-common.sh runner-curl-bash-if-enabled \
    "${INSTALL_CURSOR_AGENT}" \
    "Cursor Agent CLI" \
    "https://cursor.com/install" \
    "" \
    "agent --version" \
    "CURSOR_DISABLE_AUTO_UPDATE=1"

ARG INSTALL_GEMINI_CLI=true
ARG GEMINI_CLI_VERSION=latest
RUN /tmp/toolchain/install-common.sh npm-global-if-enabled \
    "${INSTALL_GEMINI_CLI}" \
    "Gemini CLI" \
    "@google/gemini-cli" \
    "${GEMINI_CLI_VERSION}" \
    "gemini --version"

ARG INSTALL_ANTIGRAVITY_CLI=true
RUN /tmp/toolchain/install-common.sh runner-curl-bash-if-enabled \
    "${INSTALL_ANTIGRAVITY_CLI}" \
    "Antigravity CLI" \
    "https://antigravity.google/cli/install.sh" \
    "--dir /home/runner/.local/bin" \
    "test -x /home/runner/.local/bin/agy"

COPY runner.sh /runner.sh
RUN chmod +x /runner.sh
USER runner
WORKDIR /home/runner
ENTRYPOINT ["/runner.sh"]
