#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

if ! command -v shellcheck >/dev/null 2>&1; then
  echo "error: shellcheck is required (brew install shellcheck)" >&2
  exit 1
fi

shellcheck entrypoint.sh install.sh manage.sh runner.sh scripts/*.sh
/bin/bash -n entrypoint.sh install.sh manage.sh runner.sh scripts/*.sh
echo "shell lint ok"
