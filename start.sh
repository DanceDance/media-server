#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_DIR
readonly DOCKER_BIN="${DOCKER_BIN:-/usr/bin/docker}"

read_env_var() {
  local key="$1"
  awk -v key="$key" '
    {
      sub(/\r$/, "")
      if ($0 ~ /^[[:space:]]*(#|$)/) next
      line = $0
      sub(/^[[:space:]]*(export[[:space:]]+)?/, "", line)
      eq = index(line, "=")
      if (!eq) next
      lhs = substr(line, 1, eq - 1)
      sub(/[[:space:]]+$/, "", lhs)
      if (lhs != key) next
      rhs = substr(line, eq + 1)
      sub(/^[[:space:]]+/, "", rhs)
      if (rhs ~ /^"[^"]*"([[:space:]]*(#.*)?)?$/) {
        sub(/^"/, "", rhs); sub(/"([[:space:]]*(#.*)?)?$/, "", rhs)
      } else if (rhs ~ /^\x27[^\x27]*\x27([[:space:]]*(#.*)?)?$/) {
        sub(/^\x27/, "", rhs); sub(/\x27([[:space:]]*(#.*)?)?$/, "", rhs)
      } else {
        sub(/[[:space:]]+#.*$/, "", rhs); sub(/[[:space:]]+$/, "", rhs)
      }
      val = rhs
    }
    END { print val }
  ' .env
}

ensure_bind_directories() {
  local data_root="$1"
  local temp_root="$2"
  local dir

  mkdir -p \
    "${data_root%/}/media/movies" \
    "${data_root%/}/media/tv" \
    "${data_root%/}/downloads/movies" \
    "${data_root%/}/downloads/tv" \
    "$temp_root"

  while IFS= read -r dir; do
    mkdir -p "$dir"
  done < <(awk '!/^[[:space:]]*#/' docker-compose.yml | grep -oE '\./provision/[A-Za-z0-9._-]+' | sort -u || true)
}

cd "$PROJECT_DIR"

# Ensure .env exists before starting
if [[ ! -f .env ]]; then
  echo "Initializing .env from .env.defaults..."
  cp .env.defaults .env
  echo "Created .env from .env.defaults (edit DATA_ROOT and TEMP_ROOT in .env to customize paths)."
fi

DATA_ROOT="$(read_env_var DATA_ROOT)"
TEMP_ROOT="$(read_env_var TEMP_ROOT)"
if [[ -z "$DATA_ROOT" || -z "$TEMP_ROOT" ]]; then
  echo "Error: DATA_ROOT and TEMP_ROOT must be set in .env." >&2
  exit 1
fi

ensure_bind_directories "$DATA_ROOT" "$TEMP_ROOT"

"$DOCKER_BIN" compose pull --quiet
"$DOCKER_BIN" compose up -d
"$DOCKER_BIN" image prune -f
