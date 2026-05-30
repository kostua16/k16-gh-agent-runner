#!/usr/bin/env bash
# Bootstrap ~/k16-gh-agent-runner and start the runner stack.
# One-liner: curl -fsSL https://raw.githubusercontent.com/kostua16/k16-gh-agent-runner/main/install.sh | bash
set -euo pipefail

if ((BASH_VERSINFO[0] < 4)); then
  echo "error: bash 4+ is required (install.sh uses associative arrays)" >&2
  exit 1
fi

INSTALL_DIR="${INSTALL_DIR:-$HOME/k16-gh-agent-runner}"
GITHUB_REPO="${GITHUB_REPO:-kostua16/k16-gh-agent-runner}"
GITHUB_BRANCH="${GITHUB_BRANCH:-main}"
RAW_BASE="https://raw.githubusercontent.com/${GITHUB_REPO}/${GITHUB_BRANCH}"

declare -A ENV_VALUES=()
declare -a ENV_KEYS=()
declare -a OPTIONAL_API_KEYS=(
  ANTHROPIC_API_KEY
  ZAI_API_KEY
  OPENAI_API_KEY
  CURSOR_API_KEY
)

die() {
  echo "error: $*" >&2
  exit 1
}

require_cmd() {
  local cmd="$1"
  command -v "$cmd" >/dev/null 2>&1 || die "${cmd} is required"
}

preflight() {
  require_cmd curl
  require_cmd docker
  docker compose version >/dev/null 2>&1 || die "docker compose (v2 plugin) is required"

  if [[ ! -S /var/run/docker.sock ]] && [[ ! -S "${DOCKER_HOST:-}" ]]; then
    echo "warning: /var/run/docker.sock not found — runner jobs using Docker may fail" >&2
  elif [[ -S /var/run/docker.sock ]] && [[ ! -w /var/run/docker.sock ]]; then
    echo "warning: /var/run/docker.sock is not writable — add your user to the docker group" >&2
  fi
}

download_runtime_files() {
  local files=(.env.example manage.sh docker-compose.yml)
  local f dest
  for f in "${files[@]}"; do
    dest="${INSTALL_DIR}/${f}"
    echo "==> Downloading ${f}"
    curl -fsSL "${RAW_BASE}/${f}" -o "$dest"
  done
  chmod +x "${INSTALL_DIR}/manage.sh"
}

parse_env_example() {
  local example="${INSTALL_DIR}/.env.example"
  [[ -f "$example" ]] || die ".env.example not found"

  ENV_KEYS=()
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" =~ ^([A-Z][A-Z0-9_]*)=(.*)$ ]]; then
      ENV_KEYS+=("${BASH_REMATCH[1]}")
      ENV_VALUES["${BASH_REMATCH[1]}"]="${BASH_REMATCH[2]}"
    fi
  done <"$example"
}

copy_env_header() {
  local example="${INSTALL_DIR}/.env.example"
  local out="${INSTALL_DIR}/.env"
  : >"$out"
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" =~ ^[A-Z][A-Z0-9_]*= ]]; then
      break
    fi
    [[ -n "$line" || ${#line} -eq 0 ]] && echo "$line" >>"$out"
  done <"$example"
}

normalize_bool() {
  local v="${1,,}"
  case "$v" in
    true | 1 | yes | y) echo "true" ;;
    false | 0 | no | n) echo "false" ;;
    *) echo "$1" ;;
  esac
}

is_bool_key() {
  case "$1" in
    RUNNER_DISABLE_UPDATE | RUNNER_EPHEMERAL) return 0 ;;
    *) return 1 ;;
  esac
}

prompt_key() {
  local key="$1"
  local default="${ENV_VALUES[$key]:-}"
  local input

  if [[ "$key" == "RUNNER_TOKEN" ]]; then
    while true; do
      read -r -s -p "${key} (required, hidden): " input
      echo
      if [[ -n "$input" ]]; then
        ENV_VALUES["$key"]="$input"
        return
      fi
      echo "  RUNNER_TOKEN cannot be empty."
    done
  fi

  if is_bool_key "$key"; then
    read -r -p "${key} [${default}] (true/false): " input
    if [[ -z "$input" ]]; then
      ENV_VALUES["$key"]="$(normalize_bool "$default")"
    else
      ENV_VALUES["$key"]="$(normalize_bool "$input")"
    fi
    return
  fi

  if [[ -n "$default" ]]; then
    read -r -p "${key} [${default}]: " input
  else
    read -r -p "${key}: " input
  fi
  if [[ -z "$input" ]]; then
    ENV_VALUES["$key"]="$default"
  else
    ENV_VALUES["$key"]="$input"
  fi
}

prompt_all_keys() {
  local key
  for key in "${ENV_KEYS[@]}"; do
    prompt_key "$key"
  done
}

write_env_file() {
  local out="${INSTALL_DIR}/.env"
  copy_env_header
  local key
  for key in "${ENV_KEYS[@]}"; do
    echo "${key}=${ENV_VALUES[$key]}" >>"$out"
  done
}

prompt_optional_api_keys() {
  local add
  read -r -p "Add optional workflow API keys? (y/N): " add
  [[ "${add,,}" == "y" || "${add,,}" == "yes" ]] || return 0

  local key val
  for key in "${OPTIONAL_API_KEYS[@]}"; do
    read -r -s -p "${key} (optional, hidden): " val
    echo
    if [[ -n "$val" ]]; then
      echo "${key}=${val}" >>"${INSTALL_DIR}/.env"
    fi
  done
}

edit_env_interactive() {
  load_existing_env
  while true; do
    echo
    echo "Current keys:"
    local i=1 key
    for key in "${ENV_KEYS[@]}"; do
      if [[ "$key" == "RUNNER_TOKEN" ]]; then
        echo "  ${i}) ${key}=***"
      else
        echo "  ${i}) ${key}=${ENV_VALUES[$key]}"
      fi
      ((i++)) || true
    done
    echo "  0) Done"
    read -r -p "Edit key number (0=done): " choice
    [[ "$choice" == "0" ]] && break
    if [[ "$choice" =~ ^[0-9]+$ ]] && ((choice >= 1 && choice <= ${#ENV_KEYS[@]})); then
      prompt_key "${ENV_KEYS[$((choice - 1))]}"
      write_env_file
    else
      echo "Invalid choice."
    fi
  done
}

load_existing_env() {
  local env_file="${INSTALL_DIR}/.env"
  [[ -f "$env_file" ]] || return 0
  local line key val
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" =~ ^([A-Z][A-Z0-9_]*)=(.*)$ ]]; then
      key="${BASH_REMATCH[1]}"
      val="${BASH_REMATCH[2]}"
      ENV_VALUES["$key"]="$val"
    fi
  done <"$env_file"
}

configure_env() {
  parse_env_example
  local env_file="${INSTALL_DIR}/.env"

  if [[ -f "$env_file" ]]; then
    echo
    echo ".env already exists."
    while true; do
      PS3="Choose: "
      select action in "Keep existing .env" "Overwrite (re-prompt all)" "Edit selected keys"; do
        case "$REPLY" in
          1)
            echo "Keeping existing .env"
            return 0
            ;;
          2)
            prompt_all_keys
            write_env_file
            prompt_optional_api_keys
            return 0
            ;;
          3)
            load_existing_env
            edit_env_interactive
            return 0
            ;;
          *)
            echo "Invalid choice."
            ;;
        esac
        break
      done
    done
  else
    prompt_all_keys
    write_env_file
    prompt_optional_api_keys
  fi
}

start_stack() {
  echo "==> Starting stack"
  (cd "$INSTALL_DIR" && ./manage.sh up)
}

print_summary() {
  cat <<EOF

==> Installation complete

Directory: ${INSTALL_DIR}

Manage the stack:
  cd ${INSTALL_DIR}
  ./manage.sh          # interactive menu
  ./manage.sh up       # start
  ./manage.sh down     # stop
  ./manage.sh logs runner
  ./manage.sh ps

EOF
}

main() {
  preflight
  mkdir -p "$INSTALL_DIR"
  cd "$INSTALL_DIR"
  download_runtime_files
  configure_env
  start_stack
  print_summary
}

main "$@"
