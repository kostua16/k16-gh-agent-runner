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
  replace-token [--token TOKEN]     Replace RUNNER_TOKEN and re-register runner
  upgrade                           Refresh runtime files and restart (install.sh --update)
  menu                              Interactive menu (default when no args)
  help                              Show this help

Examples:
  ./manage.sh up
  ./manage.sh logs runner
  ./manage.sh issues
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

cmd_upgrade() {
  curl -fsSL "$INSTALL_SH_URL" | bash -s -- --update
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
    print_issue "Stale, expired, or wrong-scope RUNNER_TOKEN" "$stale_token_line" 'Generate a fresh token for GITHUB_URL, then run ./manage.sh replace-token --token "$RUNNER_TOKEN".'
    found=1
  fi
  if [[ "$missing_token" == "1" ]]; then
    print_issue "Missing RUNNER_TOKEN" "$missing_token_line" 'Set RUNNER_TOKEN or run ./manage.sh replace-token --token "$RUNNER_TOKEN".'
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
    select choice in "Up" "Down" "Logs" "View Issues" "Status" "Restart" "Pull" "Replace Token" "Upgrade" "Quit"; do
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
          cmd_restart
          read -r -p "Press Enter to continue..."
          ;;
        7)
          cmd_pull
          read -r -p "Press Enter to continue..."
          ;;
        8)
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
        9)
          cmd_upgrade
          read -r -p "Press Enter to continue..."
          ;;
        10)
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
