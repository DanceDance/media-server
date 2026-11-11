#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_DIR
readonly RETENTION=2
readonly PULL_MAX_ATTEMPTS=3
readonly PULL_RETRY_DELAY_SECS="${PULL_RETRY_DELAY_SECS:-15}"
readonly NOTIFY_SCRIPT="${NOTIFY_SCRIPT:-${HOME:-/root}/.bin/telegram_notify.sh}"
readonly DOCKER_BIN="${DOCKER_BIN:-/usr/bin/docker}"

STACK_NEEDS_START=0
BACKUP_COMPLETE=0
PULL_FAILED=0
backup_file=""

notify_failure() {
  local message="$1"
  [[ -x "$NOTIFY_SCRIPT" ]] || return 0
  "$NOTIFY_SCRIPT" "[MediaServer] $message" || true
}

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

pull_images_with_retry() {
  local attempt
  for ((attempt = 1; attempt <= PULL_MAX_ATTEMPTS; attempt++)); do
    if "$DOCKER_BIN" compose pull --quiet; then
      return 0
    fi
    if (( attempt < PULL_MAX_ATTEMPTS )); then
      echo "Image pull attempt $attempt/$PULL_MAX_ATTEMPTS failed; retrying in ${PULL_RETRY_DELAY_SECS}s..." >&2
      sleep "$PULL_RETRY_DELAY_SECS"
    fi
  done
  echo "Warning: image pull failed after $PULL_MAX_ATTEMPTS attempts; continuing with backup." >&2
  return 1
}

prune_old_backups() {
  local LC_COLLATE=C
  shopt -s nullglob
  local backups=("$BACKUP_ROOT"/media-server-[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]-[0-9][0-9][0-9][0-9][0-9][0-9].tar.gz)
  shopt -u nullglob

  (( ${#backups[@]} > RETENTION )) || return 0

  local remove_count=$(( ${#backups[@]} - RETENTION ))
  local i
  for ((i = 0; i < remove_count; i++)); do
    rm -- "${backups[$i]}"
  done
}

finish() {
  local status=$?
  set +e
  trap - EXIT INT TERM HUP

  local recovery_failed=0
  if (( STACK_NEEDS_START )); then
    echo "Starting the stack after interrupted backup..." >&2
    if ! "$DOCKER_BIN" compose up -d; then
      recovery_failed=1
      (( status == 0 )) && status=1
    fi
  fi

  if (( ! BACKUP_COMPLETE )) && [[ -n "$backup_file" ]]; then
    rm -f -- "$backup_file" || true
  fi

  if (( recovery_failed )); then
    notify_failure "CRITICAL: Weekly update failed (exit $status) and docker compose up -d recovery failed; containers may still be stopped. Check $PROJECT_DIR/update.log."
    exit "$status"
  fi

  if (( status != 0 )); then
    notify_failure "Weekly stack update/backup failed (exit $status). Check $PROJECT_DIR/update.log."
    exit "$status"
  fi

  if (( PULL_FAILED )); then
    notify_failure "Weekly backup succeeded, but docker compose pull failed after $PULL_MAX_ATTEMPTS attempts. Check $PROJECT_DIR/update.log."
    exit 1
  fi

  exit 0
}

cd "$PROJECT_DIR"

exec 9>"$PROJECT_DIR/.update_stack.lock"
if ! flock -n 9; then
  echo "Another update is already running; skipping this run." >&2
  notify_failure "Weekly stack update skipped because $PROJECT_DIR/.update_stack.lock is already held."
  exit 1
fi

trap finish EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

if [[ ! -f .env ]]; then
  echo "Missing .env; refusing to update without the existing configuration." >&2
  exit 1
fi

if [[ -z "${BACKUP_ROOT:-}" ]]; then
  DATA_ROOT="$(read_env_var DATA_ROOT)"
  if [[ -z "$DATA_ROOT" ]]; then
    echo "Set BACKUP_ROOT or define DATA_ROOT in .env." >&2
    exit 1
  fi
  BACKUP_ROOT="${DATA_ROOT%/}/backup"
fi

mkdir -p "$BACKUP_ROOT"

echo "=== Starting stack update: $(date -Is) ==="
if ! pull_images_with_retry; then
  PULL_FAILED=1
fi

timestamp=$(date '+%Y%m%d-%H%M%S')
backup_file="$BACKUP_ROOT/media-server-$timestamp.tar.gz"

# Stop services briefly so SQLite databases and config files are consistent.
STACK_NEEDS_START=1
"$DOCKER_BIN" compose stop
/usr/bin/tar -czf "$backup_file" -C "$PROJECT_DIR" \
  provision .env .env.defaults docker-compose.yml start.sh \
  setup_cron.sh update_stack.sh
BACKUP_COMPLETE=1

"$DOCKER_BIN" compose up -d
STACK_NEEDS_START=0

echo "Created backup: $backup_file"
prune_old_backups
"$DOCKER_BIN" image prune -f

if (( PULL_FAILED )); then
  echo "Backup completed, but image pull failed: $(date -Is)" >&2
else
  echo "Update completed successfully: $(date -Is)"
fi
