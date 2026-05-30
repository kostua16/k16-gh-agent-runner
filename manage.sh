#!/usr/bin/env bash
# Manage the production runner stack (docker compose).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

COMPOSE=(docker compose -f docker-compose.yml)

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

usage() {
  cat <<'EOF'
Usage: manage.sh <command> [args...]

Commands:
  up              Start services (detached)
  down            Stop and remove containers
  logs [service]  Follow logs (optional service: runner, cache-server)
  ps, status      Show container status
  restart [svc]   Restart services
  pull            Pull latest images
  menu            Interactive menu (default when no args)
  help            Show this help

Examples:
  ./manage.sh up
  ./manage.sh logs runner
  ./manage.sh restart
EOF
}

cmd_up() {
  require_env
  "${COMPOSE[@]}" up -d
}

cmd_down() {
  "${COMPOSE[@]}" down
}

cmd_logs() {
  "${COMPOSE[@]}" logs -f "$@"
}

cmd_ps() {
  "${COMPOSE[@]}" ps
}

cmd_restart() {
  if [[ $# -gt 0 ]]; then
    "${COMPOSE[@]}" restart "$@"
  else
    "${COMPOSE[@]}" restart
  fi
}

cmd_pull() {
  "${COMPOSE[@]}" pull
}

run_command() {
  local cmd="${1:-}"
  shift || true
  case "$cmd" in
    up) cmd_up ;;
    down) cmd_down ;;
    logs) cmd_logs "$@" ;;
    ps | status) cmd_ps ;;
    restart) cmd_restart "$@" ;;
    pull) cmd_pull ;;
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
    select choice in "Up" "Down" "Logs" "Status" "Restart" "Pull" "Quit"; do
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
          cmd_ps
          read -r -p "Press Enter to continue..."
          ;;
        5)
          cmd_restart
          read -r -p "Press Enter to continue..."
          ;;
        6)
          cmd_pull
          read -r -p "Press Enter to continue..."
          ;;
        7)
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

require_compose

if [[ $# -eq 0 ]]; then
  menu_loop
else
  run_command "$@"
fi
