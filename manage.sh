#!/usr/bin/env bash
# Manage the production runner stack (docker compose).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

INSTALL_SH_URL="https://raw.githubusercontent.com/kostua16/k16-gh-agent-runner/main/install.sh"
COMPOSE=(docker compose -f docker-compose.yml)

die() {
  echo "error: $*" >&2
  exit 1
}

tolower() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

require_compose() {
  if ! docker compose version >/dev/null 2>&1; then
    echo "error: docker compose (v2 plugin) is required" >&2
    exit 1
  fi
}

require_docker() {
  if ! docker version >/dev/null 2>&1; then
    echo "error: docker daemon access is required" >&2
    exit 1
  fi
}

require_env() {
  if [[ ! -f .env ]]; then
    echo "error: .env not found in ${ROOT}" >&2
    echo "Run ./install.sh or copy .env.example to .env and set secrets." >&2
    exit 1
  fi
}

token_nonempty() {
  [[ -n "${1//[[:space:]]/}" ]]
}

positive_int() {
  case "$1" in
    '' | *[!0-9]*) return 1 ;;
    *) [[ "$1" -gt 0 ]] ;;
  esac
}

section() {
  printf '\n==> %s\n' "$1"
}

clean_template_value() {
  case "$1" in
    "" | "<no value>") printf '' ;;
    *) printf '%s' "$1" ;;
  esac
}

path_usage() {
  local path="$1" usage=""
  if [[ ! -e "$path" ]]; then
    printf 'missing'
    return 0
  fi

  usage="$(du -sh "$path" 2>/dev/null | awk '{print $1}' || true)"
  if [[ -n "$usage" ]]; then
    printf '%s' "$usage"
  else
    printf 'unreadable'
  fi
}

read_secret() {
  local prompt="$1" reply=""
  if [[ -r /dev/tty ]]; then
    read -r -s -p "$prompt" reply </dev/tty
    printf '\n' >/dev/tty
  elif [[ -t 0 ]]; then
    read -r -s -p "$prompt" reply
    printf '\n'
  else
    return 1
  fi
  printf '%s' "$reply"
}

set_env_value() {
  local key="$1" val="$2" tmp
  tmp="$(mktemp "${ROOT}/.env.tmp.XXXXXX")" || die "failed to create temp file"
  if ! awk -v key="$key" -v val="$val" '
    BEGIN { written = 0 }
    {
      if ($0 ~ /^[[:space:]]*#/) {
        print
        next
      }

      eq = index($0, "=")
      if (eq > 0) {
        current = substr($0, 1, eq - 1)
        if (current == key) {
          print key "=" val
          written = 1
          next
        }
      }

      print
    }
    END {
      if (!written) {
        print key "=" val
      }
    }
  ' .env >"$tmp"; then
    rm -f "$tmp"
    die "failed to update .env"
  fi
  mv "$tmp" .env
}

usage() {
  cat <<'EOF'
Usage: manage.sh <command> [args...]

Commands:
  up                                Start services (detached)
  down                              Stop and remove containers
  logs [service]                    Follow logs (optional service: runner, cache-server)
  issues [service]                  Scan recent logs for known runner issues
  issues --file PATH                Scan a saved log file for known runner issues
  ps, status                        Show container status
  restart [svc]                     Restart services
  pull                              Pull latest images
  disk [--top N]                    Diagnose Docker/containerd disk usage
  cleanup <logs|docker|all> [...]   Dry-run or apply safe disk cleanup
  replace-token [--token TOKEN]     Replace RUNNER_TOKEN and re-register runner
  upgrade                           Refresh runtime files and restart (install.sh --update)
  menu                              Interactive menu (default when no args)
  help                              Show this help

Examples:
  ./manage.sh up
  ./manage.sh logs runner
  ./manage.sh issues
  ./manage.sh disk --top 10
  ./manage.sh cleanup logs runner --dry-run
  ./manage.sh cleanup docker --dry-run
  ./manage.sh replace-token --token "$RUNNER_TOKEN"
  ./manage.sh restart
EOF
}

cmd_up() {
  require_env
  require_compose
  "${COMPOSE[@]}" up -d
}

cmd_down() {
  require_compose
  "${COMPOSE[@]}" stop --timeout 60 runner 2>/dev/null || true
  "${COMPOSE[@]}" down --timeout 60
}

cmd_logs() {
  require_compose
  "${COMPOSE[@]}" logs -f "$@"
}

cmd_ps() {
  require_compose
  "${COMPOSE[@]}" ps
}

cmd_restart() {
  require_compose
  if [[ $# -gt 0 ]]; then
    "${COMPOSE[@]}" restart "$@"
  else
    "${COMPOSE[@]}" restart
  fi
}

cmd_pull() {
  require_compose
  "${COMPOSE[@]}" pull
}

disk_usage() {
  local dir="$1" top="${2:-10}" mode="${3:-all}"
  if [[ ! -d "$dir" ]]; then
    echo "  ${dir}: not found"
    return 0
  fi

  if [[ "$mode" == "top" ]]; then
    if ! du -xhd1 "$dir" 2>/dev/null | sort -h | tail -n "$top"; then
      echo "  unable to read ${dir}"
    fi
  else
    if ! du -xhd1 "$dir" 2>/dev/null | sort -h; then
      echo "  unable to read ${dir}"
    fi
  fi
}

print_stack_container_disk() {
  local ids cid summary log_path upper_dir work_dir

  section "Compose Container Writable Layers"
  ids="$("${COMPOSE[@]}" ps -a -q 2>/dev/null || true)"
  if [[ -z "$ids" ]]; then
    echo "  no compose containers found"
    return 0
  fi

  while IFS= read -r cid; do
    [[ -n "$cid" ]] || continue

    summary="$(docker inspect --size -f '  {{.Name}} image={{.Config.Image}} state={{.State.Status}} size_rw={{.SizeRw}}B size_root_fs={{.SizeRootFs}}B' "$cid" 2>/dev/null || true)"
    if [[ -n "$summary" ]]; then
      echo "$summary"
    else
      echo "  ${cid}: unable to inspect"
      continue
    fi

    log_path="$(docker inspect -f '{{.LogPath}}' "$cid" 2>/dev/null || true)"
    log_path="$(clean_template_value "$log_path")"
    if [[ -n "$log_path" ]]; then
      echo "    log: ${log_path} ($(path_usage "$log_path"))"
    else
      echo "    log: unavailable"
    fi

    upper_dir="$(docker inspect -f '{{index .GraphDriver.Data "UpperDir"}}' "$cid" 2>/dev/null || true)"
    upper_dir="$(clean_template_value "$upper_dir")"
    if [[ -n "$upper_dir" ]]; then
      echo "    upper: ${upper_dir} ($(path_usage "$upper_dir"))"
    fi

    work_dir="$(docker inspect -f '{{index .GraphDriver.Data "WorkDir"}}' "$cid" 2>/dev/null || true)"
    work_dir="$(clean_template_value "$work_dir")"
    if [[ -n "$work_dir" ]]; then
      echo "    work: ${work_dir} ($(path_usage "$work_dir"))"
    fi
  done <<<"$ids"
}

print_top_json_logs() {
  local dir="/var/lib/docker/containers" top="$1"

  section "Top Docker JSON Logs"
  if [[ ! -d "$dir" ]]; then
    echo "  ${dir}: not found"
    return 0
  fi

  if ! find "$dir" -type f -name '*-json.log' -exec du -k {} + 2>/dev/null |
    sort -nr |
    head -n "$top" |
    awk '{printf "%.2f GB  %s\n", $1 / 1024 / 1024, $2}'; then
    echo "  unable to inspect Docker JSON logs"
  fi
}

print_runner_container_usage() {
  local ids cid running top="$1"

  section "Runner Container Internal Usage"
  ids="$("${COMPOSE[@]}" ps -q runner 2>/dev/null || true)"
  cid="$(printf '%s\n' "$ids" | head -n 1)"
  if [[ -z "$cid" ]]; then
    echo "  runner container is not present"
    return 0
  fi

  running="$(docker inspect -f '{{.State.Running}}' "$cid" 2>/dev/null || true)"
  if [[ "$running" != "true" ]]; then
    echo "  runner container is not running"
    return 0
  fi

  if ! docker exec "$cid" sh -lc "echo 'Top /home/runner and /tmp directories:'; du -h -d 1 /home/runner /tmp 2>/dev/null | sort -h | tail -n ${top}; echo; echo 'Common runner paths:'; for p in /home/runner/_work /home/runner/.cache /home/runner/.npm /home/runner/.bun /home/runner/.local /tmp; do [ -e \"\$p\" ] && du -sh \"\$p\" 2>/dev/null; done | sort -h"; then
    echo "  unable to inspect inside runner container"
  fi
}

disk_usage_usage() {
  cat <<'EOF'
Usage: manage.sh disk [--top N]

Shows Docker/containerd disk diagnostics without deleting anything.

Options:
  --top N   Number of largest entries to show for ranked lists (default: 10)
EOF
}

cmd_disk() {
  local top=10
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --top)
        [[ $# -ge 2 ]] || die "--top requires a value"
        top="$2"
        shift 2
        ;;
      --top=*)
        top="${1#--top=}"
        shift
        ;;
      -h | --help)
        disk_usage_usage
        return 0
        ;;
      *)
        die "unknown disk argument: $1"
        ;;
    esac
  done

  positive_int "$top" || die "--top must be a positive integer"
  require_compose
  require_docker

  section "Docker System Usage"
  docker system df -v || true

  section "Docker Containers With Size"
  docker ps -a --size || true

  print_stack_container_disk
  print_top_json_logs "$top"

  section "/var/lib/docker Usage"
  disk_usage /var/lib/docker "$top" all

  section "/var/lib/containerd Usage"
  disk_usage /var/lib/containerd "$top" all

  section "Top containerd Overlay Snapshots"
  disk_usage /var/lib/containerd/io.containerd.snapshotter.v1.overlayfs/snapshots "$top" top

  print_runner_container_usage "$top"
}

cmd_upgrade() {
  curl -fsSL "$INSTALL_SH_URL" | bash -s -- --update
}

cleanup_usage() {
  cat <<'EOF'
Usage: manage.sh cleanup <logs|docker|all> [options]

Safe cleanup tools default to --dry-run. Use --apply to delete or truncate.

Commands:
  cleanup logs [service|--all] [--dry-run|--apply]
      Truncate Docker JSON logs for compose-managed containers only.

  cleanup docker [--dry-run|--apply] [--until 168h] [--all-images]
      Prune stopped containers, images, and build cache. Volumes are never pruned.

  cleanup all [--dry-run|--apply] [--until 168h] [--all-images]
      Run log cleanup for all compose services, then Docker cleanup.
EOF
}

is_json_log_path() {
  case "$1" in
    */containers/*/*-json.log) return 0 ;;
    *) return 1 ;;
  esac
}

compose_container_ids() {
  local target="$1"
  if [[ "$target" == "__all__" ]]; then
    "${COMPOSE[@]}" ps -a -q
  else
    "${COMPOSE[@]}" ps -a -q "$target"
  fi
}

cleanup_log_for_container() {
  local cid="$1" mode="$2" name log_path usage_before

  name="$(docker inspect -f '{{.Name}}' "$cid" 2>/dev/null || true)"
  name="${name#/}"
  [[ -n "$name" ]] || name="$cid"

  log_path="$(docker inspect -f '{{.LogPath}}' "$cid" 2>/dev/null || true)"
  log_path="$(clean_template_value "$log_path")"
  if [[ -z "$log_path" ]]; then
    echo "  ${name}: no Docker log path reported"
    return 0
  fi

  if ! is_json_log_path "$log_path"; then
    echo "  ${name}: skipping non-json log path: ${log_path}"
    return 0
  fi

  usage_before="$(path_usage "$log_path")"
  if [[ "$mode" == "apply" ]]; then
    if : >"$log_path"; then
      echo "  truncated ${name}: ${log_path} (${usage_before} before)"
    else
      echo "  failed to truncate ${name}: ${log_path}" >&2
      return 1
    fi
  else
    echo "  would truncate ${name}: ${log_path} (${usage_before})"
  fi
}

cmd_cleanup_logs() {
  local mode="dry-run" target="runner" target_set=0 ids cid failed=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run)
        mode="dry-run"
        shift
        ;;
      --apply)
        mode="apply"
        shift
        ;;
      --all)
        target="__all__"
        target_set=1
        shift
        ;;
      -h | --help)
        cleanup_usage
        return 0
        ;;
      *)
        if [[ "$target_set" == "0" ]]; then
          target="$1"
          target_set=1
          shift
        else
          die "unknown cleanup logs argument: $1"
        fi
        ;;
    esac
  done

  require_compose
  require_docker

  section "Docker JSON Log Cleanup (${mode})"
  ids="$(compose_container_ids "$target")" || die "failed to find compose containers"
  if [[ -z "$ids" ]]; then
    if [[ "$target" == "__all__" ]]; then
      echo "  no compose containers found"
    else
      echo "  no compose container found for service: ${target}"
    fi
    return 0
  fi

  while IFS= read -r cid; do
    [[ -n "$cid" ]] || continue
    cleanup_log_for_container "$cid" "$mode" || failed=1
  done <<<"$ids"

  if [[ "$mode" == "dry-run" ]]; then
    echo "  dry-run only; re-run with --apply to truncate these logs"
  fi

  [[ "$failed" == "0" ]]
}

cmd_cleanup_docker() {
  local mode="dry-run" until="168h" all_images=0 image_args

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run)
        mode="dry-run"
        shift
        ;;
      --apply)
        mode="apply"
        shift
        ;;
      --until)
        [[ $# -ge 2 ]] || die "--until requires a value"
        until="$2"
        shift 2
        ;;
      --until=*)
        until="${1#--until=}"
        shift
        ;;
      --all-images)
        all_images=1
        shift
        ;;
      -h | --help)
        cleanup_usage
        return 0
        ;;
      *)
        die "unknown cleanup docker argument: $1"
        ;;
    esac
  done

  [[ -n "$until" && "$until" != *[[:space:]]* ]] || die "--until must be a Docker duration or timestamp without spaces"
  require_docker

  section "Docker Prune Cleanup (${mode})"
  if [[ "$mode" == "dry-run" ]]; then
    echo "  no changes will be made"
    echo "  would run: docker container prune -f --filter until=${until}"
    if [[ "$all_images" == "1" ]]; then
      echo "  would run: docker image prune -a -f --filter until=${until}"
    else
      echo "  would run: docker image prune -f --filter until=${until}"
    fi
    echo "  would run: docker builder prune -f --filter until=${until}"
    echo "  volumes will not be pruned"

    section "Current Docker Reclaimable Usage"
    docker system df -v || true
    return 0
  fi

  echo "  pruning stopped containers older than ${until}"
  docker container prune -f --filter "until=${until}"

  echo "  pruning images older than ${until}"
  image_args=(image prune -f --filter "until=${until}")
  if [[ "$all_images" == "1" ]]; then
    image_args=(image prune -a -f --filter "until=${until}")
  fi
  docker "${image_args[@]}"

  echo "  pruning build cache older than ${until}"
  docker builder prune -f --filter "until=${until}"
  echo "  volumes were not pruned"
}

cmd_cleanup_all() {
  local mode="dry-run" until="168h" all_images=0
  local log_args docker_args

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run)
        mode="dry-run"
        shift
        ;;
      --apply)
        mode="apply"
        shift
        ;;
      --until)
        [[ $# -ge 2 ]] || die "--until requires a value"
        until="$2"
        shift 2
        ;;
      --until=*)
        until="${1#--until=}"
        shift
        ;;
      --all-images)
        all_images=1
        shift
        ;;
      -h | --help)
        cleanup_usage
        return 0
        ;;
      *)
        die "unknown cleanup all argument: $1"
        ;;
    esac
  done

  log_args=(--all)
  docker_args=(--until "$until")
  if [[ "$mode" == "apply" ]]; then
    log_args+=(--apply)
    docker_args+=(--apply)
  else
    log_args+=(--dry-run)
    docker_args+=(--dry-run)
  fi
  if [[ "$all_images" == "1" ]]; then
    docker_args+=(--all-images)
  fi

  cmd_cleanup_logs "${log_args[@]}"
  cmd_cleanup_docker "${docker_args[@]}"
}

cmd_cleanup() {
  local subcommand="${1:-}"
  if [[ $# -gt 0 ]]; then
    shift
  fi

  case "$subcommand" in
    logs) cmd_cleanup_logs "$@" ;;
    docker) cmd_cleanup_docker "$@" ;;
    all) cmd_cleanup_all "$@" ;;
    help | -h | --help | "") cleanup_usage ;;
    *) die "unknown cleanup command: ${subcommand}" ;;
  esac
}

replace_token_usage() {
  cat <<'EOF'
Usage: manage.sh replace-token [--token TOKEN] [--no-restart]

Updates RUNNER_TOKEN in .env, sets RUNNER_REPLACE=true, clears the persisted
runner registration files from the runner-data volume, and starts the runner.

Options:
  --token TOKEN   New GitHub runner registration token
  --no-restart   Only update .env; do not clear config or restart
EOF
}

clear_runner_registration() {
  require_compose
  echo "==> Stopping runner"
  "${COMPOSE[@]}" stop --timeout 60 runner 2>/dev/null || true

  echo "==> Removing stopped runner container"
  "${COMPOSE[@]}" rm -f runner 2>/dev/null || true

  echo "==> Clearing persisted runner registration"
  "${COMPOSE[@]}" run --rm --no-deps --entrypoint sh runner -c 'rm -f /config/.runner /config/.credentials /config/.credentials_rsaparams'
}

cmd_replace_token() {
  local token="" restart=1
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --token)
        [[ $# -ge 2 ]] || die "--token requires a value"
        token="$2"
        shift 2
        ;;
      --token=*)
        token="${1#--token=}"
        shift
        ;;
      --restart)
        restart=1
        shift
        ;;
      --no-restart)
        restart=0
        shift
        ;;
      -h | --help)
        replace_token_usage
        return 0
        ;;
      *)
        if [[ -z "$token" ]]; then
          token="$1"
          shift
        else
          die "unknown replace-token argument: $1"
        fi
        ;;
    esac
  done

  require_env

  if ! token_nonempty "$token"; then
    token="$(read_secret "RUNNER_TOKEN (hidden): ")" || die "RUNNER_TOKEN required (stdin is not a TTY; use --token or run from a terminal)"
  fi
  token_nonempty "$token" || die "RUNNER_TOKEN cannot be empty"

  set_env_value RUNNER_TOKEN "$token"
  set_env_value RUNNER_REPLACE true
  echo "==> Updated .env (RUNNER_TOKEN=***, RUNNER_REPLACE=true)"

  if [[ "$restart" == "0" ]]; then
    echo "==> Skipping re-registration; the new token will not be used until runner registration files are cleared"
    return 0
  fi

  clear_runner_registration
  echo "==> Starting runner with new registration token"
  "${COMPOSE[@]}" up -d runner
}

short_log_line() {
  local line="$1"
  line="${line#*| }"
  if [[ ${#line} -gt 220 ]]; then
    line="${line:0:217}..."
  fi
  printf '%s' "$line"
}

print_issue() {
  local title="$1" evidence="$2" fix="$3"
  echo "  - ${title}"
  if [[ -n "$evidence" ]]; then
    echo "    evidence: $(short_log_line "$evidence")"
  fi
  echo "    fix: ${fix}"
}

diagnose_logs() {
  local line lower found=0 saw_log=0 target_line=""
  local stale_token=0 stale_token_line=""
  local missing_token=0 missing_token_line=""
  local unauthorized=0 unauthorized_line=""
  local forbidden=0 forbidden_line=""
  local already_configured=0 already_configured_line=""
  local session_conflict=0 session_conflict_line=""
  local url_mismatch=0 url_mismatch_line=""
  local network=0 network_line=""
  local runner_failed=0 runner_failed_line=""

  while IFS= read -r line || [[ -n "$line" ]]; do
    saw_log=1
    lower="$(tolower "$line")"

    if [[ -z "$target_line" && "$line" == *"Configuring runner "* ]]; then
      target_line="$line"
    fi

    if [[ "$line" == *"actions/runner-registration"* && "$line" == *"NotFound"* ]] ||
      [[ "$line" == *"Response status code does not indicate success: 404"* ]] ||
      [[ "$line" == *'"status":"404"'* ]] ||
      [[ "$lower" == *"runner registration token"* && "$lower" == *"expired"* ]] ||
      [[ "$lower" == *"invalid"* && "$lower" == *"runner registration token"* ]]; then
      stale_token=1
      [[ -z "$stale_token_line" ]] && stale_token_line="$line"
    fi

    if [[ "$line" == *"RUNNER_TOKEN is required"* ]] || [[ "$line" == *"RUNNER_TOKEN is empty"* ]]; then
      missing_token=1
      [[ -z "$missing_token_line" ]] && missing_token_line="$line"
    fi

    if [[ "$line" == *"Response status code does not indicate success: 401"* ]] ||
      [[ "$line" == *'"status":"401"'* ]] ||
      [[ "$line" == *"Unauthorized"* ]]; then
      unauthorized=1
      [[ -z "$unauthorized_line" ]] && unauthorized_line="$line"
    fi

    if [[ "$line" == *"Response status code does not indicate success: 403"* ]] ||
      [[ "$line" == *'"status":"403"'* ]] ||
      [[ "$line" == *"Forbidden"* ]]; then
      forbidden=1
      [[ -z "$forbidden_line" ]] && forbidden_line="$line"
    fi

    if [[ "$lower" == *"already configured"* ]]; then
      already_configured=1
      [[ -z "$already_configured_line" ]] && already_configured_line="$line"
    fi

    if [[ "$line" == *"A session for this runner already exists"* ]]; then
      session_conflict=1
      [[ -z "$session_conflict_line" ]] && session_conflict_line="$line"
    fi

    if [[ "$line" == *"differs from configured"* ]]; then
      url_mismatch=1
      [[ -z "$url_mismatch_line" ]] && url_mismatch_line="$line"
    fi

    if [[ "$lower" == *"could not resolve"* ]] ||
      [[ "$lower" == *"connection refused"* ]] ||
      [[ "$lower" == *"connection timed out"* ]] ||
      [[ "$lower" == *"name or service not known"* ]] ||
      [[ "$lower" == *"temporary failure in name resolution"* ]]; then
      network=1
      [[ -z "$network_line" ]] && network_line="$line"
    fi

    if [[ "$line" == *"Runner execution has finished with return code"* ]] ||
      [[ "$line" == *"return code 1"* ]]; then
      runner_failed=1
      [[ -z "$runner_failed_line" ]] && runner_failed_line="$line"
    fi
  done

  echo "Runner log issues:"
  if [[ -n "$target_line" ]]; then
    echo "  target: $(short_log_line "$target_line")"
  fi

  if [[ "$saw_log" == "0" ]]; then
    echo "  no log lines received"
    return 0
  fi

  if [[ "$stale_token" == "1" ]]; then
    print_issue "Stale, expired, or wrong-scope RUNNER_TOKEN" "$stale_token_line" "Generate a fresh token for GITHUB_URL, then run ./manage.sh replace-token --token \"\$RUNNER_TOKEN\"."
    found=1
  fi
  if [[ "$missing_token" == "1" ]]; then
    print_issue "Missing RUNNER_TOKEN" "$missing_token_line" "Set RUNNER_TOKEN or run ./manage.sh replace-token --token \"\$RUNNER_TOKEN\"."
    found=1
  fi
  if [[ "$unauthorized" == "1" ]]; then
    print_issue "Unauthorized registration request" "$unauthorized_line" "Generate a fresh token and confirm it belongs to the repository or organization in GITHUB_URL."
    found=1
  fi
  if [[ "$forbidden" == "1" ]]; then
    print_issue "Forbidden registration request" "$forbidden_line" "Confirm the token was generated by an account with access to the target repository or organization."
    found=1
  fi
  if [[ "$already_configured" == "1" ]]; then
    print_issue "Runner already has persisted config" "$already_configured_line" "Use replace-token to clear runner-data registration files before re-registering."
    found=1
  fi
  if [[ "$session_conflict" == "1" ]]; then
    print_issue "Runner session conflict" "$session_conflict_line" "Stop any legacy host runner, wait for the old session to clear, then restart the stack."
    found=1
  fi
  if [[ "$url_mismatch" == "1" ]]; then
    print_issue "GITHUB_URL does not match persisted runner config" "$url_mismatch_line" "Fix GITHUB_URL or run replace-token to re-register against the intended target."
    found=1
  fi
  if [[ "$network" == "1" ]]; then
    print_issue "Network or DNS issue" "$network_line" "Check DNS, proxy, firewall, and outbound GitHub access from the runner host/container."
    found=1
  fi
  if [[ "$runner_failed" == "1" ]]; then
    print_issue "Runner process exited non-zero" "$runner_failed_line" "Review the specific issue above, then inspect full logs if no specific issue was detected."
    found=1
  fi

  if [[ "$found" == "0" ]]; then
    echo "  none: no known registration, token, session, URL, or network issue was detected"
  fi
}

issues_usage() {
  cat <<'EOF'
Usage: manage.sh issues [service] [--tail N]
       manage.sh issues --file PATH

Scans runner logs for common registration, token, session, URL, and network
issues. Defaults to the last 300 log lines from the runner service.
EOF
}

cmd_issues() {
  local file="" tail=300 service="runner" service_set=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --file)
        [[ $# -ge 2 ]] || die "--file requires a path"
        file="$2"
        shift 2
        ;;
      --file=*)
        file="${1#--file=}"
        shift
        ;;
      --tail)
        [[ $# -ge 2 ]] || die "--tail requires a value"
        tail="$2"
        shift 2
        ;;
      --tail=*)
        tail="${1#--tail=}"
        shift
        ;;
      -h | --help)
        issues_usage
        return 0
        ;;
      *)
        if [[ "$service_set" == "0" ]]; then
          service="$1"
          service_set=1
          shift
        else
          die "unknown issues argument: $1"
        fi
        ;;
    esac
  done

  if [[ -n "$file" ]]; then
    if [[ "$file" == "-" ]]; then
      diagnose_logs
    else
      [[ -f "$file" ]] || die "log file not found: ${file}"
      diagnose_logs <"$file"
    fi
    return 0
  fi

  case "$tail" in
    '' | *[!0-9]*) die "--tail must be a positive integer" ;;
  esac
  require_compose
  "${COMPOSE[@]}" logs --no-color --tail "$tail" "$service" | diagnose_logs
}

run_command() {
  local cmd="${1:-}"
  shift || true
  case "$cmd" in
    up) cmd_up ;;
    down) cmd_down ;;
    logs) cmd_logs "$@" ;;
    issues | diagnose) cmd_issues "$@" ;;
    ps | status) cmd_ps ;;
    restart) cmd_restart "$@" ;;
    pull) cmd_pull ;;
    disk | df) cmd_disk "$@" ;;
    cleanup | clean) cmd_cleanup "$@" ;;
    replace-token | token | rotate-token) cmd_replace_token "$@" ;;
    --token | --token=*) cmd_replace_token "$cmd" "$@" ;;
    upgrade) cmd_upgrade ;;
    help | -h | --help) usage ;;
    menu | "") menu_loop ;;
    *)
      echo "error: unknown command: ${cmd}" >&2
      echo >&2
      usage >&2
      exit 1
      ;;
  esac
}

menu_loop() {
  while true; do
    echo
    PS3="Choose an action: "
    # shellcheck disable=SC2034
    select choice in "Up" "Down" "Logs" "View Issues" "Status" "Disk Usage" "Cleanup Dry Run" "Restart" "Pull" "Replace Token" "Upgrade" "Quit"; do
      case "$REPLY" in
        1)
          cmd_up
          read -r -p "Press Enter to continue..."
          ;;
        2)
          cmd_down
          read -r -p "Press Enter to continue..."
          ;;
        3)
          cmd_logs
          ;;
        4)
          cmd_issues
          read -r -p "Press Enter to continue..."
          ;;
        5)
          cmd_ps
          read -r -p "Press Enter to continue..."
          ;;
        6)
          cmd_disk
          read -r -p "Press Enter to continue..."
          ;;
        7)
          cmd_cleanup all --dry-run
          read -r -p "Press Enter to continue..."
          ;;
        8)
          cmd_restart
          read -r -p "Press Enter to continue..."
          ;;
        9)
          cmd_pull
          read -r -p "Press Enter to continue..."
          ;;
        10)
          read -r -p "Replace RUNNER_TOKEN and re-register runner? (y/N): " confirm
          case "$(tolower "$confirm")" in
            y | yes)
              cmd_replace_token
              ;;
            *)
              echo "Skipped."
              ;;
          esac
          read -r -p "Press Enter to continue..."
          ;;
        11)
          cmd_upgrade
          read -r -p "Press Enter to continue..."
          ;;
        12)
          exit 0
          ;;
        *)
          echo "Invalid choice."
          ;;
      esac
      break
    done
  done
}

if [[ $# -eq 0 ]]; then
  menu_loop
else
  run_command "$@"
fi
