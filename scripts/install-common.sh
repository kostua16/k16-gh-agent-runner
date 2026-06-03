#!/usr/bin/env bash
# Shared helpers for image toolchain installer phases.
set -euo pipefail

RUNNER_USER="${RUNNER_USER:-runner}"
RUNNER_HOME="${RUNNER_HOME:-/home/runner}"

is_true() {
  case "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" in
    true | 1 | yes | y) return 0 ;;
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

ensure_runner_local_bin() {
  mkdir -p "${RUNNER_HOME}/.local/bin"
  chown -R "${RUNNER_USER}:${RUNNER_USER}" "${RUNNER_HOME}/.local"
}

configure_runner_path() {
  local profile_snippet="/etc/profile.d/runner-toolchain.sh"
  local env_file="/etc/environment"

  echo "==> Configuring PATH for ${RUNNER_USER}"
  cat >"$profile_snippet" <<'EOF'
export PATH="/home/runner/.local/bin:/usr/local/bun/bin:${PATH}"
EOF
  chmod 644 "$profile_snippet"

  if grep -q 'runner-toolchain' "$env_file" 2>/dev/null; then
    :
  else
    echo 'PATH="/home/runner/.local/bin:/usr/local/bun/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"' >>"$env_file"
  fi
}

clean_apt() {
  apt-get clean
  rm -rf /var/lib/apt/lists/*
}

install_npm_global() {
  local name="$1"
  local package="$2"
  local version="$3"
  local verify_command="$4"
  local spec="$package"

  if [[ -n "$version" && "$version" != "latest" ]]; then
    spec="${package}@${version}"
  fi

  echo "==> Installing ${name} ${version:-latest}"
  npm install -g "$spec"
  bash -lc "$verify_command"
}

install_npm_global_if_enabled() {
  local enabled="$1"
  shift

  if is_true "$enabled"; then
    install_npm_global "$@"
  else
    echo "==> Skipping $1"
  fi
}

install_runner_curl_bash() {
  local name="$1"
  local url="$2"
  local install_args="$3"
  local verify_command="$4"
  local env_exports="${5:-}"
  local install_command

  echo "==> Installing ${name}"
  ensure_runner_local_bin

  install_command="curl -fsSL \"${url}\" | bash"
  if [[ -n "$install_args" ]]; then
    install_command="${install_command} -s -- ${install_args}"
  fi
  if [[ -n "$env_exports" ]]; then
    install_command="export ${env_exports}; ${install_command}"
  fi

  as_runner "$install_command"
  as_runner "$verify_command"
}

install_runner_curl_bash_if_enabled() {
  local enabled="$1"
  shift

  if is_true "$enabled"; then
    install_runner_curl_bash "$@"
  else
    echo "==> Skipping $1"
  fi
}

usage() {
  cat <<'EOF'
Usage: install-common.sh <command> [args...]

Commands:
  is-true <value>
  npm-global-if-enabled <enabled> <name> <package> <version> <verify-command>
  runner-curl-bash-if-enabled <enabled> <name> <url> <install-args> <verify-command> [env-exports]
EOF
}

main() {
  local command="${1:-}"
  if [[ $# -gt 0 ]]; then
    shift
  fi

  case "$command" in
    is-true)
      [[ $# -eq 1 ]] || {
        usage >&2
        exit 2
      }
      is_true "$1"
      ;;
    npm-global-if-enabled)
      [[ $# -eq 5 ]] || {
        usage >&2
        exit 2
      }
      install_npm_global_if_enabled "$@"
      ;;
    runner-curl-bash-if-enabled)
      [[ $# -eq 5 || $# -eq 6 ]] || {
        usage >&2
        exit 2
      }
      install_runner_curl_bash_if_enabled "$@"
      ;;
    -h | --help | help)
      usage
      ;;
    *)
      usage >&2
      exit 2
      ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
