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
  cleanup <logs|docker|volumes|all> [...]
                                    Dry-run or apply safe disk cleanup
  replace-token [--token TOKEN]     Replace RUNNER_TOKEN and re-register runner
  upgrade [--token TOKEN] [--all] [--prune-unused]
                                    Refresh runtime files and restart (install.sh --update)
  menu                              Interactive menu (default when no args)
  help                              Show this help

Examples:
  ./manage.sh up
  ./manage.sh logs runner
  ./manage.sh issues
  ./manage.sh disk --top 10
  ./manage.sh cleanup volumes --dry-run
  ./manage.sh cleanup logs runner --dry-run
  ./manage.sh cleanup docker --dry-run
  ./manage.sh cleanup docker --prune --dry-run
  ./manage.sh cleanup docker --dangerous --dry-run
  ./manage.sh replace-token --token "$RUNNER_TOKEN"
  ./manage.sh upgrade --token "$RUNNER_TOKEN"
  ./manage.sh upgrade --all
  ./manage.sh upgrade --all --prune-unused
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

env_file_value() {
  local key="$1"
  [[ -f .env ]] || return 1
  awk -v key="$key" '
    /^[[:space:]]*#/ { next }
    {
      eq = index($0, "=")
      if (eq > 0 && substr($0, 1, eq - 1) == key) {
        print substr($0, eq + 1)
        exit
      }
    }
  ' .env
}

compose_project_name() {
  local name="${COMPOSE_PROJECT_NAME:-}"
  if [[ -z "$name" ]]; then
    name="$(env_file_value COMPOSE_PROJECT_NAME 2>/dev/null || true)"
  fi
  if [[ -z "$name" ]]; then
    name="$(basename "$ROOT")"
  fi
  printf '%s' "$name"
}

compose_declared_volumes() {
  local volumes
  volumes="$("${COMPOSE[@]}" config --volumes 2>/dev/null || true)"
  if [[ -n "$volumes" ]]; then
    printf '%s\n' "$volumes"
  else
    printf '%s\n' cache-data runner-data
  fi
}

compose_volume_names() {
  local project logical ids cid
  project="$(compose_project_name)"

  {
    while IFS= read -r logical; do
      [[ -n "$logical" ]] || continue
      docker volume ls -q \
        --filter "label=com.docker.compose.project=${project}" \
        --filter "label=com.docker.compose.volume=${logical}" 2>/dev/null || true

      if docker volume inspect "${project}_${logical}" >/dev/null 2>&1; then
        printf '%s\n' "${project}_${logical}"
      fi
      if docker volume inspect "$logical" >/dev/null 2>&1; then
        printf '%s\n' "$logical"
      fi
    done <<<"$(compose_declared_volumes)"

    ids="$("${COMPOSE[@]}" ps -a -q 2>/dev/null || true)"
    while IFS= read -r cid; do
      [[ -n "$cid" ]] || continue
      docker inspect -f '{{range .Mounts}}{{if eq .Type "volume"}}{{.Name}}{{"\n"}}{{end}}{{end}}' "$cid" 2>/dev/null || true
    done <<<"$ids"
  } | awk 'NF && !seen[$0]++'
}

volume_label() {
  local volume="$1" key="$2" value
  value="$(docker volume inspect -f "{{ index .Labels \"${key}\" }}" "$volume" 2>/dev/null || true)"
  clean_template_value "$value"
}

volume_mountpoint() {
  local volume="$1" mountpoint
  mountpoint="$(docker volume inspect -f '{{.Mountpoint}}' "$volume" 2>/dev/null || true)"
  clean_template_value "$mountpoint"
}

volume_logical_name() {
  local volume="$1" logical
  logical="$(volume_label "$volume" "com.docker.compose.volume")"
  if [[ -z "$logical" ]]; then
    case "$volume" in
      *_cache-data) logical="cache-data" ;;
      *_runner-data) logical="runner-data" ;;
      *) logical="$volume" ;;
    esac
  fi
  printf '%s' "$logical"
}

find_compose_volume() {
  local logical="$1" volumes volume
  volumes="$(compose_volume_names)"
  while IFS= read -r volume; do
    [[ -n "$volume" ]] || continue
    if [[ "$(volume_logical_name "$volume")" == "$logical" ]]; then
      printf '%s\n' "$volume"
      return 0
    fi
  done <<<"$volumes"
  return 1
}

safe_volume_mountpoint() {
  case "$1" in
    "" | "/" | "/var" | "/var/lib" | "/var/lib/docker" | "/var/lib/docker/volumes") return 1 ;;
    */_data) return 0 ;;
    *) return 1 ;;
  esac
}

print_runner_volume_candidates() {
  local mountpoint="$1" found
  echo "    expected runner-data files: .runner, .credentials, .credentials_rsaparams"
  if [[ ! -d "$mountpoint" ]]; then
    return 0
  fi

  found="$(find "$mountpoint" -mindepth 1 -maxdepth 1 \
    ! -name .runner \
    ! -name .credentials \
    ! -name .credentials_rsaparams \
    -print -quit 2>/dev/null || true)"
  if [[ -z "$found" ]]; then
    echo "    cleanup candidates: none"
    return 0
  fi

  echo "    cleanup candidates (non-registration top-level entries):"
  find "$mountpoint" -mindepth 1 -maxdepth 1 \
    ! -name .runner \
    ! -name .credentials \
    ! -name .credentials_rsaparams \
    -exec du -sh {} + 2>/dev/null | sort -h | sed 's/^/      /' || true
}

print_cache_volume_candidates() {
  local mountpoint="$1" path found=0
  if [[ ! -d "$mountpoint" ]]; then
    return 0
  fi

  echo "    cache cleanup candidates:"
  for path in \
    "${mountpoint}/cache" \
    "${mountpoint}/cache-server.db" \
    "${mountpoint}/cache-server.db-shm" \
    "${mountpoint}/cache-server.db-wal"; do
    if [[ -e "$path" ]]; then
      echo "      $(path_usage "$path")  ${path}"
      found=1
    fi
  done
  if [[ "$found" == "0" ]]; then
    echo "      none"
  fi
}

print_compose_volumes() {
  local top="$1" volumes volume logical project mountpoint

  section "Compose Volumes"
  volumes="$(compose_volume_names)"
  if [[ -z "$volumes" ]]; then
    echo "  no compose volumes found"
    return 0
  fi

  while IFS= read -r volume; do
    [[ -n "$volume" ]] || continue
    logical="$(volume_logical_name "$volume")"
    project="$(volume_label "$volume" "com.docker.compose.project")"
    mountpoint="$(volume_mountpoint "$volume")"

    echo "  ${volume}"
    [[ -n "$project" ]] && echo "    project: ${project}"
    echo "    logical: ${logical}"
    if [[ -n "$mountpoint" ]]; then
      echo "    mountpoint: ${mountpoint} ($(path_usage "$mountpoint"))"
      if [[ -d "$mountpoint" ]]; then
        echo "    top contents:"
        disk_usage "$mountpoint" "$top" top | sed 's/^/      /'
      fi
    else
      echo "    mountpoint: unavailable"
    fi

    case "$logical" in
      runner-data) print_runner_volume_candidates "$mountpoint" ;;
      cache-data) print_cache_volume_candidates "$mountpoint" ;;
    esac
  done <<<"$volumes"
}

disk_usage_usage() {
  cat <<'EOF'
Usage: manage.sh disk [--top N]

Shows Docker/containerd disk and compose volume diagnostics without deleting
anything.

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
  print_compose_volumes "$top"
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
  local prune_unused=0
  local -a pass_through=()

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --prune-unused | --prune-unused=*)
        prune_unused=1
        shift
        ;;
      *)
        pass_through+=("$1")
        shift
        ;;
    esac
  done

  # --prune-unused is owned by manage.sh and stripped from the install.sh
  # passthrough so install.sh never sees it. After a successful upgrade the new
  # runner image is already pulled and referenced by the recreated container,
  # so pruning removes only the prior versions left behind by repeated pulls.
  if [[ ${#pass_through[@]} -gt 0 ]]; then
    curl -fsSL "$INSTALL_SH_URL" | bash -s -- --update "${pass_through[@]}"
  else
    curl -fsSL "$INSTALL_SH_URL" | bash -s -- --update
  fi

  if [[ "$prune_unused" == "1" ]]; then
    require_docker
    section "Post-upgrade image cleanup (--prune-unused)"
    echo "  removing all unused images and build cache (no age filter)"
    echo "  warning: images not used by any container are deleted, including rollback versions"
    cmd_cleanup_docker --prune --apply
  fi
}

cleanup_usage() {
  cat <<'EOF'
Usage: manage.sh cleanup <logs|docker|volumes|all> [options]

Safe cleanup tools default to --dry-run. Use --apply to delete or truncate.

Commands:
  cleanup logs [service|--all] [--dry-run|--apply]
      Truncate Docker JSON logs for compose-managed containers only.

  cleanup docker [--dry-run|--apply] [--until 168h] [--all-images]
                 [--prune] [--volumes] [--dangerous]
      Prune stopped containers/images/build cache older than --until (default).
        --prune     drop the age filter; prune ALL unused images + build cache
                    (incl. buildx builder cache) and reclaim /var/lib/containerd
                    space under the image store.
        --volumes   reset OUR volumes only: back up runner-data registration,
                    compose down, rm cache-data + runner-data, recreate
                    runner-data and restore registration, compose up. Stack
                    downtime. Never host-wide.
        --dangerous --prune + --volumes.
      The default prune never touches volumes or networks.

  cleanup volumes [cache|runner-data|--all] [--dry-run|--apply]
      Safe, selective volume cleanup (keeps runner registration). --apply
      requires an explicit target. For a full volume reset with backup, use
      "cleanup docker --volumes" instead.

  cleanup all [--dry-run|--apply] [--until 168h] [--all-images]
              [--prune] [--volumes] [--dangerous]
      Log cleanup for all compose services, then Docker cleanup with the same
      prune/volumes/dangerous flags forwarded.
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

# Reset our own compose volumes with a backup/restore of runner registration.
# Scoped to cache-data + runner-data only (never host-wide system prune --volumes).
# Causes stack downtime: back up registration -> compose down -> rm volumes ->
# recreate runner-data -> restore registration -> compose up.
cmd_cleanup_docker_volumes() {
  local mode="$1"
  local cache_vol runner_vol ts backup_dir backup_name reg_exists=0 runner_image

  require_env
  require_compose

  cache_vol="$(find_compose_volume cache-data 2>/dev/null || true)"
  runner_vol="$(find_compose_volume runner-data 2>/dev/null || true)"
  runner_image="$(env_file_value RUNNER_IMAGE 2>/dev/null || true)"
  [[ -n "$runner_image" ]] || runner_image="ghcr.io/kostua16/k16-gh-agent-runner:latest"

  section "Docker Volume Reset (${mode})"
  echo "  scoped to our compose volumes only (never host-wide)"
  [[ -n "$cache_vol" ]] && echo "  cache-data: ${cache_vol}"
  [[ -n "$runner_vol" ]] && echo "  runner-data: ${runner_vol}"
  if [[ -z "$cache_vol" && -z "$runner_vol" ]]; then
    echo "  no compose volumes found; nothing to reset"
    return 0
  fi

  ts="$(date -u +%Y%m%d-%H%M%S)"
  backup_dir="${ROOT}/backups"
  backup_name="runner-data-${ts}.tar.gz"

  if [[ "$mode" == "dry-run" ]]; then
    if [[ -n "$runner_vol" ]]; then
      echo "  would back up runner-data registration to: ${backup_dir}/${backup_name}"
      echo "  would stop + remove containers (compose down --timeout 60)"
      echo "  would remove + recreate volume: ${runner_vol}"
      echo "  would restore .runner / .credentials / .credentials_rsaparams into ${runner_vol}"
    fi
    [[ -n "$cache_vol" ]] && echo "  would remove volume: ${cache_vol} (recreated empty on compose up)"
    echo "  would start the stack (compose up -d)"
    echo "  warning: stack downtime during reset"
    echo "  dry-run only; re-run with --apply to reset volumes"
    return 0
  fi

  mkdir -p "$backup_dir"

  if [[ -n "$runner_vol" ]]; then
    docker run --rm --entrypoint sh -v "${runner_vol}:/data:ro" "$runner_image" -c '[ -e /data/.runner ]' >/dev/null 2>&1 && reg_exists=1
    if [[ "$reg_exists" == "1" ]]; then
      echo "  backing up runner-data registration to ${backup_dir}/${backup_name}"
      if ! docker run --rm --entrypoint sh -v "${runner_vol}:/data:ro" -v "${backup_dir}:/backup" "$runner_image" \
          -c "cd /data && tar czf /backup/${backup_name} --ignore-failed-read .runner .credentials .credentials_rsaparams" >/dev/null 2>&1 ||
         [[ ! -s "${backup_dir}/${backup_name}" ]]; then
        die "runner-data backup failed or is empty; aborting before any destructive action"
      fi
      echo "  backup ok: ${backup_dir}/${backup_name} ($(path_usage "${backup_dir}/${backup_name}"))"
    else
      echo "  no runner registration in ${runner_vol}; nothing to back up"
    fi
  fi

  echo "  stopping and removing containers"
  "${COMPOSE[@]}" down --timeout 60

  if [[ -n "$cache_vol" ]]; then
    echo "  removing volume ${cache_vol}"
    docker volume rm "$cache_vol" >/dev/null 2>&1 || echo "  warning: could not remove ${cache_vol} (still in use?)"
  fi

  if [[ -n "$runner_vol" ]]; then
    echo "  removing volume ${runner_vol}"
    if ! docker volume rm "$runner_vol" >/dev/null 2>&1; then
      if [[ "$reg_exists" == "1" ]]; then
        echo "  warning: could not remove ${runner_vol}; registration backup is safe at ${backup_dir}/${backup_name}"
      else
        echo "  warning: could not remove ${runner_vol}; no registration was present (nothing to back up)"
      fi
    else
      echo "  recreating ${runner_vol} (empty)"
      docker volume create "$runner_vol" >/dev/null 2>&1 || die "failed to recreate ${runner_vol}"
      if [[ "$reg_exists" == "1" ]]; then
        echo "  restoring registration files into ${runner_vol}"
        docker run --rm --entrypoint sh -v "${runner_vol}:/data" -v "${backup_dir}:/backup:ro" "$runner_image" \
          -c "cd /data && tar xzf /backup/${backup_name}" >/dev/null 2>&1 \
          || echo "  warning: could not restore registration; run ./manage.sh replace-token --token \"\$RUNNER_TOKEN\""
      fi
    fi
  fi

  echo "  starting the stack"
  "${COMPOSE[@]}" up -d

  echo "  volume reset complete"
  if [[ -n "$runner_vol" && "$reg_exists" == "1" ]]; then
    echo "  runner-data backup kept at: ${backup_dir}/${backup_name}"
  fi
  echo "  if the runner fails to reconnect, run: ./manage.sh replace-token --token \"\$RUNNER_TOKEN\""
}

# Prune build cache for every buildx builder, including docker-container driver
# builders whose cache lives in a state volume that `docker builder prune`
# (default builder only) does not touch. The default docker-driver builder is
# skipped because the regular builder prune already covers it.
prune_buildx_cache() {
  local mode="$1" name driver builders

  docker buildx version >/dev/null 2>&1 || return 0

  # `docker buildx ls --format` cannot dereference .Driver on its lsContext, so
  # emit JSON and parse with jq when available (skips the docker-driver default
  # builder, already covered by `docker builder prune`). Without jq, fall back to
  # builder names only and attempt every one.
  if command -v jq >/dev/null 2>&1; then
    builders="$(docker buildx ls --format '{{json .}}' 2>/dev/null \
      | jq -r 'if .Name then "\(.Name)\t\(.Driver)" else empty end' 2>/dev/null \
      | awk '!seen[$0]++' || true)"
  else
    builders="$(docker buildx ls --format '{{.Name}}' 2>/dev/null \
      | awk 'NF && !seen[$0]++' || true)"
  fi
  [[ -n "$builders" ]] || return 0

  while IFS=$'\t' read -r name driver; do
    [[ -n "$name" ]] || continue
    [[ "$driver" == "docker" ]] && continue
    if [[ "$mode" == "dry-run" ]]; then
      echo "  would run: docker buildx prune -a -f --builder ${name}${driver:+ (${driver})}"
    else
      echo "  pruning buildx cache: builder ${name}${driver:+ (${driver})}"
      docker buildx prune -a -f --builder "$name" >/dev/null 2>&1 \
        || echo "  warning: could not prune buildx builder ${name}"
    fi
  done <<<"$builders"
}

cmd_cleanup_docker() {
  local mode="dry-run" until="168h" until_set=0 all_images=0 do_prune=0 do_volumes=0
  local container_args image_args builder_args run_prune=0

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
        until_set=1
        shift 2
        ;;
      --until=*)
        until="${1#--until=}"
        until_set=1
        shift
        ;;
      --all-images)
        all_images=1
        shift
        ;;
      --prune)
        do_prune=1
        shift
        ;;
      --volumes)
        do_volumes=1
        shift
        ;;
      --dangerous)
        do_prune=1
        do_volumes=1
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

  # --prune/--dangerous prune regardless of age, so an explicit --until would be
  # silently ignored. Surface that so a destructive prune is not mistaken for a
  # scoped one.
  if [[ "$do_prune" == "1" && "$until_set" == "1" ]]; then
    echo "  note: --until=${until} is ignored by --prune/--dangerous; all unused images are pruned regardless of age"
  fi

  # --prune (or --dangerous) drops the age filter and prunes all unused images
  # plus all build cache; under the containerd image store this reclaims the
  # /var/lib/containerd space the time-gated default leaves behind. The image
  # prune runs unless --volumes was given alone; volume reset runs only when
  # requested. --dangerous is both.
  [[ "$do_prune" == "1" || "$do_volumes" == "0" ]] && run_prune=1

  if [[ "$do_prune" == "1" ]]; then
    container_args=(container prune -f)
    image_args=(image prune -a -f)
    builder_args=(builder prune -a -f)
  else
    container_args=(container prune -f --filter "until=${until}")
    if [[ "$all_images" == "1" ]]; then
      image_args=(image prune -a -f --filter "until=${until}")
    else
      image_args=(image prune -f --filter "until=${until}")
    fi
    builder_args=(builder prune -f --filter "until=${until}")
  fi

  if [[ "$run_prune" == "1" ]]; then
    section "Docker Prune Cleanup (${mode})"
    if [[ "$do_prune" == "1" ]]; then
      echo "  --prune: no age filter; all stopped containers, all unused images, all build cache (incl. buildx builder cache)"
    fi
    if [[ "$mode" == "dry-run" ]]; then
      echo "  no changes will be made"
      echo "  would run: docker ${container_args[*]}"
      echo "  would run: docker ${image_args[*]}"
      echo "  would run: docker ${builder_args[*]}"
      [[ "$do_prune" == "1" ]] && prune_buildx_cache dry-run
      echo "  these prune commands never touch volumes"

      section "Current Docker Reclaimable Usage"
      docker system df -v || true
    else
      echo "  pruning stopped containers"
      docker "${container_args[@]}"
      echo "  pruning unused images"
      docker "${image_args[@]}"
      echo "  pruning build cache"
      docker "${builder_args[@]}"
      [[ "$do_prune" == "1" ]] && prune_buildx_cache apply
    fi
  fi

  if [[ "$do_volumes" == "1" ]]; then
    cmd_cleanup_docker_volumes "$mode"
  fi
}

print_cache_volume_cleanup_plan() {
  local volume="$1" mountpoint="$2"
  echo "  volume: ${volume}"
  echo "  will remove cache-server cache files and sqlite database state"
  if [[ -n "$mountpoint" ]]; then
    print_cache_volume_candidates "$mountpoint"
  fi
  echo "  cache-server will be stopped before cleanup and started afterwards"
}

cmd_cleanup_volume_cache() {
  local mode="$1" volume mountpoint
  volume="$(find_compose_volume cache-data 2>/dev/null || true)"
  section "cache-data Volume Cleanup (${mode})"
  if [[ -z "$volume" ]]; then
    echo "  cache-data volume not found"
    return 0
  fi

  mountpoint="$(volume_mountpoint "$volume")"
  if [[ "$mode" == "dry-run" ]]; then
    print_cache_volume_cleanup_plan "$volume" "$mountpoint"
    echo "  dry-run only; re-run with --apply to clear cache-data"
    return 0
  fi

  if ! safe_volume_mountpoint "$mountpoint"; then
    die "unsafe or unavailable cache-data mountpoint: ${mountpoint:-<empty>}"
  fi

  echo "  stopping cache-server"
  "${COMPOSE[@]}" stop --timeout 30 cache-server 2>/dev/null || true

  echo "  clearing ${volume} cache data"
  rm -rf \
    "${mountpoint}/cache" \
    "${mountpoint}/cache-server.db" \
    "${mountpoint}/cache-server.db-shm" \
    "${mountpoint}/cache-server.db-wal"
  mkdir -p "${mountpoint}/cache"

  echo "  starting cache-server"
  "${COMPOSE[@]}" up -d cache-server
}

print_runner_legacy_cleanup_plan() {
  local volume="$1" mountpoint="$2"
  echo "  volume: ${volume}"
  echo "  will preserve .runner, .credentials, and .credentials_rsaparams"
  if [[ -n "$mountpoint" ]]; then
    print_runner_volume_candidates "$mountpoint"
  fi
}

cmd_cleanup_volume_runner_legacy() {
  local mode="$1" volume mountpoint found
  volume="$(find_compose_volume runner-data 2>/dev/null || true)"
  section "runner-data Legacy Cleanup (${mode})"
  if [[ -z "$volume" ]]; then
    echo "  runner-data volume not found"
    return 0
  fi

  mountpoint="$(volume_mountpoint "$volume")"
  if [[ "$mode" == "dry-run" ]]; then
    print_runner_legacy_cleanup_plan "$volume" "$mountpoint"
    echo "  dry-run only; re-run with --apply to remove non-registration entries"
    return 0
  fi

  if ! safe_volume_mountpoint "$mountpoint"; then
    die "unsafe or unavailable runner-data mountpoint: ${mountpoint:-<empty>}"
  fi

  found="$(find "$mountpoint" -mindepth 1 -maxdepth 1 \
    ! -name .runner \
    ! -name .credentials \
    ! -name .credentials_rsaparams \
    -print -quit 2>/dev/null || true)"
  if [[ -z "$found" ]]; then
    echo "  no non-registration entries found"
    return 0
  fi

  echo "  removing non-registration entries from ${volume}"
  find "$mountpoint" -mindepth 1 -maxdepth 1 \
    ! -name .runner \
    ! -name .credentials \
    ! -name .credentials_rsaparams \
    -exec rm -rf {} +
}

cmd_cleanup_volumes() {
  local mode="dry-run" target="__all__" target_set=0

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
      cache | cache-data)
        target="cache"
        target_set=1
        shift
        ;;
      runner-legacy | runner-data)
        target="runner-legacy"
        target_set=1
        shift
        ;;
      -h | --help)
        cleanup_usage
        return 0
        ;;
      *)
        die "unknown cleanup volumes argument: $1"
        ;;
    esac
  done

  if [[ "$mode" == "apply" && "$target_set" == "0" ]]; then
    die "cleanup volumes --apply requires cache, runner-data, or --all"
  fi

  require_compose
  require_docker

  case "$target" in
    cache)
      cmd_cleanup_volume_cache "$mode"
      ;;
    runner-legacy)
      cmd_cleanup_volume_runner_legacy "$mode"
      ;;
    __all__)
      cmd_cleanup_volume_cache "$mode"
      cmd_cleanup_volume_runner_legacy "$mode"
      ;;
  esac
}

cmd_cleanup_all() {
  local mode="dry-run" until="168h" all_images=0
  local fwd_prune=0 fwd_volumes=0 fwd_dangerous=0
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
      --prune)
        fwd_prune=1
        shift
        ;;
      --volumes)
        fwd_volumes=1
        shift
        ;;
      --dangerous)
        fwd_dangerous=1
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
  [[ "$all_images" == "1" ]] && docker_args+=(--all-images)
  if [[ "$fwd_dangerous" == "1" ]]; then
    docker_args+=(--dangerous)
  else
    [[ "$fwd_prune" == "1" ]] && docker_args+=(--prune)
    [[ "$fwd_volumes" == "1" ]] && docker_args+=(--volumes)
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
    volumes | volume) cmd_cleanup_volumes "$@" ;;
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
    upgrade) cmd_upgrade "$@" ;;
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
