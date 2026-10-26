#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RETENTION=2
STACK_NEEDS_START=0
BACKUP_COMPLETE=0

cd "$PROJECT_DIR"

exec 9>"$PROJECT_DIR/.update_stack.lock"
if ! flock -n 9; then
  echo "Another update is already running; skipping this run." >&2
  exit 1
fi

if [[ ! -f .env ]]; then
  echo "Missing .env; refusing to update without the existing configuration." >&2
  exit 1
fi

if [[ -z "${BACKUP_ROOT:-}" ]]; then
  DATA_ROOT=$(awk -F= '$1 == "DATA_ROOT" { sub(/^[^=]*=/, ""); print; exit }' .env)
  if [[ -z "$DATA_ROOT" ]]; then
    echo "Set BACKUP_ROOT or define DATA_ROOT in .env." >&2
    exit 1
  fi
  BACKUP_ROOT="${DATA_ROOT%/}/backup"
fi

mkdir -p "$BACKUP_ROOT"
timestamp=$(date '+%Y%m%d-%H%M%S')
backup_file="$BACKUP_ROOT/media-server-$timestamp.tar.gz"

finish() {
  local status=$?
  trap - EXIT
  if (( STACK_NEEDS_START )); then
    echo "Starting the stack after interrupted backup..."
    /usr/bin/docker compose up -d || status=1
  fi
  if (( ! BACKUP_COMPLETE )); then
    rm -f -- "$backup_file"
  fi
  exit "$status"
}
trap finish EXIT

# Stop services briefly so their SQLite databases and config files are consistent.
STACK_NEEDS_START=1
/usr/bin/docker compose stop
/usr/bin/tar -czf "$backup_file" -C "$PROJECT_DIR" \
  provision .env .env.defaults docker-compose.yml start.sh \
  setup_cron.sh update_stack.sh
BACKUP_COMPLETE=1
/usr/bin/docker compose up -d
STACK_NEEDS_START=0

echo "Created backup: $backup_file"
# Keep the newest dated archives. These contain service configuration and secrets.
shopt -s nullglob
backups=("$BACKUP_ROOT"/media-server-*.tar.gz)
if (( ${#backups[@]} > RETENTION )); then
  for ((i=0; i<${#backups[@]}-RETENTION; i++)); do
    rm -- "${backups[$i]}"
  done
fi

/usr/bin/docker compose pull
/usr/bin/docker compose up -d

echo "Update completed successfully."
