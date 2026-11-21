#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_DIR
readonly SCRIPT_PATH="$PROJECT_DIR/update_stack.sh"
readonly ENV_FILE="$PROJECT_DIR/.env"
readonly CRON_SCHEDULE="23 4 * * 1"
readonly REBOOT_DELAY_SECS=120
readonly BACKUP_MAX_AGE_DAYS=7

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
  ' "$ENV_FILE"
}

filter_existing_jobs() {
  awk -v script="$SCRIPT_PATH" '
    /^[[:space:]]*#/ { print; next }
    {
      pos = index($0, script)
      if (!pos) { print; next }
      before = (pos > 1) ? substr($0, pos - 1, 1) : ""
      after = substr($0, pos + length(script), 1)
      if ((before == "" || before == "\"" || before == " " || before == "\t") &&
          (after == "" || after == "\"" || after == " " || after == "\t")) {
        next
      }
      print
    }
  '
}

if [[ ! -x "$SCRIPT_PATH" ]]; then
  echo "Update script is missing or not executable: $SCRIPT_PATH" >&2
  exit 1
fi

if [[ ! -f "$ENV_FILE" ]]; then
  echo "Missing $ENV_FILE; define DATA_ROOT before scheduling cron jobs." >&2
  exit 1
fi

DATA_ROOT="$(read_env_var DATA_ROOT)"
if [[ -z "$DATA_ROOT" ]]; then
  echo "Missing DATA_ROOT in $ENV_FILE; define DATA_ROOT before scheduling cron jobs." >&2
  exit 1
fi

readonly BACKUP_DIR="${DATA_ROOT%/}/backup"
readonly JOB="$CRON_SCHEDULE /bin/bash \"$SCRIPT_PATH\" >> \"$PROJECT_DIR/update.log\" 2>&1"
readonly REBOOT_JOB="@reboot sleep $REBOOT_DELAY_SECS && if [ -z \"\$(find \"$BACKUP_DIR\" -maxdepth 1 -name 'media-server-[0-9]*-[0-9]*.tar.gz' -mtime -$BACKUP_MAX_AGE_DAYS 2>/dev/null)\" ]; then /bin/bash \"$SCRIPT_PATH\" >> \"$PROJECT_DIR/update.log\" 2>&1; fi"

existing_crontab=""
if ! crontab_out=$(crontab -l 2>&1); then
  if [[ "$crontab_out" != *"no crontab for"* ]]; then
    echo "Failed to read existing crontab: $crontab_out" >&2
    exit 1
  fi
else
  existing_crontab="$crontab_out"
fi

filtered_crontab=""
if [[ -n "$existing_crontab" ]]; then
  filtered_crontab="$(filter_existing_jobs <<< "$existing_crontab")"
fi

if [[ -n "$filtered_crontab" ]]; then
  new_crontab=$(printf '%s\n%s\n%s' "$filtered_crontab" "$JOB" "$REBOOT_JOB")
else
  new_crontab=$(printf '%s\n%s' "$JOB" "$REBOOT_JOB")
fi

if [[ "$new_crontab" == "$existing_crontab" ]]; then
  echo "Weekly update and reboot catch-up jobs are already scheduled."
  exit 0
fi

printf '%s\n' "$new_crontab" | crontab -
echo "Scheduled weekly update (Monday at 04:23 AM) and @reboot catch-up (>7 days old)."
