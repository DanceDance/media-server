#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_DIR
readonly SCRIPT_PATH="$PROJECT_DIR/update_stack.sh"
readonly CRON_SCHEDULE="23 4 * * 1"
readonly JOB="$CRON_SCHEDULE /bin/bash \"$SCRIPT_PATH\" >> \"$PROJECT_DIR/update.log\" 2>&1"

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

existing_crontab=""
if ! crontab_out=$(crontab -l 2>&1); then
  if [[ "$crontab_out" != *"no crontab for"* ]]; then
    echo "Failed to read existing crontab: $crontab_out" >&2
    exit 1
  fi
else
  existing_crontab="$crontab_out"
fi

if [[ -n "$existing_crontab" ]] && grep -Fqx "$JOB" <<< "$existing_crontab"; then
  echo "Weekly update job is already scheduled at $CRON_SCHEDULE."
  exit 0
fi

filtered_crontab=""
if [[ -n "$existing_crontab" ]]; then
  filtered_crontab="$(filter_existing_jobs <<< "$existing_crontab")"
fi

if [[ -n "$filtered_crontab" ]]; then
  printf '%s\n%s\n' "$filtered_crontab" "$JOB" | crontab -
else
  printf '%s\n' "$JOB" | crontab -
fi
echo "Scheduled weekly update with backup for Monday at 04:23 AM."
