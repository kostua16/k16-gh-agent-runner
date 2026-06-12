#!/usr/bin/env bash
# Bootstrap ~/k16-gh-agent-runner and start the runner stack.
# One-liner: curl -fsSL https://raw.githubusercontent.com/kostua16/k16-gh-agent-runner/main/install.sh | bash
# Migrate:   curl -fsSL .../install.sh | bash -s -- --migrate [~/actions-runner]
set -euo pipefail

INSTALL_DIR="${INSTALL_DIR:-$HOME/k16-gh-agent-runner}"
GITHUB_REPO="${GITHUB_REPO:-kostua16/k16-gh-agent-runner}"
GITHUB_BRANCH="${GITHUB_BRANCH:-main}"
RAW_BASE="https://raw.githubusercontent.com/${GITHUB_REPO}/${GITHUB_BRANCH}"

MIGRATE_PATH=""
MIGRATE_SOURCE=""
CLI_TOKEN=""
DO_UPDATE=0
UPDATE_ALL=0
RUNNER_HEALTH_WARN=0
UPGRADE_BACKUP_DIR=""

ENV_KEYS=()
ENV_VALS=()
RUNNER_CONFIG_FILES=(.runner .credentials .credentials_rsaparams)
OPTIONAL_API_KEYS=(
  ANTHROPIC_API_KEY
  ZAI_API_KEY
  OPENAI_API_KEY
  CURSOR_API_KEY
)

tolower() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

env_get() {
  local key="$1" i
  for i in "${!ENV_KEYS[@]}"; do
    if [[ "${ENV_KEYS[i]}" == "$key" ]]; then
      printf '%s' "${ENV_VALS[i]}"
      return 0
    fi
  done
  return 1
}

env_set() {
  local key="$1" val="$2" i
  for i in "${!ENV_KEYS[@]}"; do
    if [[ "${ENV_KEYS[i]}" == "$key" ]]; then
      ENV_VALS[i]="$val"
      return 0
    fi
  done
  ENV_KEYS+=("$key")
  ENV_VALS+=("$val")
}

prompt_fd() {
  if [[ -r /dev/tty ]]; then
    printf '/dev/tty'
  elif [[ -t 0 ]]; then
    printf '0'
  else
    return 1
  fi
}

read_line() {
  local prompt="$1" secret="${2:-0}" fd reply=""
  fd="$(prompt_fd)" || return 1
  if [[ "$secret" == 1 ]]; then
    read -r -s -p "$prompt" reply <"$fd"
    printf '\n' >"$fd"
  else
    read -r -p "$prompt" reply <"$fd"
  fi
  printf '%s' "$reply"
}

token_nonempty() {
  [[ -n "${1//[[:space:]]/}" ]]
}

apply_supplied_token() {
  if token_nonempty "$CLI_TOKEN"; then
    echo "  using RUNNER_TOKEN from --token"
    env_set "RUNNER_TOKEN" "$CLI_TOKEN"
    return 0
  fi
  if token_nonempty "${RUNNER_TOKEN:-}"; then
    echo "  using RUNNER_TOKEN from environment"
    env_set "RUNNER_TOKEN" "$RUNNER_TOKEN"
    return 0
  fi
  return 1
}

runner_token_set() {
  local token
  token="$(env_get RUNNER_TOKEN 2>/dev/null || true)"
  token_nonempty "$token"
}

die() {
  echo "error: $*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage: install.sh [options]

Options:
  --migrate [PATH]  Migrate from a legacy self-hosted runner install
                    (default PATH: ~/actions-runner). Requires jq.
                    Stops the old service, imports URL/name/labels, and
                    prefers `gh api` for a new registration token.
  --token TOKEN     Runner registration token (skips token prompt and
                    overrides gh lookup in --migrate or missing-state --update)
  --update          Refresh manage.sh, .env.example, and docker-compose.yml;
                    merge new keys into existing .env, then pull → restart
  --all             With --update, refresh cache-server too and clear compose
                    Docker logs plus cache-server cache data
  -h, --help        Show this help

Environment:
  INSTALL_DIR       Target directory (default: ~/k16-gh-agent-runner)
  GITHUB_REPO       Source repo for runtime files
  GITHUB_BRANCH     Branch to download (default: main)
  RUNNER_TOKEN      Same as --token (CLI flag takes precedence)

Examples:
  curl -fsSL .../install.sh | bash
  curl -fsSL .../install.sh | bash -s -- --token "$RUNNER_TOKEN"
  curl -fsSL .../install.sh | bash -s -- --migrate --token "$RUNNER_TOKEN"
  curl -fsSL .../install.sh | bash -s -- --update
  curl -fsSL .../install.sh | bash -s -- --update --all
  curl -fsSL .../install.sh | bash -s -- --update --token "$RUNNER_TOKEN"
  ./install.sh --migrate ~/actions-runner --token "$RUNNER_TOKEN"
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --migrate)
        [[ "$DO_UPDATE" == "0" ]] || die "--migrate and --update cannot be used together"
        if [[ $# -ge 2 && "$2" != --* ]]; then
          MIGRATE_PATH="$2"
          shift 2
        else
          MIGRATE_PATH="${HOME}/actions-runner"
          shift
        fi
        ;;
      --update)
        [[ -z "$MIGRATE_PATH" ]] || die "--migrate and --update cannot be used together"
        DO_UPDATE=1
        shift
        ;;
      --all)
        UPDATE_ALL=1
        shift
        ;;
      --token)
        [[ $# -ge 2 ]] || die "--token requires a value"
        CLI_TOKEN="$2"
        token_nonempty "$CLI_TOKEN" || die "--token value cannot be empty"
        shift 2
        ;;
      --token=*)
        CLI_TOKEN="${1#--token=}"
        token_nonempty "$CLI_TOKEN" || die "--token value cannot be empty"
        shift
        ;;
      -h | --help)
        usage
        exit 0
        ;;
      *)
        die "unknown argument: $1 (try --help)"
        ;;
    esac
  done
}

expand_user_path() {
  local p="$1"
  case "$p" in
    "~")
      printf '%s' "$HOME"
      ;;
    *)
      if [ "${p#~/}" != "$p" ]; then
        printf '%s' "${HOME}/${p#~/}"
      else
        printf '%s' "$p"
      fi
      ;;
  esac
}

gh_auth_ok() {
  command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1
}

require_cmd() {
  local cmd="$1"
  command -v "$cmd" >/dev/null 2>&1 || die "${cmd} is required"
}

preflight() {
  require_cmd curl
  require_cmd docker
  docker compose version >/dev/null 2>&1 || die "docker compose (v2 plugin) is required"

  if [[ -n "$MIGRATE_PATH" ]]; then
    require_cmd jq
  fi

  if [[ ! -S /var/run/docker.sock ]] && [[ ! -S "${DOCKER_HOST:-}" ]]; then
    echo "warning: /var/run/docker.sock not found — runner jobs using Docker may fail" >&2
  elif [[ -S /var/run/docker.sock ]] && [[ ! -w /var/run/docker.sock ]]; then
    echo "warning: /var/run/docker.sock is not writable — add your user to the docker group" >&2
  fi
}

download_runtime_files() {
  local files=(.env.example manage.sh docker-compose.yml)
  local f dest tmp
  for f in "${files[@]}"; do
    dest="${INSTALL_DIR}/${f}"
    tmp="${INSTALL_DIR}/.${f}.new.$$"
    echo "==> Downloading ${f}"
    curl -fsSL "${RAW_BASE}/${f}" -o "$tmp"
    # Atomic replace: safe when ./manage.sh upgrade is running (avoids truncating
    # the script bash is still reading; also avoids ETXTBSY on some Linux setups).
    mv "$tmp" "$dest"
  done
  chmod +x "${INSTALL_DIR}/manage.sh"
}

parse_env_example() {
  local example="${INSTALL_DIR}/.env.example"
  [[ -f "$example" ]] || die ".env.example not found"

  ENV_KEYS=()
  ENV_VALS=()
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" =~ ^([A-Z][A-Z0-9_]*)=(.*)$ ]]; then
      ENV_KEYS+=("${BASH_REMATCH[1]}")
      ENV_VALS+=("${BASH_REMATCH[2]}")
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
  local v
  v="$(tolower "$1")"
  case "$v" in
    true | 1 | yes | y) echo "true" ;;
    false | 0 | no | n) echo "false" ;;
    *) echo "$1" ;;
  esac
}

is_bool_key() {
  case "$1" in
    RUNNER_DISABLE_UPDATE | RUNNER_EPHEMERAL | RUNNER_REMOVE_ON_EXIT | RUNNER_REPLACE) return 0 ;;
    *) return 1 ;;
  esac
}

prompt_key() {
  local key="$1"
  local default input
  default="$(env_get "$key" 2>/dev/null || true)"

  if [[ "$key" == "RUNNER_TOKEN" ]]; then
    if runner_token_set; then
      return 0
    fi
    while true; do
      input="$(read_line "${key} (required, hidden): " 1)" || die "RUNNER_TOKEN required (stdin is not a TTY; use --token, export RUNNER_TOKEN, or use a terminal)"
      if token_nonempty "$input"; then
        env_set "$key" "$input"
        return
      fi
      echo "  RUNNER_TOKEN cannot be empty."
    done
  fi

  if is_bool_key "$key"; then
    input="$(read_line "${key} [${default}] (true/false): ")"
    if [[ -z "$input" ]]; then
      env_set "$key" "$(normalize_bool "$default")"
    else
      env_set "$key" "$(normalize_bool "$input")"
    fi
    return
  fi

  if [[ -n "$default" ]]; then
    input="$(read_line "${key} [${default}]: ")"
  else
    input="$(read_line "${key}: ")"
  fi
  if [[ -z "$input" ]]; then
    env_set "$key" "$default"
  else
    env_set "$key" "$input"
  fi
}

prompt_all_keys() {
  local key
  for key in "${ENV_KEYS[@]}"; do
    prompt_key "$key"
  done
}

write_env_file() {
  copy_env_header
  local key val
  for key in "${ENV_KEYS[@]}"; do
    val="$(env_get "$key")"
    echo "${key}=${val}" >>"${INSTALL_DIR}/.env"
  done
}

prompt_optional_api_keys() {
  local add add_lower
  add="$(read_line "Add optional workflow API keys? (y/N): ")" || return 0
  add_lower="$(tolower "$add")"
  [[ "$add_lower" == "y" || "$add_lower" == "yes" ]] || return 0

  local key val
  for key in "${OPTIONAL_API_KEYS[@]}"; do
    val="$(read_line "${key} (optional, hidden): " 1)" || break
    if token_nonempty "$val"; then
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
        echo "  ${i}) ${key}=$(env_get "$key")"
      fi
      ((i++)) || true
    done
    echo "  0) Done"
    choice="$(read_line "Edit key number (0=done): ")"
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
      env_set "$key" "$val"
    fi
  done <"$env_file"
}

merge_docker_label() {
  local labels="$1"
  local IFS=,
  local -a parts=()
  local seen_docker=0 part
  read -ra parts <<<"$labels"
  for part in "${parts[@]}"; do
    part="${part#"${part%%[![:space:]]*}"}"
    part="${part%"${part##*[![:space:]]}"}"
    [[ -z "$part" ]] && continue
    [[ "$part" == "docker" ]] && seen_docker=1
  done
  if ((seen_docker)); then
    printf '%s' "$labels"
    return
  fi
  if [[ -n "$labels" ]]; then
    printf '%s,docker' "$labels"
  else
    printf 'docker'
  fi
}

migrate_validate() {
  local expanded resolved
  expanded="$(expand_user_path "$MIGRATE_PATH")"
  resolved="$(cd "$expanded" 2>/dev/null && pwd)" || die "migrate path not found: ${MIGRATE_PATH}"
  MIGRATE_SOURCE="$resolved"

  [[ -f "${MIGRATE_SOURCE}/.runner" ]] || die "missing .runner in ${MIGRATE_SOURCE}"
  [[ -f "${MIGRATE_SOURCE}/svc.sh" ]] || die "missing svc.sh in ${MIGRATE_SOURCE}"

  echo "==> Migrating from ${MIGRATE_SOURCE}"
}

migrate_svc_name() {
  local path="$1"
  local line
  line="$(grep -m1 '^SVC_NAME=' "${path}/svc.sh" 2>/dev/null || true)"
  line="${line#SVC_NAME=}"
  line="${line%\"}"
  line="${line#\"}"
  printf '%s' "$line"
}

migrate_systemd_unit() {
  local path="$1" unit=""
  if [[ -f "${path}/.service" ]]; then
    unit="$(tr -d '[:space:]' <"${path}/.service")"
  fi
  if [[ -z "$unit" ]]; then
    unit="$(migrate_svc_name "$path")"
  fi
  printf '%s' "$unit"
}

migrate_systemd_active() {
  local unit="$1"
  [[ -n "$unit" ]] && command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet "$unit" 2>/dev/null
}

migrate_stop_systemd() {
  local path="$1" unit
  unit="$(migrate_systemd_unit "$path")"
  [[ -n "$unit" ]] || return 0

  if migrate_systemd_active "$unit"; then
    echo "  stopping systemd unit ${unit}"
    if command -v sudo >/dev/null 2>&1 && sudo -n systemctl stop "$unit" 2>/dev/null; then
      echo "  systemd unit stopped"
    else
      echo "warning: could not stop ${unit} without a password (sudo -n failed); continuing with process signals" >&2
    fi
  else
    echo "  systemd unit already inactive (${unit})"
  fi
}

migrate_run_svc() {
  local path="$1" action="$2"
  local out rc=0

  out="$(cd "$path" && ./svc.sh "$action" 2>&1)" || rc=$?
  if [[ $rc -eq 0 ]]; then
    return 0
  fi

  if grep -qi 'must run as sudo' <<<"$out" && command -v sudo >/dev/null 2>&1; then
    if (cd "$path" && sudo -n ./svc.sh "$action" 2>/dev/null); then
      return 0
    fi
    echo "warning: svc.sh ${action} requires sudo password; skipped" >&2
  fi
}

migrate_default_labels() {
  local labels="self-hosted"
  case "$(uname -s)" in
    Linux) labels+=",Linux" ;;
    Darwin) labels+=",macOS" ;;
  esac
  case "$(uname -m)" in
    x86_64 | amd64) labels+=",X64" ;;
    aarch64 | arm64) labels+=",ARM64" ;;
  esac
  printf '%s' "$labels"
}

migrate_collect_pids() {
  local path="$1"
  local -a collected=()
  local pattern pid cmd seen="|"
  local patterns=("Runner.Listener" "RunnerService.js" "runsvc.sh" "run-helper.sh")

  for pattern in "${patterns[@]}"; do
    while read -r pid; do
      [[ -z "$pid" ]] && continue
      kill -0 "$pid" 2>/dev/null || continue
      cmd="$(ps -p "$pid" -o command= 2>/dev/null || true)"
      [[ "$cmd" == *"${path}"* ]] || continue
      [[ "$seen" == *"|${pid}|"* ]] && continue
      collected+=("$pid")
      seen="${seen}${pid}|"
    done < <(pgrep -f "$pattern" 2>/dev/null || true)
  done

  if ((${#collected[@]} > 0)); then
    printf '%s\n' "${collected[@]}"
  fi
}

migrate_detect_running() {
  local path="$1"
  local svc_name status_out unit

  echo "==> Checking legacy runner status"

  if grep -q launchctl "${path}/svc.sh" 2>/dev/null; then
    svc_name="$(migrate_svc_name "$path")"
    if [[ -n "$svc_name" ]]; then
      status_out="$(launchctl list 2>/dev/null | grep -F "$svc_name" || true)"
      if [[ -n "$status_out" ]]; then
        echo "  launchctl: running (${svc_name})"
        echo "    ${status_out}"
      else
        echo "  launchctl: not loaded (${svc_name})"
      fi
    fi
  elif grep -q systemctl "${path}/svc.sh" 2>/dev/null; then
    unit="$(migrate_systemd_unit "$path")"
    if [[ -n "$unit" ]] && command -v systemctl >/dev/null 2>&1; then
      if migrate_systemd_active "$unit"; then
        echo "  systemctl: active (${unit})"
      else
        echo "  systemctl: inactive (${unit})"
      fi
    fi
  fi

  local pid
  if read -r pid < <(migrate_collect_pids "$path" | head -1); then
    echo "  processes:"
    while read -r pid; do
      [[ -n "$pid" ]] && echo "    pid ${pid}: $(ps -p "$pid" -o command= 2>/dev/null || echo '?')"
    done < <(migrate_collect_pids "$path")
  else
    echo "  processes: none matched"
  fi
}

migrate_signal_pids() {
  local sig="$1"
  shift
  local pid
  for pid in "$@"; do
    kill "-${sig}" "$pid" 2>/dev/null || true
  done
}

migrate_stop() {
  local path="$1"
  local -a pids=()
  local pid waited=0

  echo "==> Stopping legacy runner"

  if grep -q systemctl "${path}/svc.sh" 2>/dev/null; then
    migrate_stop_systemd "$path"
  elif [[ -f "${path}/.service" ]] && [[ -x "${path}/svc.sh" ]]; then
    echo "  running svc.sh stop"
    migrate_run_svc "$path" stop
  fi

  sleep 3

  while read -r pid; do
    [[ -n "$pid" ]] && pids+=("$pid")
  done < <(migrate_collect_pids "$path")

  if ((${#pids[@]} > 0)); then
    echo "  sending SIGTERM to ${#pids[@]} process(es)"
    migrate_signal_pids TERM "${pids[@]}"
    while ((waited < 10)); do
      local -a remaining=()
      for pid in "${pids[@]}"; do
        kill -0 "$pid" 2>/dev/null && remaining+=("$pid")
      done
      ((${#remaining[@]} == 0)) && break
      sleep 1
      waited=$((waited + 1))
      pids=("${remaining[@]}")
    done
    if ((${#pids[@]} > 0)); then
      echo "  sending SIGKILL to ${#pids[@]} remaining process(es)"
      migrate_signal_pids KILL "${pids[@]}"
      sleep 1
    fi
  fi

  if read -r pid < <(migrate_collect_pids "$path" | head -1); then
    echo "warning: some legacy runner processes may still be running" >&2
    migrate_detect_running "$path"
  else
    echo "  legacy runner stopped"
  fi
}

parse_github_target() {
  local url="$1"
  GITHUB_TARGET_TYPE=""
  GITHUB_OWNER=""
  GITHUB_REPO_NAME=""

  if [[ "$url" =~ ^https://github\.com/([^/]+)/([^/]+)/?$ ]]; then
    GITHUB_TARGET_TYPE="repo"
    GITHUB_OWNER="${BASH_REMATCH[1]}"
    GITHUB_REPO_NAME="${BASH_REMATCH[2]}"
  elif [[ "$url" =~ ^https://github\.com/([^/]+)/?$ ]]; then
    GITHUB_TARGET_TYPE="org"
    GITHUB_OWNER="${BASH_REMATCH[1]}"
  else
    GITHUB_TARGET_TYPE="unsupported"
  fi
}

gh_fetch_registration_token() {
  local token=""
  case "$GITHUB_TARGET_TYPE" in
    repo)
      token="$(gh api -X POST "repos/${GITHUB_OWNER}/${GITHUB_REPO_NAME}/actions/runners/registration-token" --jq .token)"
      ;;
    org)
      token="$(gh api -X POST "orgs/${GITHUB_OWNER}/actions/runners/registration-token" --jq .token)"
      ;;
    *)
      return 1
      ;;
  esac
  [[ -n "$token" && "$token" != "null" ]] || return 1
  printf '%s' "$token"
}

gh_fetch_runner_labels() {
  local agent_id="$1" agent_name="$2"
  local api_path labels
  case "$GITHUB_TARGET_TYPE" in
    repo) api_path="repos/${GITHUB_OWNER}/${GITHUB_REPO_NAME}/actions/runners" ;;
    org) api_path="orgs/${GITHUB_OWNER}/actions/runners" ;;
    *) return 1 ;;
  esac

  labels="$(
    gh api "$api_path" --paginate \
      --jq "[.runners[]? | select(.id == ${agent_id} or .name == \"${agent_name}\") | .labels[]?.name] | unique | join(\",\")" 2>/dev/null || true
  )"
  [[ -n "$labels" && "$labels" != "null" ]] || return 1
  printf '%s' "$labels"
}

read_legacy_runner_token() {
  local env_file="$1/.env"
  [[ -f "$env_file" ]] || return 1
  local line val
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" =~ ^RUNNER_TOKEN=(.*)$ ]]; then
      val="${BASH_REMATCH[1]}"
      val="${val%\"}"
      val="${val#\"}"
      token_nonempty "$val" || return 1
      printf '%s' "$val"
      return 0
    fi
  done <"$env_file"
  return 1
}

prompt_registration_token() {
  local input
  echo "Generate a registration token: GitHub → Settings → Actions → Runners → New self-hosted runner"
  while true; do
    input="$(read_line "RUNNER_TOKEN (required, hidden): " 1)" || die "RUNNER_TOKEN required (stdin is not a TTY; use --token, export RUNNER_TOKEN, or install gh and run gh auth login)"
    if token_nonempty "$input"; then
      env_set "RUNNER_TOKEN" "$input"
      return
    fi
    echo "  RUNNER_TOKEN cannot be empty."
  done
}

migrate_extract_config() {
  local path="$1"
  local runner_file="${path}/.runner"
  local github_url agent_name agent_id labels token

  echo "==> Reading legacy configuration"

  github_url="$(jq -r '.gitHubUrl // empty' "$runner_file")"
  agent_name="$(jq -r '.agentName // empty' "$runner_file")"
  agent_id="$(jq -r '.agentId // empty' "$runner_file")"

  [[ -n "$github_url" ]] || die "gitHubUrl missing in ${runner_file}"
  [[ -n "$agent_name" ]] || die "agentName missing in ${runner_file}"

  env_set "GITHUB_URL" "$github_url"
  env_set "RUNNER_NAME" "$agent_name"

  parse_github_target "$github_url"

  if ! apply_supplied_token; then
    token=""
    if gh_auth_ok && [[ "$GITHUB_TARGET_TYPE" != "unsupported" ]]; then
      echo "  fetching registration token via gh api"
      if token="$(gh_fetch_registration_token)"; then
        env_set "RUNNER_TOKEN" "$token"
      else
        echo "warning: gh api registration-token failed; will try legacy .env or prompt" >&2
      fi
    elif [[ "$GITHUB_TARGET_TYPE" == "unsupported" ]]; then
      echo "warning: non-github.com URL — skipping gh api" >&2
    fi

    if ! runner_token_set; then
      if token="$(read_legacy_runner_token "$path" 2>/dev/null)"; then
        echo "  using RUNNER_TOKEN from legacy .env"
        echo "warning: legacy registration tokens expire quickly; install gh and run gh auth login for a fresh token" >&2
        env_set "RUNNER_TOKEN" "$token"
      else
        if ! command -v gh >/dev/null 2>&1; then
          echo "warning: gh is not installed on this host — pass --token or export RUNNER_TOKEN" >&2
        fi
        prompt_registration_token
      fi
    fi
  fi

  labels=""
  if gh_auth_ok && [[ "$GITHUB_TARGET_TYPE" != "unsupported" ]] && [[ -n "$agent_id" ]]; then
    echo "  fetching runner labels via gh api"
    labels="$(gh_fetch_runner_labels "$agent_id" "$agent_name" 2>/dev/null || true)"
  fi
  if [[ -z "$labels" ]]; then
    if [[ -n "${RUNNER_LABELS:-}" ]]; then
      labels="$RUNNER_LABELS"
      echo "  using RUNNER_LABELS from environment"
    else
      labels="$(env_get RUNNER_LABELS 2>/dev/null || true)"
    fi
    if [[ -z "$labels" ]]; then
      labels="$(migrate_default_labels)"
      echo "  using default RUNNER_LABELS=${labels}"
    fi
  fi
  env_set "RUNNER_LABELS" "$(merge_docker_label "$labels")"

  echo "  GITHUB_URL=${github_url}"
  echo "  RUNNER_NAME=${agent_name}"
  echo "  RUNNER_LABELS=$(env_get RUNNER_LABELS)"
  echo "  RUNNER_TOKEN=***"
}

require_runner_token() {
  runner_token_set || die "RUNNER_TOKEN is empty; pass --token, export RUNNER_TOKEN, install gh and run gh auth login, or re-run from a terminal to enter it"
}

migrate_apply_env() {
  local env_file="${INSTALL_DIR}/.env"
  if [[ -f "$env_file" ]]; then
    echo "==> Overwriting existing ${env_file} with migrated configuration"
  fi
  migrate_extract_config "$MIGRATE_SOURCE"
  require_runner_token
  write_env_file
}

run_migration() {
  migrate_validate
  migrate_detect_running "$MIGRATE_SOURCE"
  migrate_stop "$MIGRATE_SOURCE"
}

merge_env_update() {
  local env_file="${INSTALL_DIR}/.env"
  [[ -f "$env_file" ]] || die ".env not found in ${INSTALL_DIR}; run a fresh install first"

  echo "==> Merging ${env_file} with .env.example"
  parse_env_example
  load_existing_env
  write_env_file
  echo "  preserved existing values; added any new keys from .env.example"
}

cleanup_upgrade_backup() {
  if [[ -n "$UPGRADE_BACKUP_DIR" && -d "$UPGRADE_BACKUP_DIR" ]]; then
    rm -rf "$UPGRADE_BACKUP_DIR"
  fi
}

compose_cmd() {
  (cd "$INSTALL_DIR" && docker compose -f docker-compose.yml "$@")
}

runner_container_id() {
  local id
  while IFS= read -r id; do
    [[ -n "$id" ]] || continue
    printf '%s' "$id"
    return 0
  done < <(compose_cmd ps -a -q runner 2>/dev/null || true)
  return 1
}

runner_container_running() {
  local id="$1" running
  [[ -n "$id" ]] || return 1
  running="$(docker inspect -f '{{.State.Running}}' "$id" 2>/dev/null || true)"
  [[ "$running" == "true" ]]
}

registration_backup_complete() {
  [[ -f "$1/.runner" && -f "$1/.credentials" ]]
}

copy_registration_files() {
  local src="$1" dest="$2" file
  for file in "${RUNNER_CONFIG_FILES[@]}"; do
    if [[ -f "${src}/${file}" ]]; then
      cp "${src}/${file}" "${dest}/${file}"
    fi
  done
  registration_backup_complete "$dest"
}

capture_runner_registration_from_container() {
  local cid="$1" base="$2" dest="$3" candidate
  candidate="$(mktemp -d "${dest}/candidate.XXXXXX")" || die "failed to create registration backup"

  if docker cp "${cid}:${base}/.runner" "${candidate}/.runner" >/dev/null 2>&1 &&
    docker cp "${cid}:${base}/.credentials" "${candidate}/.credentials" >/dev/null 2>&1; then
    docker cp "${cid}:${base}/.credentials_rsaparams" "${candidate}/.credentials_rsaparams" >/dev/null 2>&1 || true
    if copy_registration_files "$candidate" "$dest"; then
      rm -rf "$candidate"
      return 0
    fi
  fi

  rm -rf "$candidate"
  return 1
}

capture_runner_registration_from_volume() {
  local dest="$1" candidate archive
  candidate="$(mktemp -d "${dest}/volume.XXXXXX")" || die "failed to create registration backup"
  archive="${candidate}/registration.tar"

  # shellcheck disable=SC2016 # Expand variables inside the container shell.
  if compose_cmd run --rm -T --no-deps --entrypoint sh runner -c 'set -eu
cd /config
test -f .runner
test -f .credentials
files=".runner .credentials"
if [ -f .credentials_rsaparams ]; then
  files="$files .credentials_rsaparams"
fi
tar -cf - $files' >"$archive" &&
    tar -xf "$archive" -C "$candidate" 2>/dev/null &&
    copy_registration_files "$candidate" "$dest"; then
    rm -rf "$candidate"
    return 0
  fi

  rm -rf "$candidate"
  return 1
}

capture_runner_registration() {
  local dest="$1" cid
  cid="$(runner_container_id || true)"

  if [[ -n "$cid" ]]; then
    if capture_runner_registration_from_container "$cid" /config "$dest"; then
      echo "  captured existing runner registration from container /config"
      return 0
    fi
    if capture_runner_registration_from_container "$cid" /home/runner "$dest"; then
      echo "  captured existing runner registration from legacy container /home/runner"
      return 0
    fi
  fi

  if capture_runner_registration_from_volume "$dest"; then
    echo "  captured existing runner registration from runner-data volume"
    return 0
  fi

  echo "  no persisted runner registration found; a fresh token will be required"
  return 1
}

restore_runner_registration() {
  local backup="$1"
  registration_backup_complete "$backup" || return 1

  echo "==> Restoring runner registration into runner-data"
  # shellcheck disable=SC2016 # Expand variables inside the container shell.
  compose_cmd run --rm -T --no-deps --entrypoint sh --volume "${backup}:/restore:ro" runner -c 'set -eu
mkdir -p /config
install -m 600 /restore/.runner /config/.runner
install -m 600 /restore/.credentials /config/.credentials
if [ -f /restore/.credentials_rsaparams ]; then
  install -m 600 /restore/.credentials_rsaparams /config/.credentials_rsaparams
fi'
}

pull_images_with_retry() {
  local attempt=1 max_attempts=3 delay=10

  while ((attempt <= max_attempts)); do
    if ((attempt == 1)); then
      echo "==> Pulling latest images"
    else
      echo "==> Pulling latest images (attempt ${attempt}/${max_attempts})"
    fi

    if compose_cmd pull; then
      return 0
    fi

    if ((attempt == max_attempts)); then
      return 1
    fi

    echo "warning: image pull failed; retrying in ${delay}s" >&2
    sleep "$delay"
    delay=$((delay * 2))
    attempt=$((attempt + 1))
  done
}

prepare_fresh_update_token() {
  local github_url token

  if apply_supplied_token; then
    env_set RUNNER_REPLACE true
    write_env_file
    return 0
  fi

  github_url="$(env_get GITHUB_URL 2>/dev/null || true)"
  [[ -n "$github_url" ]] || die "GITHUB_URL is missing from .env; cannot fetch a fresh runner token"
  parse_github_target "$github_url"

  if gh_auth_ok && [[ "$GITHUB_TARGET_TYPE" != "unsupported" ]]; then
    echo "  fetching fresh RUNNER_TOKEN via gh api"
    if token="$(gh_fetch_registration_token)"; then
      env_set RUNNER_TOKEN "$token"
      env_set RUNNER_REPLACE true
      write_env_file
      return 0
    fi
    echo "warning: gh api registration-token failed" >&2
  elif [[ "$GITHUB_TARGET_TYPE" == "unsupported" ]]; then
    echo "warning: non-github.com URL — cannot fetch a token via gh api" >&2
  elif ! command -v gh >/dev/null 2>&1; then
    echo "warning: gh is not installed on this host" >&2
  else
    echo "warning: gh is not authenticated; run gh auth login" >&2
  fi

  die "runner registration files were not found; existing .env RUNNER_TOKEN may be expired. Pass a fresh token with ./manage.sh upgrade --token \"\$RUNNER_TOKEN\" or authenticate gh and retry."
}

ensure_update_registration_ready() {
  local backup="$1"
  if registration_backup_complete "$backup"; then
    return 0
  fi

  echo "==> Preparing fresh runner registration token"
  prepare_fresh_update_token
}

stop_runner_for_upgrade() {
  local runner_was_running="$1"

  echo "==> Stopping runner service"
  compose_cmd stop --timeout 60 runner 2>/dev/null || true
  compose_cmd rm -f runner 2>/dev/null || true

  if [[ "$runner_was_running" == "1" ]]; then
    echo "==> Waiting for GitHub runner session to clear (20s)..."
    sleep 20
  fi
}

prune_upgrade_logs() {
  echo "==> Pruning compose Docker logs"
  (cd "$INSTALL_DIR" && ./manage.sh cleanup logs --all --apply)
}

clear_upgrade_cache_data() {
  echo "==> Clearing cache-server cache data"
  compose_cmd run --rm -T --no-deps --entrypoint sh cache-server -c 'set -eu
rm -rf /data/cache /data/cache-server.db /data/cache-server.db-shm /data/cache-server.db-wal
mkdir -p /data/cache'
}

refresh_cache_for_upgrade() {
  echo "==> Stopping cache-server service"
  compose_cmd stop --timeout 30 cache-server 2>/dev/null || true
  compose_cmd rm -f cache-server 2>/dev/null || true
  clear_upgrade_cache_data
}

refresh_stack() {
  local runner_id runner_was_running=0
  local -a up_args

  echo "==> Refreshing stack (capture credentials → pull → restart)"
  UPGRADE_BACKUP_DIR="$(mktemp -d "${INSTALL_DIR}/.upgrade-registration.XXXXXX")" || die "failed to create registration backup"
  trap cleanup_upgrade_backup EXIT

  runner_id="$(runner_container_id || true)"
  if runner_container_running "$runner_id"; then
    runner_was_running=1
  fi

  capture_runner_registration "$UPGRADE_BACKUP_DIR" || true

  if ! pull_images_with_retry; then
    die "image pull failed after 3 attempts; existing runner was left running"
  fi

  if ! registration_backup_complete "$UPGRADE_BACKUP_DIR"; then
    capture_runner_registration "$UPGRADE_BACKUP_DIR" || true
  fi

  ensure_update_registration_ready "$UPGRADE_BACKUP_DIR"
  warn_host_legacy_runner || true
  if [[ "$UPDATE_ALL" == "1" ]]; then
    if ! prune_upgrade_logs; then
      echo "warning: failed to prune compose Docker logs; continuing upgrade" >&2
    fi
  fi
  stop_runner_for_upgrade "$runner_was_running"
  if [[ "$UPDATE_ALL" == "1" ]]; then
    if ! refresh_cache_for_upgrade; then
      echo "warning: failed to clear cache-server cache data; continuing upgrade" >&2
    fi
  fi
  if registration_backup_complete "$UPGRADE_BACKUP_DIR"; then
    restore_runner_registration "$UPGRADE_BACKUP_DIR"
  fi

  up_args=(up -d --remove-orphans)
  if [[ "$UPDATE_ALL" == "1" ]]; then
    up_args+=(--force-recreate)
  fi
  compose_cmd "${up_args[@]}"
  check_runner_health || RUNNER_HEALTH_WARN=1
}

warn_host_legacy_runner() {
  local path legacy_path pid unit active=0

  for path in "${HOME}/actions-runner" "${INSTALL_DIR}/../actions-runner"; do
    expanded="$(expand_user_path "$path" 2>/dev/null || true)"
    [[ -d "$expanded" && -f "${expanded}/svc.sh" ]] || continue
    legacy_path="$expanded"

    unit="$(migrate_systemd_unit "$legacy_path" 2>/dev/null || true)"
    if migrate_systemd_active "$unit" 2>/dev/null; then
      echo "warning: legacy systemd runner is active (${unit}) — stop it or the Docker runner may fail with session conflict" >&2
      echo "  sudo systemctl stop ${unit}" >&2
      active=1
    fi

    if read -r pid < <(migrate_collect_pids "$legacy_path" 2>/dev/null | head -1); then
      echo "warning: legacy runner processes still running under ${legacy_path} (pid ${pid})" >&2
      active=1
    fi
  done

  if [[ "$active" == "1" ]]; then
    return 1
  fi
  return 0
}

run_update() {
  [[ -f "${INSTALL_DIR}/.env" ]] || die "nothing to update in ${INSTALL_DIR}; run a fresh install first"

  download_runtime_files
  merge_env_update
  refresh_stack
  print_summary
}

configure_env() {
  parse_env_example
  apply_supplied_token || true

  if [[ -n "$MIGRATE_SOURCE" ]]; then
    migrate_apply_env
    return 0
  fi

  local env_file="${INSTALL_DIR}/.env"

  if [[ -f "$env_file" ]]; then
    echo
    echo ".env already exists."
    while true; do
      PS3="Choose: "
      # shellcheck disable=SC2034
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
  require_runner_token
  warn_host_legacy_runner || true
  echo "==> Starting stack"
  (cd "$INSTALL_DIR" && ./manage.sh up)
  check_runner_health || RUNNER_HEALTH_WARN=1
}

check_runner_health() {
  local waits=12 stable=0 id inspect state running restarting restart_count previous_restart_count=""
  while ((waits > 0)); do
    sleep 2
    id="$(
      if cd "$INSTALL_DIR"; then
        docker compose ps -q runner 2>/dev/null || true
      fi
    )"
    if [[ -n "$id" ]]; then
      inspect="$(docker inspect -f '{{.State.Status}} {{.State.Running}} {{.State.Restarting}} {{.RestartCount}} {{.State.ExitCode}}' "$id" 2>/dev/null || true)"
      if [[ -n "$inspect" ]]; then
        read -r state running restarting restart_count _ <<<"$inspect"
        if [[ "$state" == "running" && "$running" == "true" && "$restarting" != "true" ]]; then
          if [[ -n "$previous_restart_count" && "$restart_count" != "$previous_restart_count" ]]; then
            stable=1
          else
            stable=$((stable + 1))
          fi
          previous_restart_count="$restart_count"
          if ((stable >= 3)); then
            return 0
          fi
        else
          stable=0
          previous_restart_count="$restart_count"
        fi
      fi
    fi
    waits=$((waits - 1))
  done

  echo "warning: runner container did not stay running; scanning recent issues:" >&2
  if ! (cd "$INSTALL_DIR" && ./manage.sh issues) >&2; then
    echo "  cd ${INSTALL_DIR} && ./manage.sh issues" >&2
  fi
  echo "Check logs:" >&2
  echo "  cd ${INSTALL_DIR} && ./manage.sh logs runner" >&2
  return 1
}

print_summary() {
  if [[ "$RUNNER_HEALTH_WARN" == "1" ]]; then
    cat <<EOF

==> Installation finished with warnings

Directory: ${INSTALL_DIR}
EOF
  else
    cat <<EOF

==> Installation complete

Directory: ${INSTALL_DIR}
EOF
  fi
  if [[ -n "$MIGRATE_SOURCE" ]]; then
    cat <<EOF
Migrated from: ${MIGRATE_SOURCE}
Legacy runner service was stopped before starting the Docker stack.
EOF
  fi
  cat <<EOF

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
  if [[ "$UPDATE_ALL" == "1" && "$DO_UPDATE" != "1" ]]; then
    die "--all is only supported with --update"
  fi

  mkdir -p "$INSTALL_DIR"
  cd "$INSTALL_DIR"

  if [[ "$DO_UPDATE" == "1" ]]; then
    run_update
    return 0
  fi

  if [[ -n "$MIGRATE_PATH" ]]; then
    run_migration
  fi
  download_runtime_files
  configure_env
  start_stack
  print_summary
}

parse_args "$@"
main
